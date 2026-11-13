package com.yggnode.app.vpn

import org.json.JSONArray
import org.json.JSONObject
import yggnode.Node

/**
 * Watches the live peer links and keeps the tunnel usable.
 *
 * A Yggdrasil node does not drop a dead peer by itself: the link stays in the
 * list and keeps retrying with a growing back-off. On a phone that is not good
 * enough — a peer that went away in the morning may only come back hours later,
 * while the tunnel has nothing to route through. This supervisor notices that,
 * removes the dead link and puts a live replacement from the probe pool in its
 * place.
 *
 * The pool is filled by the app after every probe run, so a replacement is
 * already known to have completed a handshake and carries its measured latency.
 */
class PeerSupervisor(
    private val prefs: Prefs,
    private val node: Node,
    private val settingsProvider: () -> Settings,
    private val onLog: (String, String) -> Unit,
    private val onActiveChanged: (List<PeerEntry>) -> Unit,
    private val onStats: (up: Int, total: Int, latencyMs: Double, peersJson: String) -> Unit,
) {
    private data class Runtime(
        val uri: String,
        val up: Boolean,
        val latencyMs: Double,
        val lastError: String,
        val lastErrorUnix: Long,
    )

    private val lock = Any()
    private var active: MutableList<PeerEntry> = mutableListOf()
    private var pool: MutableList<PeerEntry> = mutableListOf()

    /** The last error seen for each peer, kept after the link comes back. */
    private val lastErrors = LinkedHashMap<String, PeerErrorRecord>()

    /** When each peer was first seen down, in elapsed-realtime milliseconds. */
    private val deadSince = HashMap<String, Long>()

    /** When each peer was put into the active list. A fresh link needs time to
     *  finish its handshake before it may be declared dead. */
    private val addedAt = HashMap<String, Long>()

    /** Peers that were dropped stay out of the pool for a while, so a flapping
     *  link cannot bounce back and forth between the same two URIs. */
    private val penalisedUntil = HashMap<String, Long>()

    @Volatile
    private var running = false
    private var thread: Thread? = null
    private var lastRetryAt = 0L

    /** Guards the sleep between ticks so a manual refresh can cut it short. */
    private val sleeper = Object()

    @Volatile
    private var checkRequested = false

    /** Asks the loop to read the peer state again right away. */
    fun requestCheck() {
        checkRequested = true
        synchronized(sleeper) { sleeper.notifyAll() }
    }

    fun start(active: List<PeerEntry>, pool: List<PeerEntry>) {
        val now = android.os.SystemClock.elapsedRealtime()
        synchronized(lock) {
            this.active = active.toMutableList()
            this.pool = pool.toMutableList()
            deadSince.clear()
            addedAt.clear()
            for (peer in active) {
                addedAt[peer.uri] = now
            }
            penalisedUntil.clear()
            lastErrors.clear()
            lastErrors.putAll(prefs.peerErrors())
        }
        running = true
        thread = Thread({ loop() }, "ygg-supervisor").apply {
            isDaemon = true
            start()
        }
        onLog("INFO", "supervisor started with ${active.size} peer(s), pool ${pool.size}")
    }

    fun stop() {
        running = false
        synchronized(sleeper) { sleeper.notifyAll() }
        thread?.interrupt()
        thread = null
        // The stored list is not written back here. It belongs to the UI: the
        // supervisor saves its own replacements as they happen, and writing the
        // in-memory list on stop would overwrite a switch the app made a moment
        // ago, when `applyUserPeers` had not reached this thread yet. The next
        // connect then read the old exit peer and the tunnel came up without
        // the node the user had just selected.
    }

    /** Called when the user edits the peer list while the tunnel is up. */
    fun applyUserPeers(peers: List<PeerEntry>) {
        val now = android.os.SystemClock.elapsedRealtime()
        synchronized(lock) {
            val previous = active.map { it.uri }.toSet()
            active = peers.toMutableList()
            deadSince.keys.retainAll(active.map { it.uri }.toSet())
            // The store is what a connect reads, so it is written before the Go
            // node is touched: a disconnect racing with this call must not bring
            // the previous list back.
            prefs.savePeers(active.toList())
            for (peer in peers) {
                if (peer.uri !in previous) {
                    addedAt[peer.uri] = now
                    try {
                        node.addPeer(peer.uri)
                    } catch (t: Throwable) {
                        onLog("ERROR", "could not add ${peer.uri}: ${t.message}")
                    }
                }
            }
            for (uri in previous) {
                if (peers.none { it.uri == uri }) {
                    try {
                        node.removePeer(uri)
                    } catch (t: Throwable) {
                        onLog("ERROR", "could not remove $uri: ${t.message}")
                    }
                }
            }
        }
        onLog("INFO", "peer list updated by the user (${peers.size})")
    }

    fun applyPool(pool: List<PeerEntry>) {
        synchronized(lock) {
            this.pool = pool.toMutableList()
            prefs.savePool(this.pool.toList())
        }
    }

    fun currentPeers(): List<PeerEntry> = synchronized(lock) { active.toList() }

    private fun loop() {
        while (running) {
            checkRequested = false
            val settings = settingsProvider()
            try {
                tick(settings)
            } catch (t: Throwable) {
                onLog("ERROR", "supervisor tick failed: ${t.message}")
            }
            val sleep = settings.healthCheckSec.coerceIn(5, 120) * 1000L
            synchronized(sleeper) {
                if (!checkRequested && running) {
                    try {
                        sleeper.wait(sleep)
                    } catch (_: InterruptedException) {
                        return
                    }
                }
            }
        }
    }

    private fun tick(settings: Settings) {
        val raw = node.peersJSON
        val runtime = parse(raw)
        val peersJson = rememberErrors(raw, runtime)
        // Yggdrasil keeps a configured peer under its scheme, host, port and
        // path and drops the options from the live link info. A pinned exit
        // peer is configured with `?key=...`, so the exact URI never matches
        // what the node reports; both sides are compared through the key.
        val byUri = HashMap<String, Runtime>()
        for (state in runtime) {
            byUri[state.uri] = state
            byUri.putIfAbsent(peerKey(state.uri), state)
        }
        val now = android.os.SystemClock.elapsedRealtime()

        val up = runtime.count { it.up }
        val total = runtime.size
        val latencies = runtime.filter { it.up && it.latencyMs > 0 }.map { it.latencyMs }
        val avg = if (latencies.isEmpty()) 0.0 else latencies.average()
        onStats(up, total, avg, peersJson)

        synchronized(lock) {
            // 1. Track how long each active peer has been down.
            for (peer in active) {
                val state = byUri[peer.uri] ?: byUri[peerKey(peer.uri)]
                if (state != null && state.up) {
                    deadSince.remove(peer.uri)
                } else {
                    deadSince.putIfAbsent(peer.uri, now)
                }
            }

            // 2. Replace the peers that stayed down past the timeout. A peer that
            //    was added a moment ago is still handshaking, so it gets a grace
            //    period; and only one peer is swapped per tick, otherwise a
            //    network blip would drain the whole pool in a few seconds.
            if (settings.autoReplace) {
                val timeoutMs = settings.deadPeerTimeoutSec.coerceIn(15, 300) * 1000L
                val dead = active.firstOrNull { peer ->
                    // A pinned exit peer is never replaced: it is the direct
                    // link to the exit node and the profile owns its lifetime.
                    if (peer.pinned) return@firstOrNull false
                    val since = deadSince[peer.uri] ?: return@firstOrNull false
                    val born = addedAt[peer.uri] ?: 0L
                    now - since >= timeoutMs && now - born >= GRACE_MS
                }
                if (dead != null) {
                    replaceLocked(dead, settings, now)
                }
            }

            // 3. Keep the active list at the configured size.
            topUpLocked(settings, now)

            // 4. Nothing is up and there is nothing to swap in: ask the node to
            //    dial again, at most once every 30 seconds.
            if (total > 0 && up == 0 && active.isNotEmpty() && now - lastRetryAt > 30_000L) {
                lastRetryAt = now
                for (state in runtime) {
                    if (state.lastError.isNotBlank()) {
                        onLog("WARN", "peer ${state.uri}: ${state.lastError}")
                    }
                }
                try {
                    node.retryPeersNow()
                    onLog("WARN", "no peer is up, retrying the whole list")
                } catch (t: Throwable) {
                    onLog("ERROR", "retry failed: ${t.message}")
                }
            }

            // 5. Forget stale penalties and dead timers for peers that are gone.
            val activeUris = active.map { it.uri }.toSet()
            deadSince.keys.retainAll(activeUris)
            penalisedUntil.entries.removeAll { it.value < now }
        }
    }

    private fun replaceLocked(dead: PeerEntry, settings: Settings, now: Long) {
        val candidate = pickCandidateLocked(active)
        if (candidate == null) {
            onLog(
                "WARN",
                "peer ${dead.uri} is down and the pool has no replacement; " +
                    "run a peer test to refill it",
            )
            // Give the dead peer another window instead of logging every tick.
            deadSince[dead.uri] = now
            return
        }
        try {
            node.removePeer(dead.uri)
        } catch (t: Throwable) {
            onLog("WARN", "could not remove ${dead.uri}: ${t.message}")
        }
        try {
            node.addPeer(candidate.uri)
        } catch (t: Throwable) {
            onLog("ERROR", "could not add ${candidate.uri}: ${t.message}")
            deadSince[dead.uri] = now
            return
        }
        active.removeAll { it.uri == dead.uri }
        active.add(candidate)
        pool.removeAll { it.uri == candidate.uri }
        deadSince.remove(dead.uri)
        addedAt[candidate.uri] = now
        addedAt.remove(dead.uri)
        penalisedUntil[dead.uri] = now + PENALTY_MS
        prefs.savePeers(active.toList())
        prefs.savePool(pool.toList())
        onLog("INFO", "peer ${dead.uri} replaced with ${candidate.uri}")
        onActiveChanged(active.toList())
        topUpLocked(settings, now)
    }

    private fun topUpLocked(settings: Settings, now: Long) {
        var changed = false
        // `peerCount` describes the public peers the user picked. The pinned
        // exit links sit on top of that number and are never counted, so a
        // tunnel with three public peers and one exit node keeps three + one.
        while (active.count { !it.pinned } < settings.peerCount) {
            val candidate = pickCandidateLocked(active) ?: break
            try {
                node.addPeer(candidate.uri)
            } catch (t: Throwable) {
                onLog("ERROR", "could not add ${candidate.uri}: ${t.message}")
                pool.removeAll { it.uri == candidate.uri }
                continue
            }
            active.add(candidate)
            pool.removeAll { it.uri == candidate.uri }
            addedAt[candidate.uri] = now
            changed = true
            onLog("INFO", "peer ${candidate.uri} added from the pool")
        }
        if (changed) {
            prefs.savePeers(active.toList())
            prefs.savePool(pool.toList())
            onActiveChanged(active.toList())
        }
    }

    /** The fastest pool entry that is not already in use and not penalised. */
    private fun pickCandidateLocked(activeNow: List<PeerEntry>): PeerEntry? {
        val used = activeNow.map { it.uri }.toSet()
        val usedHosts = activeNow.map { hostOf(it.uri) }.toSet()
        val now = android.os.SystemClock.elapsedRealtime()
        return pool
            .asSequence()
            .filter { it.uri.isNotBlank() && it.uri !in used && !it.pinned }
            .filter { hostOf(it.uri) !in usedHosts }
            .filter { (penalisedUntil[it.uri] ?: 0L) <= now }
            .sortedWith(compareBy({ it.latencyMs <= 0.0 }, { it.latencyMs }, { it.tcpRttMs }))
            .firstOrNull()
    }

    private fun hostOf(uri: String): String = try {
        java.net.URI(uri).host?.lowercase() ?: uri
    } catch (_: Exception) {
        uri
    }

    /**
     * The identity of a peer link without its query string, matching the URI
     * the Yggdrasil core reports for a live link (`?key=...` is dropped).
     */
    private fun peerKey(uri: String): String = try {
        val parsed = java.net.URI(uri.trim())
        val host = parsed.host ?: return uri.trim()
        val bracketed = if (host.contains(':')) "[$host]" else host
        val port = if (parsed.port > 0) ":${parsed.port}" else ""
        val path = parsed.path ?: ""
        "${parsed.scheme}://$bracketed$port$path"
    } catch (_: Exception) {
        uri.trim()
    }

    private fun parse(raw: String): List<Runtime> {
        if (raw.isBlank()) return emptyList()
        return try {
            val arr = JSONArray(raw)
            buildList {
                for (i in 0 until arr.length()) {
                    val o: JSONObject = arr.optJSONObject(i) ?: continue
                    val uri = o.optString("uri")
                    if (uri.isBlank()) continue
                    add(
                        Runtime(
                            uri = uri,
                            up = o.optBoolean("up", false),
                            latencyMs = o.optDouble("latencyMs", 0.0),
                            lastError = o.optString("lastError"),
                            lastErrorUnix = o.optLong("lastErrorUnix", 0L),
                        ),
                    )
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    /**
     * Remembers every error the node reports and adds the previous one to the
     * JSON of a peer that has recovered. The node clears `lastError` as soon as
     * the link is back, so without this copy the UI would show "none" and lose
     * the error that the user still wants to see.
     */
    private fun rememberErrors(raw: String, runtime: List<Runtime>): String {
        var changed = false
        synchronized(lock) {
            for (state in runtime) {
                if (state.lastError.isBlank()) continue
                val known = lastErrors[state.uri]
                val at = when {
                    state.lastErrorUnix > 0 -> state.lastErrorUnix
                    known != null && known.message == state.lastError -> known.lastSeenUnix
                    else -> System.currentTimeMillis() / 1000
                }
                if (known == null || known.message != state.lastError || known.lastSeenUnix != at) {
                    lastErrors[state.uri] = PeerErrorRecord(state.lastError, at)
                    changed = true
                }
            }
            if (changed) prefs.savePeerErrors(lastErrors)
        }
        if (lastErrors.isEmpty()) return raw
        return try {
            val arr = JSONArray(raw)
            var enriched = false
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (o.optString("lastError").isNotBlank()) continue
                val record = synchronized(lock) { lastErrors[o.optString("uri")] } ?: continue
                o.put("lastErrorWas", record.message)
                o.put("lastErrorWasUnix", record.lastSeenUnix)
                enriched = true
            }
            if (enriched) arr.toString() else raw
        } catch (_: Exception) {
            raw
        }
    }

    companion object {
        private const val PENALTY_MS = 10 * 60 * 1000L

        /** How long a freshly added peer may stay down before it is replaced. */
        private const val GRACE_MS = 90 * 1000L
    }
}
