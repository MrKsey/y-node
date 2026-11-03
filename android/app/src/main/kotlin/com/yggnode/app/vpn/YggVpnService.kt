package com.yggnode.app.vpn

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.yggnode.app.R
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.Locale
import java.util.concurrent.Executors
import yggnode.Node
import yggnode.Yggnode

/**
 * The Yggdrasil tunnel.
 *
 * The service owns the TUN descriptor, the Yggdrasil node, the data path and the
 * peer supervisor. The Flutter UI never talks to it directly: it writes settings
 * and the peer list into [Prefs], asks the service to connect, and follows
 * [VpnState] for everything else. That keeps the tunnel alive when the activity
 * is gone.
 */
class YggVpnService : VpnService() {

    companion object {
        const val ACTION_CONNECT = "com.yggnode.app.action.CONNECT"
        const val ACTION_DISCONNECT = "com.yggnode.app.action.DISCONNECT"
        const val ACTION_WAKEUP = "com.yggnode.app.action.WAKEUP"

        private const val CHANNEL_ID = "y_node_tunnel"
        private const val NOTIFICATION_ID = 1001
        private const val WAKEUP_REQUEST = 42

        /** While the screen is off the CPU is allowed to suspend, and the Go
         *  timers of the node — the peer supervisor and the exit health loop —
         *  then run only when something else wakes the device. The alarm buys
         *  them a short slot once a minute; traffic wakes the CPU by itself, so
         *  this is a keep-alive for the idle case, not part of the data path. */
        private const val SCREEN_OFF_WAKEUP_INTERVAL_MS = 60_000L

        /** With "Save battery" the timers are allowed to lag much more: the
         *  tunnel itself does not depend on them, only their freshness does. */
        private const val SCREEN_OFF_WAKEUP_INTERVAL_SAVING_MS = 300_000L

        /** Long enough for one round of Go timers to run, short enough not to
         *  keep the CPU up for a noticeable share of the interval. */
        private const val SCREEN_OFF_WAKE_LOCK_MS = 4_000L
        private const val DATA_ACTIVITY_REFRESH_MS = 1_000L
        private const val DATA_ACTIVITY_WAKE_LOCK_MS = 10_000L
        private const val DATA_ACTIVITY_MIN_BYTES = 16 * 1024

        private const val MAX_REVOKE_ATTEMPTS = 5
        private const val REVOKE_SETTLE_MS = 2_000L
        private const val NETWORK_CHANGE_DEBOUNCE_MS = 1_500L
        private const val NETWORK_SETTLE_MS = 10_000L

        /** The address the apps of the allow list see as their own. It only
         *  exists inside the tunnel; tun2socks forwards the traffic behind it. */
        private const val FORWARD_ADDRESS = "10.111.222.1"

        /** The resolver the tunnel answers itself while an exit node is on. */
        private const val EXIT_DNS_ADDRESS = "10.111.222.2"

        @Volatile
        var isActive: Boolean = false
            private set

        @Volatile
        private var instance: YggVpnService? = null

        /** Pushes a peer list edited in the UI into the running supervisor. */
        fun applyPeers(peers: List<PeerEntry>, pool: List<PeerEntry>) {
            val service = instance ?: return
            service.supervisor?.applyUserPeers(peers)
            service.supervisor?.applyPool(pool)
        }

        /** Re-reads the live peer state right away, for the Refresh button. */
        fun refreshPeers() {
            instance?.supervisor?.requestCheck()
        }

        /** Checks the DNS servers through the running node. */
        fun checkDns(serversJson: String, timeoutMs: Int): String {
            val service = instance ?: return "[]"
            return try {
                service.node.checkDNS(serversJson, timeoutMs.toLong())
            } catch (t: Throwable) {
                ConnectionLog.append("WARN", "DNS check failed: ${t.message}")
                "[]"
            }
        }

        /** Reads an Yggdrasil page through the running node. */
        fun fetchUrl(url: String, timeoutMs: Int): String {
            val service = instance ?: return """{"error":"the tunnel is not running"}"""
            return try {
                service.node.fetchURL(url, timeoutMs.toLong())
            } catch (t: Throwable) {
                ConnectionLog.append("WARN", "page fetch failed: ${t.message}")
                """{"error":"${t.message}"}"""
            }
        }

        /** The exit state and profile health, as reported by the Go bridge. */
        fun exitStatus(): String {
            val service = instance ?: return ""
            return try {
                service.node.exitStatusJSON
            } catch (t: Throwable) {
                ConnectionLog.append("WARN", "exit status failed: ${t.message}")
                ""
            }
        }

        /**
         * Rebuilds the forwarding stack with the exit configuration in the
         * shared store. The Yggdrasil node and the TUN stay up; only forwarded
         * connections are reset.
         */
        fun applyExitConfig(): Boolean {
            val service = instance ?: return false
            return try {
                val current = service.prefs.settings()
                service.node.setExitConfig(
                    current.exitConfigJson(service.systemDnsServers()),
                )
                service.settings = current
                // Restart the health loop so a newly enabled exit is checked
                // right away and a disabled one stops being polled.
                service.startExitWatch()
                ConnectionLog.append("SERVICE", "exit configuration applied")
                true
            } catch (t: Throwable) {
                ConnectionLog.append("WARN", "exit configuration failed: ${t.message}")
                false
            }
        }

        /** Asks every exit profile's status API whether this node is allowed. */
        fun checkExitProfiles(timeoutMs: Int): String {
            val service = instance
                ?: return """{"error":"the tunnel is not running"}"""
            return try {
                service.node.checkExitProfiles(timeoutMs.toLong())
            } catch (t: Throwable) {
                ConnectionLog.append("WARN", "exit check failed: ${t.message}")
                """{"error":"${t.message}"}"""
            }
        }

        /**
         * Checks the UDP relay of the active exit: a DNS query through the exit
         * and a QUIC handshake to the resolved address.
         */
        fun testExitUdp(timeoutMs: Int): String {
            val service = instance
                ?: return """{"ok":false,"state":"off","error":"the tunnel is not running"}"""
            return try {
                service.node.testExitUDP(timeoutMs.toLong())
            } catch (t: Throwable) {
                ConnectionLog.append("WARN", "UDP check failed: ${t.message}")
                """{"ok":false,"state":"error","error":"${t.message}"}"""
            }
        }

        /**
         * Checks IPv6 through the active exit: an HTTPS request to a literal
         * IPv6 address and an AAAA query over the UDP relay.
         */
        fun testExitIPv6(timeoutMs: Int): String {
            val service = instance
                ?: return """{"ok":false,"state":"off","error":"the tunnel is not running"}"""
            return try {
                service.node.testExitIPv6(timeoutMs.toLong())
            } catch (t: Throwable) {
                ConnectionLog.append("WARN", "IPv6 check failed: ${t.message}")
                """{"ok":false,"state":"error","error":"${t.message}"}"""
            }
        }

        /**
         * Reports the address a remote service sees for this device. "exit"
         * goes through the running exit node, so the answer is what websites
         * see while their traffic is carried by it.
         */
        fun publicIp(via: String, timeoutMs: Int): String {
            val service = instance
                ?: return """{"ok":false,"via":"$via","error":"tunnel_off"}"""
            return try {
                service.node.publicIP(via, timeoutMs.toLong())
            } catch (t: Throwable) {
                ConnectionLog.append("WARN", "public IP check failed: ${t.message}")
                """{"ok":false,"via":"$via","error":"native_error"}"""
            }
        }

        /** Redeems an invite token on one exit profile through the tunnel. */
        fun registerExit(profileId: String, invite: String): String {
            val service = instance
                ?: return """{"ok":false,"error":"vpn_not_running"}"""
            val version = try {
                service.appVersion()
            } catch (_: Throwable) {
                "?"
            }
            return try {
                service.node.registerExit(
                    profileId,
                    invite,
                    deviceName(),
                    version,
                )
            } catch (t: Throwable) {
                ConnectionLog.append("WARN", "exit registration failed: ${t.message}")
                """{"ok":false,"error":"native_error"}"""
            }
        }

        private fun deviceName(): String = try {
            Build.MODEL ?: "Android"
        } catch (_: Throwable) {
            "Android"
        }

        fun connect(context: Context) {
            val intent = Intent(context, YggVpnService::class.java).setAction(ACTION_CONNECT)
            ContextCompat.startForegroundService(context, intent)
        }

        fun disconnect(context: Context) {
            val intent = Intent(context, YggVpnService::class.java).setAction(ACTION_DISCONNECT)
            try {
                context.startService(intent)
            } catch (_: Exception) {
            }
        }
    }

    private lateinit var prefs: Prefs
    private var settings: Settings = Settings()
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Everything that touches the Go node runs here. Starting the node,
     * building the TUN interface and stopping them all block for a while; doing
     * that on the main thread froze the UI and the platform channels with it.
     */
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "ygg-service").apply { isDaemon = true }
    }

    /** Set as soon as a disconnect is requested, so a queued connect stops. */
    @Volatile
    private var stopRequested = false

    /** True once the system has destroyed the service; nothing may start then. */
    @Volatile
    private var destroyed = false

    private val node: Node by lazy {
        Yggnode.newNode().also { it.setLogger(goLogger) }
    }

    private val goLogger = object : yggnode.Logger {
        override fun log(level: String, message: String) {
            ConnectionLog.append("YGG/${level.uppercase(Locale.US)}", message)
        }
    }

    /**
     * Binds an upstream socket of the forwarding stack to the real network. The
     * stack dials on behalf of the apps in the allow list, so without this the
     * socket would be routed into the tunnel and back into the stack.
     */
    private val socketProtector = object : yggnode.Protector {
        override fun protect(fd: Long): Boolean {
            return try {
                protect(fd.toInt())
            } catch (t: Throwable) {
                ConnectionLog.append("WARN", "tun2socks socket not protected: ${t.message}")
                false
            }
        }
    }

    private var descriptor: ParcelFileDescriptor? = null
    private var bridge: TunBridge? = null
    private var supervisor: PeerSupervisor? = null
    private var networkMonitor: NetworkMonitor? = null
    private var screenMonitor: ScreenStateMonitor? = null
    private var statsThread: Thread? = null
    private var exitWatchThread: Thread? = null

    /** Guards the sleep of the exit health loop so a wake can cut it short. */
    private val exitSleeper = Object()

    @Volatile
    private var exitCheckRequested = false

    @Volatile
    private var screenInteractive = true

    @Volatile
    private var stopping = false

    @Volatile
    private var lastEstablishedAt = 0L

    private var revokeAttempts = 0
    private var networkChangeScheduled = false
    private var lastNetworkChangeAt = 0L

    /**
     * The status and text of the notification that is already posted. The stats
     * thread wakes once a second, but the notification shows the same few words
     * and formatted byte counts, so posting it again when nothing visible has
     * changed is pure work on the main thread.
     */
    private var lastNotificationKey: String? = null

    private var wakeLock: PowerManager.WakeLock? = null
    private var wakeAlarm: AlarmManager? = null
    private var wakePending: PendingIntent? = null
    private val releaseWakeLockRunnable = Runnable { releaseWakeLockIfIdle() }
    private var lastActivityAt = 0L
    private var bytesSinceRenew = 0

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()
        instance = this
        prefs = Prefs(this)
        settings = prefs.settings()
        ConnectionLog.init(this, appVersion())
        ConnectionLog.enabled = settings.logging
        ConnectionLog.append("SERVICE", "service created")

        createChannel()

        networkMonitor = NetworkMonitor(this) { reason -> onUnderlyingNetworkChanged(reason) }
        networkMonitor?.start()

        screenMonitor = ScreenStateMonitor(this) { interactive -> onScreenStateChanged(interactive) }
        screenMonitor?.start()
        screenInteractive = screenMonitor?.isInteractive ?: true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A null intent means Android restarted the sticky service: the user was
        // connected when it was killed, so bring the tunnel back up.
        val action = intent?.action ?: ACTION_CONNECT
        ConnectionLog.append("SERVICE", "start command: $action")

        return when (action) {
            ACTION_CONNECT -> {
                // The five second foreground deadline is unforgiving: show the
                // notification before doing anything slow.
                goForeground(VpnState.STATUS_CONNECTING, "")
                stopRequested = false
                worker.execute { handleConnect() }
                START_STICKY
            }

            ACTION_WAKEUP -> {
                handleWakeup()
                START_STICKY
            }

            else -> {
                // A connect may still be queued: make it stop before it builds
                // anything, then tear down what is already up.
                stopRequested = true
                worker.execute { handleDisconnect(userInitiated = true) }
                START_NOT_STICKY
            }
        }
    }

    override fun onRevoke() {
        ConnectionLog.append("SERVICE", "VPN slot revoked by another app")
        if (stopping) {
            super.onRevoke()
            return
        }
        VpnState.setStatus(VpnState.STATUS_RECONNECTING, "Another VPN took over")
        worker.execute {
            teardown(keepState = true)
            scheduleRevokeRecovery()
        }
    }

    override fun onDestroy() {
        ConnectionLog.append("SERVICE", "service destroyed")
        destroyed = true
        stopping = true
        stopStats()
        cancelWakeAlarm()
        releaseWakeLock()
        networkMonitor?.stop()
        networkMonitor = null
        screenMonitor?.stop()
        screenMonitor = null
        isActive = false
        if (VpnState.current.status != VpnState.STATUS_DISCONNECTED) {
            VpnState.setStatus(VpnState.STATUS_DISCONNECTED)
        }
        if (instance === this) instance = null
        // The node and the descriptor are released off the main thread; the
        // executor still runs the queued task after shutdown().
        worker.execute {
            supervisor?.stop()
            supervisor = null
            bridge?.stop()
            bridge = null
            closeDescriptor()
        }
        worker.shutdown()
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // Connect / disconnect
    // ------------------------------------------------------------------

    private fun handleConnect() {
        if (destroyed || stopRequested) {
            ConnectionLog.append("SERVICE", "connect cancelled before it started")
            return
        }
        if (isActive && node.isRunning) {
            // A connect while the tunnel is still up means the settings changed
            // (the split-tunnel list is read only on start): tear the old link
            // down and build it again instead of ignoring the request, which
            // used to leave the new list unapplied while the UI said otherwise.
            ConnectionLog.append("SERVICE", "connect while the tunnel is up, restarting")
            teardown(keepState = true)
        }
        stopping = false
        revokeAttempts = 0
        settings = prefs.settings()
        ConnectionLog.enabled = settings.logging

        val identity = prefs.identity()
        if (identity == null) {
            fail("identity_missing", "The node identity is missing, open the app to create one")
            return
        }

        val peers = prefs.peers()
        if (peers.isEmpty()) {
            fail("no_peers", "No peers configured")
            return
        }

        VpnState.setStatus(VpnState.STATUS_CONNECTING)
        VpnState.setStage("starting")
        ConnectionLog.startSession(
            buildString {
                append("Node: ").append(identity.address).append("\n")
                append("Peers: ").append(peers.size).append("\n")
                peers.take(6).forEach { append("  - ").append(it.uri).append("\n") }
                append("DNS: ").append(settings.dnsMode)
                    .append(' ').append(settings.effectiveDns().joinToString(", ")).append("\n")
                append("MTU: ").append(settings.mtu).append("\n")
                append("Split tunnel: ").append(settings.splitEnabled)
                    .append(" (").append(settings.splitApps.size).append(" app(s))\n")
                append("Exit node: ")
                    .append(
                        if (settings.exitActive()) {
                            settings.exitActiveId.ifBlank {
                                settings.exitProfiles.firstOrNull()?.name ?: ""
                            }
                        } else {
                            "off"
                        },
                    )
                    .append('\n')
            },
        )

        val started = startNode(identity, peers)
        if (!started) return
        if (stopRequested) {
            ConnectionLog.append("SERVICE", "connect cancelled after the node start")
            teardown(keepState = false)
            return
        }

        VpnState.setStage("tunnel")
        if (!buildTunnel(identity)) {
            teardown(keepState = false)
            fail("vpn_permission", "Android did not grant the VPN interface")
            return
        }
        if (stopRequested) {
            ConnectionLog.append("SERVICE", "connect cancelled after the tunnel")
            teardown(keepState = false)
            return
        }

        startDataPath()
        // The tunnel carries IPv4 for the ordinary internet, so the forwarding
        // stack has to be up before the first app packet arrives.
        bridge?.startForwarding(
            socketProtector,
            FORWARD_ADDRESS,
            settings.exitConfigJson(systemDnsServers()),
        )
        VpnState.setStage("network")
        startSupervisor(peers)
        VpnState.setStage("peers")

        isActive = true
        lastEstablishedAt = SystemClock.elapsedRealtime()
        prefs.putString(Prefs.KEY_WANTED, "1")
        VpnState.update {
            it.copy(
                status = VpnState.STATUS_CONNECTED,
                stage = "",
                error = null,
                nodeAddress = identity.address,
                subnet = identity.subnet,
                publicKey = identity.publicKey,
                connectedAt = System.currentTimeMillis(),
                dns = if (settings.exitActive()) {
                    EXIT_DNS_ADDRESS
                } else {
                    settings.effectiveDns().joinToString(", ")
                },
                mtu = settings.mtu,
                peersTotal = peers.size,
            )
        }
        startStats()
        startExitWatch()
        goForeground(VpnState.STATUS_CONNECTED, "")
        if (!screenInteractive) {
            scheduleWakeAlarm()
        }
        ConnectionLog.append("SERVICE", "tunnel established")
    }

    private fun startNode(identity: Identity, peers: List<PeerEntry>): Boolean {
        return try {
            val cfg = buildString {
                append('{')
                append("\"privateKey\":\"").append(identity.privateKey).append("\",")
                append("\"mtu\":").append(settings.mtu).append(',')
                append("\"peers\":[")
                peers.forEachIndexed { index, peer ->
                    if (index > 0) append(',')
                    append('"').append(peer.uri.replace("\\", "\\\\").replace("\"", "\\\""))
                        .append('"')
                }
                append("]}")
            }
            node.start(cfg)
            ConnectionLog.append(
                "SERVICE",
                "node started: ${node.address} mtu=${node.mtu}",
            )
            true
        } catch (t: Throwable) {
            ConnectionLog.append("ERROR", "node start failed: ${t.message}")
            fail("node_start", t.message ?: "Could not start the Yggdrasil node")
            false
        }
    }

    private fun buildTunnel(identity: Identity): Boolean {
        val builder = Builder()
        builder.setSession("Y-Node")
        builder.setMtu(settings.mtu)
        builder.addAddress(identity.address, 128)
        // The whole Yggdrasil address space.
        builder.addRoute("200::", 7)
        // Android only tells apps that IPv6 is usable when the VPN network has a
        // global IPv6 route. Without it Chrome and Samsung Internet ask for A
        // records only, and a `.ygg` name has nothing but AAAA, so the browser
        // reports "host not found" even though the tunnel is fine. The route is
        // deliberately 2000::/3 (global unicast): link-local and multicast stay
        // untouched, [TunBridge] sends 200::/7 to the node, and the forwarding
        // stack carries the rest through the exit node when one is enabled.
        builder.addRoute("2000::", 3)
        // Android 12 binds every app in the VPN to the VPN network and never
        // falls back to the real network for an address family the VPN does not
        // route. Without IPv4 the apps simply lose the ordinary internet, so the
        // tunnel carries it too and tun2socks forwards it out.
        builder.addAddress(FORWARD_ADDRESS, 32)
        builder.addRoute("0.0.0.0", 0)
        builder.setBlocking(true)

        for (server in if (settings.exitActive()) {
            listOf(EXIT_DNS_ADDRESS)
        } else {
            settings.effectiveDns()
        }) {
            try {
                builder.addDnsServer(server)
            } catch (t: Throwable) {
                ConnectionLog.append("WARN", "DNS $server rejected: ${t.message}")
            }
        }

        if (settings.splitEnabled) {
            for (pkg in settings.splitApps) {
                // The app itself must never be inside its own tunnel: the node
                // dials peers and the exit API on the real network.
                if (pkg == packageName) continue
                try {
                    builder.addAllowedApplication(pkg)
                } catch (_: Exception) {
                    ConnectionLog.append("WARN", "split tunnel: $pkg is not installed")
                }
            }
            // With an allow list everything else — this app included — already
            // stays outside the tunnel, so no explicit exclusion is allowed here.
            ConnectionLog.append(
                "INFO",
                "split tunnel on, ${settings.splitApps.size} app(s) routed into Yggdrasil",
            )
        } else {
            // The app must never send its own traffic into the tunnel: the node's
            // dials to public peers, the peer test and the DNS lookups all have to
            // use the real network, and a tunnel that depends on itself would
            // never come up.
            try {
                builder.addDisallowedApplication(packageName)
            } catch (t: Throwable) {
                ConnectionLog.append(
                    "WARN",
                    "could not exclude the app from the VPN: ${t.message}",
                )
            }
        }

        descriptor = try {
            builder.establish()
        } catch (t: Throwable) {
            ConnectionLog.append("ERROR", "establish failed: ${t.message}")
            null
        }
        return descriptor != null
    }

    private fun startDataPath() {
        val fd = descriptor ?: return
        val mtu = settings.mtu
        bridge = TunBridge(
            node = node,
            input = FileInputStream(fd.fileDescriptor),
            output = FileOutputStream(fd.fileDescriptor),
            mtu = mtu,
            onLog = { tag, message -> ConnectionLog.append(tag, message) },
            onError = { t ->
                ConnectionLog.append("ERROR", "data path: ${t.message}")
                if (!stopping) {
                    worker.execute { onDataPathFailure(t) }
                }
            },
            onActivity = { bytes -> noteDataActivity(bytes) },
        ).also { it.start() }
        ConnectionLog.append("SERVICE", "data path started (mtu=$mtu)")
    }

    private fun startSupervisor(peers: List<PeerEntry>) {
        supervisor?.stop()
        supervisor = PeerSupervisor(
            prefs = prefs,
            node = node,
            settingsProvider = { prefs.settings() },
            onLog = { tag, message -> ConnectionLog.append(tag, message) },
            onActiveChanged = { updated ->
                VpnState.update { it.copy(peersTotal = updated.size) }
            },
            onStats = { up, total, latency, peersJson ->
                VpnState.update {
                    it.copy(
                        peersUp = up,
                        peersTotal = total,
                        latencyMs = latency,
                        peersJson = peersJson,
                    )
                }
            },
        ).also { it.start(peers, prefs.pool()) }
    }

    private fun handleDisconnect(userInitiated: Boolean) {
        if (userInitiated) {
            ConnectionLog.append("SERVICE", "disconnect requested by the user")
            prefs.putString(Prefs.KEY_WANTED, "0")
        }
        stopping = true
        VpnState.setStatus(VpnState.STATUS_DISCONNECTING)
        try {
            teardown(keepState = false)
        } finally {
            // The UI has to leave the "Disconnecting…" state even when one of
            // the pieces below throws while it is being released.
            VpnState.setStatus(VpnState.STATUS_DISCONNECTED)
            isActive = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    /** Releases everything the tunnel owns. Safe to call more than once. */
    private fun teardown(keepState: Boolean) {
        stopStats()
        stopExitWatch()
        cancelWakeAlarm()
        releaseWakeLock()
        supervisor?.stop()
        supervisor = null
        bridge?.stop()
        bridge = null
        closeDescriptor()
        isActive = false
        if (!keepState) {
            VpnState.reset()
        }
    }

    private fun closeDescriptor() {
        try {
            descriptor?.close()
        } catch (_: Throwable) {
        }
        descriptor = null
    }

    private fun fail(code: String, message: String) {
        ConnectionLog.append("ERROR", "$code: $message")
        teardown(keepState = false)
        isActive = false
        VpnState.update {
            it.copy(
                status = VpnState.STATUS_DISCONNECTED,
                error = code,
            )
        }
        goForeground(VpnState.STATUS_DISCONNECTED, message)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun onDataPathFailure(t: Throwable) {
        if (stopping) return
        // A closed descriptor or a stopped node during teardown is expected; a
        // failure while the tunnel should be up means it has to be rebuilt.
        if (!node.isRunning) {
            ConnectionLog.append("WARN", "node stopped unexpectedly, rebuilding")
            VpnState.setStatus(VpnState.STATUS_RECONNECTING, t.message)
            teardown(keepState = true)
            mainHandler.postDelayed({
                if (!stopping) worker.execute { handleConnect() }
            }, 1_000L)
        }
    }

    // ------------------------------------------------------------------
    // Slot recovery and network changes
    // ------------------------------------------------------------------

    private fun scheduleRevokeRecovery() {
        if (revokeAttempts >= MAX_REVOKE_ATTEMPTS) {
            ConnectionLog.append("WARN", "giving up on the VPN slot after $revokeAttempts tries")
            VpnState.update {
                it.copy(
                    status = VpnState.STATUS_DISCONNECTED,
                    error = "vpn_taken_over",
                )
            }
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        revokeAttempts++
        goForeground(VpnState.STATUS_RECONNECTING, "Another VPN took over")
        // Let the competing VPN finish its own startup before taking the slot
        // back, otherwise the two fight and neither settles.
        mainHandler.postDelayed({
            if (stopping) return@postDelayed
            if (VpnService.prepare(this) != null) {
                ConnectionLog.append("WARN", "VPN permission must be granted again")
                VpnState.update {
                    it.copy(status = VpnState.STATUS_DISCONNECTED, error = "vpn_permission")
                }
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return@postDelayed
            }
            ConnectionLog.append("INFO", "reclaiming the VPN slot (attempt $revokeAttempts)")
            worker.execute { handleConnect() }
        }, REVOKE_SETTLE_MS)
    }

    private fun onUnderlyingNetworkChanged(reason: String) {
        if (!isActive) return
        val now = SystemClock.elapsedRealtime()
        // The TUN setup itself reshapes the network list; ignore the noise right
        // after a successful connect.
        if (now - lastEstablishedAt < NETWORK_SETTLE_MS) return
        if (networkChangeScheduled) return
        networkChangeScheduled = true
        mainHandler.postDelayed({
            networkChangeScheduled = false
            worker.execute networkWork@{
                if (!isActive || stopping) return@networkWork
                if (SystemClock.elapsedRealtime() - lastNetworkChangeAt < NETWORK_CHANGE_DEBOUNCE_MS) {
                    return@networkWork
                }
                lastNetworkChangeAt = SystemClock.elapsedRealtime()
                ConnectionLog.append("SERVICE", "underlying network changed: $reason")
                VpnState.setStatus(VpnState.STATUS_RECONNECTING, "Network changed")
                try {
                    node.retryPeersNow()
                } catch (t: Throwable) {
                    ConnectionLog.append("WARN", "retry after network change failed: ${t.message}")
                }
                // Give the node a moment to redial on the new network; if it still
                // has nothing, rebuild the whole tunnel.
                mainHandler.postDelayed({
                    worker.execute recoverWork@{
                        if (!isActive || stopping) return@recoverWork
                        val up = countUpPeers()
                        if (up == 0) {
                            ConnectionLog.append("WARN", "no peer came back after the network change")
                            teardown(keepState = true)
                            handleConnect()
                        } else {
                            VpnState.setStatus(VpnState.STATUS_CONNECTED)
                        }
                    }
                }, 20_000L)
            }
        }, NETWORK_CHANGE_DEBOUNCE_MS)
    }

    private fun countUpPeers(): Int {
        return try {
            val raw = node.peersJSON
            if (raw.isBlank()) return 0
            val arr = org.json.JSONArray(raw)
            var up = 0
            for (i in 0 until arr.length()) {
                if (arr.optJSONObject(i)?.optBoolean("up", false) == true) up++
            }
            up
        } catch (_: Exception) {
            0
        }
    }

    /**
     * The resolvers of the real network, used for local names while an exit is
     * on. They are read from the active link instead of the VPN: the tunnel is
     * configured with the split-DNS address and would hide the real servers.
     */
    private fun systemDnsServers(): List<String> {
        return try {
            val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return emptyList()
            val network = manager.activeNetwork ?: return emptyList()
            manager.getLinkProperties(network)?.dnsServers
                ?.mapNotNull { it.hostAddress }
                ?.filter { it.isNotBlank() }
                ?: emptyList()
        } catch (_: Throwable) {
            emptyList()
        }
    }

    // ------------------------------------------------------------------
    // Screen state, wake lock and stats
    // ------------------------------------------------------------------

    private fun onScreenStateChanged(interactive: Boolean) {
        screenInteractive = interactive
        ConnectionLog.append(
            "SERVICE",
            if (interactive) "screen on, resuming UI updates" else "screen off, suspending UI updates",
        )
        if (interactive) {
            cancelWakeAlarm()
            mainHandler.removeCallbacks(releaseWakeLockRunnable)
            releaseWakeLock()
        } else if (isActive) {
            scheduleWakeAlarm()
            releaseWakeLock()
        }
        // Push the current figures right away so the UI is fresh on wake. The
        // peer links are re-read too: after a long sleep the supervisor may not
        // have ticked yet and the latency column would stay empty.
        if (interactive) {
            pushStats()
            supervisor?.requestCheck()
            requestExitCheck()
        }
    }

    private fun noteDataActivity(bytes: Int) {
        if (screenInteractive) return
        bytesSinceRenew += bytes
        val now = SystemClock.elapsedRealtime()
        if (now - lastActivityAt < DATA_ACTIVITY_REFRESH_MS) return
        if (bytesSinceRenew < DATA_ACTIVITY_MIN_BYTES) return
        bytesSinceRenew = 0
        lastActivityAt = now
        acquireWakeLock()
        mainHandler.removeCallbacks(releaseWakeLockRunnable)
        mainHandler.postDelayed(releaseWakeLockRunnable, DATA_ACTIVITY_WAKE_LOCK_MS)
    }

    private fun acquireWakeLock() {
        val lock = wakeLock ?: run {
            val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
            pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Y-Node::tunnel")
                .apply { setReferenceCounted(false) }
                .also { wakeLock = it }
        }
        try {
            if (!lock.isHeld) lock.acquire()
        } catch (_: Exception) {
        }
    }

    private fun releaseWakeLock() {
        val lock = wakeLock ?: return
        try {
            if (lock.isHeld) lock.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    private fun releaseWakeLockIfIdle() {
        if (!screenInteractive) releaseWakeLock()
    }

    private fun scheduleWakeAlarm() {
        // The alarm exists for one job only: let the peer supervisor notice a
        // peer that died silently and swap it while the phone sleeps. The data
        // path never waits for it — a packet wakes the CPU by itself — and the
        // UI is refreshed from `onScreenStateChanged` the moment the screen
        // comes back. With auto replace off there is nothing to do in the
        // background, so no alarm is scheduled at all.
        if (!prefs.settings().autoReplace) {
            cancelWakeAlarm()
            return
        }
        val manager = getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        wakeAlarm = manager
        val intent = Intent(this, YggVpnService::class.java).setAction(ACTION_WAKEUP)
        val pending = PendingIntent.getService(
            this,
            WAKEUP_REQUEST,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        wakePending = pending
        try {
            manager.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + wakeupIntervalMs(),
                pending,
            )
        } catch (_: Exception) {
        }
    }

    /** A minute of keep-alive normally, five with "Save battery" on. The value
     *  is read from the prefs every time so a toggle applies to the next slot
     *  without waiting for a reconnect. */
    private fun wakeupIntervalMs(): Long =
        if (prefs.settings().energySaving) {
            SCREEN_OFF_WAKEUP_INTERVAL_SAVING_MS
        } else {
            SCREEN_OFF_WAKEUP_INTERVAL_MS
        }

    private fun cancelWakeAlarm() {
        val pending = wakePending ?: return
        try {
            (wakeAlarm ?: getSystemService(Context.ALARM_SERVICE) as? AlarmManager)?.cancel(pending)
        } catch (_: Exception) {
        }
        wakePending = null
    }

    private fun handleWakeup() {
        if (!screenInteractive && isActive && prefs.settings().autoReplace) {
            acquireWakeLock()
            mainHandler.removeCallbacks(releaseWakeLockRunnable)
            mainHandler.postDelayed(releaseWakeLockRunnable, SCREEN_OFF_WAKE_LOCK_MS)
            scheduleWakeAlarm()
        } else {
            cancelWakeAlarm()
        }
    }

    private fun startStats() {
        stopStats()
        statsThread = Thread({
            while (isActive && !stopping) {
                pushStats()
                val sleep = if (screenInteractive && !settings.energySaving) 1000L else 5000L
                try {
                    Thread.sleep(sleep)
                } catch (_: InterruptedException) {
                    return@Thread
                }
            }
        }, "ygg-stats").apply {
            isDaemon = true
            start()
        }
    }

    private fun stopStats() {
        statsThread?.interrupt()
        statsThread = null
    }

    /**
     * Keeps the exit profile health fresh. The bridge only knows a profile is
     * reachable after a connection went through it or after its status API was
     * polled, so without this loop a reconnected tunnel would show "Connecting"
     * until the first public request.
     */
    private fun startExitWatch() {
        stopExitWatch()
        if (!settings.exitActive()) return
        var self: Thread? = null
        self = Thread({
            var first = true
            while (isActive && !stopping && exitWatchThread === self) {
                val current = prefs.settings()
                if (!current.exitActive()) break
                if (first) {
                    // Give the overlay a moment to finish the peer handshakes.
                    try {
                        Thread.sleep(1200L)
                    } catch (_: InterruptedException) {
                        return@Thread
                    }
                    first = false
                    if (!isActive || stopping) break
                }
                try {
                    node.checkExitProfiles(
                        (current.exitProfiles.size * 6000 + 4000).toLong(),
                    )
                } catch (t: Throwable) {
                    ConnectionLog.append("WARN", "exit health check failed: ${t.message}")
                }
                pushStats()
                val sleep = current.healthCheckSec.coerceIn(5, 120) * 1000L
                synchronized(exitSleeper) {
                    if (isActive && !stopping && exitWatchThread === self &&
                        !exitCheckRequested
                    ) {
                        try {
                            exitSleeper.wait(sleep)
                        } catch (_: InterruptedException) {
                            return@Thread
                        }
                    }
                }
                exitCheckRequested = false
            }
        }, "ygg-exit")
        exitWatchThread = self
        self.isDaemon = true
        self.start()
    }

    private fun stopExitWatch() {
        exitWatchThread?.interrupt()
        exitWatchThread = null
    }

    /** Asks the exit health loop to poll right away instead of waiting a tick. */
    private fun requestExitCheck() {
        exitCheckRequested = true
        synchronized(exitSleeper) { exitSleeper.notifyAll() }
    }

    private fun pushStats() {
        val b = bridge ?: return
        val rx = b.rxBytes()
        val tx = b.txBytes()
        val exit = try {
            node.exitStatusJSON
        } catch (_: Throwable) {
            ""
        }
        VpnState.update { it.copy(rxBytes = rx, txBytes = tx, exitStatus = exit) }
        if (screenInteractive || !settings.energySaving) {
            updateNotification()
        }
    }

    // ------------------------------------------------------------------
    // Notification
    // ------------------------------------------------------------------

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.tile_label),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Yggdrasil tunnel status"
            setShowBadge(false)
            enableVibration(false)
        }
        manager.createNotificationChannel(channel)
    }

    /** The second line of the notification: the live figures or the reason. */
    private fun notificationBody(status: String, detail: String): String {
        val snapshot = VpnState.current
        return if (detail.isNotEmpty()) {
            detail
        } else if (status == VpnState.STATUS_CONNECTED) {
            val speed = if (snapshot.status == VpnState.STATUS_CONNECTED) {
                String.format(
                    Locale.US,
                    "↓ %s  ↑ %s",
                    formatBytes(snapshot.rxBytes),
                    formatBytes(snapshot.txBytes),
                )
            } else {
                ""
            }
            "${snapshot.peersUp}/${snapshot.peersTotal} peers · $speed"
        } else {
            snapshot.nodeAddress
        }
    }

    private fun buildNotification(status: String, detail: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, Class.forName("com.yggnode.app.MainActivity"))
                .setFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                ),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, YggVpnService::class.java).setAction(ACTION_DISCONNECT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val title = when (status) {
            VpnState.STATUS_CONNECTED -> "Connected"
            VpnState.STATUS_CONNECTING -> "Connecting…"
            VpnState.STATUS_RECONNECTING -> "Reconnecting…"
            VpnState.STATUS_DISCONNECTING -> "Disconnecting…"
            else -> "Disconnected"
        }
        val body = notificationBody(status, detail)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_tile)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(status != VpnState.STATUS_DISCONNECTED)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(open)
            .apply {
                if (status == VpnState.STATUS_CONNECTED || status == VpnState.STATUS_CONNECTING) {
                    addAction(0, "Disconnect", stop)
                }
            }
            .build()
    }

    private fun goForeground(status: String, detail: String) {
        val notification = buildNotification(status, detail)
        // The posted notification now carries this text; the stats thread must
        // not post the same thing again a moment later.
        lastNotificationKey = "$status|${notificationBody(status, detail)}"
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                try {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                    )
                } catch (t: Throwable) {
                    // A missing manifest declaration or a vendor restriction:
                    // fall back to the untyped call so the tunnel still gets its
                    // foreground slot instead of being killed at once.
                    ConnectionLog.append("WARN", "typed startForeground failed: ${t.message}")
                    startForeground(NOTIFICATION_ID, notification)
                }
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (t: Throwable) {
            ConnectionLog.append("ERROR", "startForeground failed: ${t.message}")
        }
    }

    private fun updateNotification() {
        if (!isActive) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val status = VpnState.current.status
        val key = "$status|${notificationBody(status, "")}"
        if (key == lastNotificationKey) return
        lastNotificationKey = key
        try {
            manager.notify(
                NOTIFICATION_ID,
                buildNotification(status, ""),
            )
        } catch (_: Exception) {
        }
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val units = arrayOf("KB", "MB", "GB", "TB")
        var value = bytes.toDouble() / 1024.0
        var index = 0
        while (value >= 1024.0 && index < units.size - 1) {
            value /= 1024.0
            index++
        }
        return String.format(Locale.US, "%.1f %s", value, units[index])
    }

    private fun appVersion(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName ?: "?"
    } catch (_: Exception) {
        "?"
    }
}
