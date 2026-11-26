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
    /** Called when every active peer is down and the pool has nothing to swap
     *  in. The service then probes the cached catalogue and refills the pool,
     *  so a tunnel left alone overnight can recover without the app. */
    private val onPoolEmpty: () -> Unit = {},
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

    @Volatile
    private var thread: Thread? = null
    private var lastRetryAt = 0L

    /** When the loop started, for the fast warm-up pace: a fresh tunnel spends
     *  the first seconds completing handshakes, and the normal interval would
     *  leave the list at "0 of 3" until the next tick. */
    private var startedAt = 0L

    /** The counts of the last tick, so the warm-up stops once every link is up. */
    @Volatile
    private var lastUp = 0
    @Volatile
    private var lastTotal = 0

    /** Guards the completion of a tick for [requestCheckAndWait]. */
    private val tickSignal = Object()
    @Volatile
    private var tickRequested = 0L
    @Volatile
    private var tickCompleted = 0L

    /** When the service was last asked to refill an empty pool. */
    private var lastPoolRequestAt = 0L

    /** A forced tick interval for the current visibility, zero to follow the
     *  health setting. The tunnel keeps running either way: a longer interval
     *  only means a dead peer is noticed and replaced later, which costs
     *  nothing while nobody watches the list. */
    @Volatile
    private var overrideIntervalMs = 0L

    /** Switches the pace without waiting out the sleep that is running now. */
    fun setPace(intervalMs: Long) {
        if (overrideIntervalMs == intervalMs) return
        overrideIntervalMs = intervalMs
        synchronized(sleeper) { sleeper.notifyAll() }
    }

    /** True while the window is on screen. The error history is only attached
     *  to the peer JSON for a reader that can show it: rebuilding the enriched
     *  array and writing the map to the store costs work nobody sees while the
     *  app is in the background. */
    @Volatile
    private var uiVisible = false

    fun setUiVisible(value: Boolean) {
        uiVisible = value
    }

    /** Peers dropped by the screen-off "exit node only" mode, in the order they
     *  were configured, restored on the next wake. A peer that the node refused
     *  to take back stays here and is retried on the health tick. */
    private val suspended = mutableListOf<PeerEntry>()

    /** When the last retry of a failed restore ran, in elapsed-realtime millis. */
    private var lastRestoreAt = 0L

    /** True while the screen is off and only the pinned exit links stay up. */
    @Volatile
    private var exitOnly = false

    /**
     * Screen-off mode: drop every public peer and keep only the pinned links of
     * the exit node, so the radio is not kept awake by the mesh while the phone
     * sleeps. Without a pinned peer there is nothing to keep and the call does
     * nothing. The full list comes back from [suspended] when the screen is on;
     * the store is left untouched, so a restart of the service always reads the
     * list the user configured.
     *
     * While the mode is on the loop parks itself: nothing but the exit link is
     * left, and the wake-up alarm already asks for a check on every slot, so a
     * timer here would only wake the CPU twice for the same look.
     */
    fun setExitOnly(on: Boolean) {
        if (exitOnly == on) return
        exitOnly = on
        var changed = false
        try {
            changed = applyExitOnlyLocked(on)
        } finally {
            // A plain notify is not enough: the loop may have been inside a
            // tick when the flag moved, so the wake-up would be lost and the
            // counts would stay at the values from before the drop. The
            // request flag survives that window and forces one fresh look.
            requestCheck()
        }
        // The list changed outside a tick, so the counts in the shared state
        // are still the ones from before. Publishing them here keeps a window
        // that is coming back from showing the old "4/4 connected" for the
        // moment the restore takes.
        if (changed) publishLiveStats()
    }

    /** Drops or restores the public peers. Returns true when the list moved. */
    private fun applyExitOnlyLocked(on: Boolean): Boolean {
        val now = android.os.SystemClock.elapsedRealtime()
        synchronized(lock) {
            if (on) {
                if (active.none { it.pinned }) {
                    // No exit node in the list: the switch has nothing to keep.
                    exitOnly = false
                    return false
                }
                val drop = active.filter { !it.pinned }
                if (drop.isEmpty()) return false
                // A restore the node refused may still be pending here. The
                // list is merged instead of cleared so the screen going off
                // again does not lose those peers for good.
                suspended.removeAll { peer -> drop.any { it.uri == peer.uri } }
                suspended.addAll(drop)
                for (peer in drop) {
                    try {
                        node.removePeer(peer.uri)
                    } catch (t: Throwable) {
                        onLog("WARN", "could not remove ${peer.uri}: ${t.message}")
                    }
                    deadSince.remove(peer.uri)
                    addedAt.remove(peer.uri)
                }
                active.removeAll { !it.pinned }
                prefs.noteScreenOffDrop()
                onLog(
                    "INFO",
                    "screen off: ${drop.size} peer(s) dropped, only the exit node stays",
                )
                onActiveChanged(active.toList())
                return true
            }
            if (suspended.isEmpty()) return false
            val restored = suspended.toList()
            suspended.clear()
            var failed = 0
            var restoredCount = 0
            for (peer in restored) {
                if (active.any { it.uri == peer.uri }) continue
                try {
                    node.addPeer(peer.uri)
                } catch (t: Throwable) {
                    // The network may still be coming up after the sleep. The
                    // peer goes back to the list so the next tick tries again
                    // instead of losing it until the tunnel is rebuilt.
                    onLog("WARN", "could not restore ${peer.uri}, will retry: ${t.message}")
                    suspended.add(peer)
                    failed++
                    continue
                }
                active.add(peer)
                addedAt[peer.uri] = now
                restoredCount++
            }
            onLog(
                "INFO",
                "screen on: $restoredCount peer(s) restored" +
                    if (failed > 0) ", $failed to retry" else "",
            )
            if (restoredCount == 0) return false
            onActiveChanged(active.toList())
            return true
        }
    }

    /** Reads the live peer state and publishes the counts right away. */
    private fun publishLiveStats() {
        try {
            val raw = node.peersJSON
            val runtime = parse(raw)
            val up = runtime.count { it.up }
            val latencies = runtime.filter { it.up && it.latencyMs > 0 }.map { it.latencyMs }
            val avg = if (latencies.isEmpty()) 0.0 else latencies.average()
            onStats(up, runtime.size, avg, if (uiVisible) rememberErrors(raw, runtime) else raw)
        } catch (t: Throwable) {
            onLog("WARN", "could not read the peer state: ${t.message}")
        }
    }

    /** Guards the sleep between ticks so a manual refresh can cut it short. */
    private val sleeper = Object()

    @Volatile
    private var checkRequested = false

    /** Asks the loop to read the peer state again right away. */
    fun requestCheck() {
        checkRequested = true
        synchronized(sleeper) { sleeper.notifyAll() }
    }

    /**
     * Asks for a check and waits until the loop has actually read the node, so
     * the caller can hand the fresh state to the UI instead of showing a toast
     * before anything was re-read. Returns false when the supervisor is not
     * running or the tick did not finish within [timeoutMs].
     */
    fun requestCheckAndWait(timeoutMs: Long): Boolean {
        if (!running || thread == null) return false
        val target: Long
        synchronized(lock) {
            tickRequested++
            target = tickRequested
        }
        requestCheck()
        synchronized(tickSignal) {
            val deadline = android.os.SystemClock.elapsedRealtime() + timeoutMs
            while (tickCompleted < target) {
                val left = deadline - android.os.SystemClock.elapsedRealtime()
                if (left <= 0L) return false
                try {
                    tickSignal.wait(left)
                } catch (_: InterruptedException) {
                    return false
                }
            }
        }
        return true
    }

    /**
     * Recreates the given links. Android may freeze the network while the
     * screen is off, and a TCP link that lost its path stays "up" in the core:
     * there is no keep-alive and no read deadline, so the node keeps writing
     * into a dead socket. Recreating the links is the only way back without
     * tearing the whole tunnel down.
     *
     * The core deletes a link from its map only after the goroutine that owns
     * it exits, and an add for a link that is still there answers "already
     * configured" without dialling. The links are therefore dropped first, the
     * node is polled until it forgets them, and only then are they added back.
     */
    fun restartLinks(peers: List<PeerEntry>, reason: String) {
        val now = android.os.SystemClock.elapsedRealtime()
        // A link younger than the fresh window was dialled after the sleep, so
        // its socket is new: the peers of the "exit node only" mode are
        // restored right before this call and must not be cancelled again.
        val targets = peers.filter { peer ->
            val born = synchronized(lock) { addedAt[peer.uri] } ?: 0L
            born == 0L || now - born >= LINK_FRESH_MS
        }
        if (targets.isEmpty()) return
        for (peer in targets) {
            try {
                node.removePeer(peer.uri)
            } catch (t: Throwable) {
                if (!t.message.orEmpty().contains("not configured")) {
                    onLog("WARN", "could not drop ${peer.uri}: ${t.message}")
                }
            }
        }
        val keys = targets.map { peerKey(it.uri) }.toSet()
        if (!waitForLinksGone(keys, LINK_RESTART_WAIT_MS)) {
            onLog(
                "WARN",
                "restart: the node kept some links longer than ${LINK_RESTART_WAIT_MS} ms",
            )
        }
        var restarted = 0
        for (peer in targets) {
            if (synchronized(lock) { active.none { it.uri == peer.uri } }) continue
            var added = false
            var lastError = ""
            for (attempt in 1..LINK_RESTART_ATTEMPTS) {
                try {
                    node.addPeer(peer.uri)
                    added = true
                    break
                } catch (t: Throwable) {
                    lastError = t.message.orEmpty()
                    if (attempt < LINK_RESTART_ATTEMPTS) {
                        try {
                            Thread.sleep(LINK_RESTART_RETRY_MS)
                        } catch (_: InterruptedException) {
                            Thread.currentThread().interrupt()
                            return
                        }
                    }
                }
            }
            if (!added) {
                onLog("WARN", "could not re-add ${peer.uri}: $lastError")
                continue
            }
            synchronized(lock) {
                addedAt[peer.uri] = android.os.SystemClock.elapsedRealtime()
                deadSince.remove(peer.uri)
            }
            restarted++
        }
        if (restarted > 0) {
            onLog("INFO", "restarted $restarted peer link(s): $reason")
            synchronized(lock) { onActiveChanged(active.toList()) }
            publishLiveStats()
        }
    }

    /** True once the node reports none of the given links any more. */
    private fun waitForLinksGone(keys: Set<String>, timeoutMs: Long): Boolean {
        if (keys.isEmpty()) return true
        val deadline = android.os.SystemClock.elapsedRealtime() + timeoutMs
        while (true) {
            val present = try {
                parse(node.peersJSON).map { peerKey(it.uri) }.toSet()
            } catch (_: Throwable) {
                return false
            }
            if (keys.none { it in present }) return true
            if (android.os.SystemClock.elapsedRealtime() >= deadline) return false
            try {
                Thread.sleep(LINK_RESTART_POLL_MS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
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
        startedAt = android.os.SystemClock.elapsedRealtime()
        lastUp = 0
        lastTotal = 0
        synchronized(tickSignal) {
            tickRequested = 0
            tickCompleted = 0
        }
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
            // A peer that was dropped for the screen and is gone from the new
            // list must not come back on the next restore.
            suspended.retainAll { peer -> peers.any { it.uri == peer.uri } }
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
            // The requests made before this tick started are what this tick
            // answers. One that comes in while the tick runs needs the next
            // tick, otherwise the caller would be told "done" with the state
            // read before it asked.
            val tickAtStart = tickRequested
            try {
                tick(settings)
            } catch (t: Throwable) {
                onLog("ERROR", "supervisor tick failed: ${t.message}")
            } finally {
                synchronized(tickSignal) {
                    if (tickCompleted < tickAtStart) tickCompleted = tickAtStart
                    tickSignal.notifyAll()
                }
            }
            val base = settings.healthCheckSec.coerceIn(5, 120) * 1000L
            val warmingUp = android.os.SystemClock.elapsedRealtime() - startedAt <
                FAST_START_MS && (lastTotal == 0 || lastUp < lastTotal)
            val sleep = when {
                // Only the exit link is kept while the screen is off. There is
                // nothing to replace and nothing to top up, and the wake-up
                // alarm already asks for one check per slot: a timer here would
                // wake the CPU a second time for the same look.
                exitOnly -> 0L
                // A negative pace means "park": with auto replace off there is
                // nothing to do while the screen is off, and the loop waits for
                // a real request instead of waking the CPU on a timer.
                overrideIntervalMs < 0L -> 0L
                overrideIntervalMs > 0L -> maxOf(overrideIntervalMs, base)
                // A fresh tunnel finishes its handshakes one by one. Reading
                // the list once a second makes the rows turn green as they come
                // up instead of showing "0 of 3" until the first health tick.
                warmingUp -> FAST_START_INTERVAL_MS
                else -> base
            }
            synchronized(sleeper) {
                if (!checkRequested && running) {
                    try {
                        if (sleep <= 0L) sleeper.wait() else sleeper.wait(sleep)
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
        // Only a visible window shows the stored error of a recovered peer; a
        // hidden one is content with the raw answer of the node.
        val peersJson = if (uiVisible) rememberErrors(raw, runtime) else raw
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
        lastUp = up
        lastTotal = total
        onStats(up, total, avg, peersJson)

        synchronized(lock) {
            // 0. A restore that ran while the network was still coming up after
            //    the sleep left its peers in `suspended`. Ask the node again on
            //    every tick, otherwise they would stay gone until a reconnect.
            if (!exitOnly && suspended.isNotEmpty() && now - lastRestoreAt >= RESTORE_RETRY_MS) {
                lastRestoreAt = now
                applyExitOnlyLocked(false)
            }

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

            // 3. Keep the active list at the configured size. Not while only
            //    the exit link is meant to stay: the public peers are dropped
            //    on purpose and must not be topped up again until the wake.
            if (!exitOnly) topUpLocked(settings, now)

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

            // 5. Nothing is up and the pool is empty: there is nothing left to
            //    swap in, so the service is asked to probe the cached
            //    catalogue. At most once every ten minutes: a probe run costs
            //    real traffic and battery, and a tunnel with no live peer at
            //    all cannot be saved faster than that anyway.
            if (settings.autoReplace && !exitOnly && up == 0 && pool.isEmpty() &&
                now - lastPoolRequestAt > POOL_REQUEST_MS
            ) {
                lastPoolRequestAt = now
                onLog("WARN", "no peer is up and the pool is empty, refilling it")
                onPoolEmpty()
            }

            // 6. Forget stale penalties and dead timers for peers that are gone.
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

        /** How often an empty pool may trigger a background probe. */
        private const val POOL_REQUEST_MS = 10 * 60 * 1000L

        /** The first ticks after a connect run at this pace while some links are
         *  still handshaking, so the list fills in as the links come up. */
        private const val FAST_START_MS = 30_000L
        private const val FAST_START_INTERVAL_MS = 1_000L

        /** A link younger than this was dialled after the sleep and is left
         *  alone by a wake restart: its socket is already new. */
        private const val LINK_FRESH_MS = 10_000L

        /** How long the core may keep a removed link in its map. The entry goes
         *  away only when the link goroutine exits, and an add before that is
         *  answered with "already configured" without dialling. */
        private const val LINK_RESTART_WAIT_MS = 4_000L
        private const val LINK_RESTART_POLL_MS = 25L
        private const val LINK_RESTART_ATTEMPTS = 5
        private const val LINK_RESTART_RETRY_MS = 60L

        /** How often a restore the node refused is retried on the health tick. */
        private const val RESTORE_RETRY_MS = 5_000L
    }
}
