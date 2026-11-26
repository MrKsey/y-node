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
import org.json.JSONArray
import org.json.JSONObject
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

        /** Starts the service without a tunnel: the app comes back in the
         *  notification panel after a boot and waits for the user. */
        const val ACTION_IDLE = "com.yggnode.app.action.IDLE"

        /** Marks a connect that came from the panel instead of the UI. A
         *  failure then has to stay visible: the activity is not on screen to
         *  show the error. */
        const val EXTRA_FROM_PANEL = "com.yggnode.app.extra.FROM_PANEL"

        private const val CHANNEL_ID = "y_node_tunnel"
        private const val ALERTS_CHANNEL_ID = "y_node_alerts"
        private const val NOTIFICATION_ID = 1001
        private const val FAILURE_NOTIFICATION_ID = 1002
        private const val WAKEUP_REQUEST = 42

        /** How many times the tun is requested before the connect is given up.
         *  Right after a reboot the system can refuse the interface for a
         *  moment, and the panel action used to fail on the first try. */
        private const val ESTABLISH_ATTEMPTS = 3
        private const val ESTABLISH_RETRY_MS = 1_500L

        /** While the screen is off the CPU is allowed to suspend, and the Go
         *  timers of the node — the peer supervisor and the exit health loop —
         *  then run only when something else wakes the device. The alarm buys
         *  them a short slot every five minutes; traffic wakes the CPU by
         *  itself, so this is a keep-alive for the idle case, not part of the
         *  data path. A dead peer is allowed to sit for a while at night: the
         *  data path only needs one live link, and the supervisor swaps the
         *  rest on the next slot. */
        private const val SCREEN_OFF_WAKEUP_INTERVAL_MS = 300_000L

        /** With "Save battery" the timers are allowed to lag much more: the
         *  tunnel itself does not depend on them, only their freshness does. */
        private const val SCREEN_OFF_WAKEUP_INTERVAL_SAVING_MS = 900_000L

        /** How long the screen may stay off before the peer links are recreated
         *  on wake. Shorter sleeps are handled by the wake alarm; a longer one
         *  can leave a TCP link in a state the core never notices. */
        private const val SLEEP_RESTART_MS = 120_000L

        /** How often a sleeping service re-reads the real screen state. Some
         *  vendor builds drop ACTION_SCREEN_ON after a deep sleep, and the
         *  cached "off" value then keeps the UI timers parked and the peers of
         *  the "exit node only" mode dropped until the window is opened. The
         *  poll is a flag read on the main thread; it does not keep the CPU up. */
        private const val SCREEN_POLL_MS = 15_000L

        /** Consecutive exit health polls that may find the node unreachable
         *  before its link is recreated. One failed poll can be a hiccup. */
        private const val EXIT_UNREACHABLE_BEFORE_RESTART = 2

        /** The first wait after an exit link was recreated, and the cap it
         *  doubles up to while the exit stays unreachable. A node that is
         *  really offline must not be redialled every minute. */
        private const val EXIT_LINK_RESTART_MS = 60_000L
        private const val EXIT_LINK_RESTART_MAX_MS = 300_000L

        /** Long enough for one round of Go timers to run, short enough not to
         *  keep the CPU up for a noticeable share of the interval. */
        private const val SCREEN_OFF_WAKE_LOCK_MS = 4_000L
        private const val DATA_ACTIVITY_REFRESH_MS = 1_000L

        /** How long the CPU is kept up after a burst of traffic with the screen
         *  off. The lock is renewed by every further burst, so a download keeps
         *  the CPU up for as long as it runs and the speed is never limited;
         *  the value only decides how long the tail after the last packet is
         *  covered, and a long tail is pure battery. */
        private const val DATA_ACTIVITY_WAKE_LOCK_MS = 3_000L
        private const val DATA_ACTIVITY_MIN_BYTES = 16 * 1024

        /** How often the figures in the panel are refreshed while the window is
         *  hidden. The screen is on, so the notification is visible, but a
         *  byte counter does not need a per-second redraw: every post rebuilds
         *  the remote views of the panel. */
        private const val HIDDEN_STATS_INTERVAL_MS = 30_000L

        /** How often the peer links are read while the window is hidden but the
         *  screen is on. The data path never waits for the supervisor: it only
         *  swaps a peer that died, and a minute of delay costs nothing while
         *  nobody watches the list. */
        private const val HIDDEN_PEER_INTERVAL_MS = 60_000L

        /** A background pool refill is a probe run: five candidates per round,
         *  eight seconds each, and at most a minute of it in total. */
        private const val POOL_PROBE_BATCH = 5
        private const val POOL_PROBE_TIMEOUT_MS = 8_000L
        private const val POOL_PROBE_BUDGET_MS = 60_000L

        /** How often the spanning tree is read for the transit counter. The
         *  number only moves when a peer changes its parent, so a few seconds
         *  of lag cost nothing. */
        private const val TRANSIT_INTERVAL_MS = 10_000L

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

        /** Re-reads the peer state and waits for the supervisor to finish the
         *  tick, so the UI can show the fresh list instead of a toast that
         *  arrives before anything was read. */
        fun refreshPeersBlocking(timeoutMs: Int): Boolean {
            val supervisor = instance?.supervisor ?: return false
            return supervisor.requestCheckAndWait(timeoutMs.toLong())
        }

        /**
         * The window came back on screen. The service does not keep a reference
         * to the activity: this one call is enough to give the first frame real
         * figures instead of the ones from the moment it went away.
         */
        fun onUiShown() {
            instance?.applyUiShown()
        }

        /** The window is gone again: the timers may fall back to the slow pace. */
        fun onUiHidden() {
            instance?.applyUiHidden()
        }

        /**
         * Leaves the notification panel when the service only waits there: the
         * app was started at boot and the user turned that option off. A running
         * tunnel is never touched by this.
         */
        fun stopIdle() {
            val service = instance ?: return
            if (!service.idle) return
            service.idle = false
            service.stopForeground(STOP_FOREGROUND_REMOVE)
            service.stopSelf()
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
                // The heading names the selected node: repaint it at once
                // instead of waiting for the next stats tick.
                service.updateNotification()
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
        fun registerExit(profileId: String, invite: String, label: String = ""): String {
            val service = instance
                ?: return """{"ok":false,"error":"vpn_not_running"}"""
            val version = try {
                service.appVersion()
            } catch (_: Throwable) {
                "?"
            }
            val device = deviceName()
            val effectiveLabel = label.trim().ifEmpty { device }.take(32)
            return try {
                service.node.registerExit(
                    profileId,
                    invite,
                    device,
                    version,
                    effectiveLabel,
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

        /**
         * Starts the service from a system event. With [connect] false it only
         * waits in the notification panel: that is what "start with the system"
         * means on Android, where the app has no tray.
         */
        fun start(context: Context, connect: Boolean) {
            val action = if (connect) ACTION_CONNECT else ACTION_IDLE
            val intent = Intent(context, YggVpnService::class.java).setAction(action)
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

    /** A background probe can run for a minute. It must never queue behind, or
     *  in front of, a connect or a teardown on [worker]: a disconnect has to
     *  happen at once even while the pool is being refilled. */
    private val poolWorker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "ygg-pool").apply { isDaemon = true }
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

    /** Guards the sleep of the stats loop so a visible window can cut it short. */
    private val statsSleeper = Object()

    /** Guards the sleep of the exit health loop so a wake can cut it short. */
    private val exitSleeper = Object()

    @Volatile
    private var exitCheckRequested = false

    @Volatile
    private var screenInteractive = true

    @Volatile
    private var stopping = false

    /** True while the service waits in the notification panel without a
     *  tunnel, which is how the app runs after a boot with the switch on. */
    @Volatile
    private var idle = false

    /** True when the tunnel was closed because the screen went off and the
     *  user asked for that. The service stays in the panel: its screen
     *  receiver is the only way to hear that the screen is back, because
     *  ACTION_SCREEN_ON cannot be declared in the manifest. */
    @Volatile
    private var screenPaused = false

    /** When the screen went off, in elapsed-realtime millis. A long sleep can
     *  leave the peer links in a half-dead TCP state: the core has no keep-alive
     *  and no read deadline, so the links are recreated when the screen is back
     *  after [SLEEP_RESTART_MS]. Zero means the screen is on or the service was
     *  started with the screen already off. */
    private var screenOffAt = 0L

    /** True while the screen-off poll of [screenPollRunnable] is scheduled. */
    private var screenPollScheduled = false

    /** Consecutive exit health polls that found the active profile unreachable. */
    private var exitUnreachableCount = 0

    /** Earliest time the exit link may be recreated again, elapsed-realtime
     *  millis. A node that is really offline must not be redialled every poll. */
    private var nextExitLinkRestartAt = 0L

    /** The wait after an exit link restart, doubled while the exit stays down. */
    private var exitLinkRestartBackoffMs = EXIT_LINK_RESTART_MS

    /** How many nodes route their traffic through this one. Read from the
     *  spanning tree on the stats tick and shown in Diagnostics. */
    private var transitPeers = 0
    private var lastTransitAt = 0L

    /** True once the Go node of this service instance was started. The node
     *  has to be stopped on every teardown: a connect that failed after it was
     *  started used to leave it running, and the next attempt then started a
     *  second node with the same identity. */
    @Volatile
    private var nodeStarted = false

    /** True when the running connect was requested from the panel. */
    @Volatile
    private var panelConnect = false

    @Volatile
    private var lastEstablishedAt = 0L

    /** True while a background pool refill is running on the worker. */
    @Volatile
    private var poolRefillRunning = false

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

    /** When the last stats snapshot was built, in elapsed-realtime millis. */
    private var lastStatsPushAt = 0L

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
        // A null intent means Android restarted the sticky service. A tunnel the
        // user left on comes back; an app started at boot keeps waiting in the
        // panel instead of connecting behind the user's back.
        val action = intent?.action ?: stickyAction()
        ConnectionLog.append("SERVICE", "start command: $action")

        return when (action) {
            ACTION_CONNECT -> {
                // The five second foreground deadline is unforgiving: show the
                // notification before doing anything slow.
                idle = false
                // An explicit connect overrides a pause for the screen.
                screenPaused = false
                panelConnect = intent?.getBooleanExtra(EXTRA_FROM_PANEL, false) == true
                goForeground(VpnState.STATUS_CONNECTING, "")
                stopRequested = false
                worker.execute { runConnect() }
                START_STICKY
            }

            ACTION_IDLE -> {
                idle = true
                panelConnect = false
                // A restart that skipped the connect only because the screen
                // was off is still a pause: the screen coming back has to
                // rebuild the tunnel. At boot nothing was wanted, so the flag
                // stays off and the panel just waits.
                screenPaused = prefs.getString(Prefs.KEY_WANTED) == "1" &&
                    prefs.settings().screenOffDisconnect &&
                    !screenInteractive
                goForeground(
                    VpnState.STATUS_DISCONNECTED,
                    if (screenPaused) {
                        "Paused while the screen is off"
                    } else {
                        "Waiting in the background"
                    },
                )
                START_STICKY
            }

            ACTION_WAKEUP -> {
                handleWakeup()
                START_STICKY
            }

            else -> {
                // A connect may still be queued: make it stop before it builds
                // anything, then tear down what is already up.
                idle = false
                panelConnect = false
                stopRequested = true
                worker.execute { handleDisconnect(userInitiated = true) }
                START_NOT_STICKY
            }
        }
    }

    /** Runs one connect on the worker. A crash here used to kill the thread
     *  and leave the panel on "Connecting…" for good. */
    private fun runConnect() {
        try {
            handleConnect()
        } catch (t: Throwable) {
            ConnectionLog.append("ERROR", "connect crashed: ${t.message}")
            fail("connect_failed", t.message ?: "Could not start the tunnel")
        }
    }

    /** What a restart without an intent means for this install. */
    private fun stickyAction(): String {
        if (prefs.getString(Prefs.KEY_WANTED) == "1") {
            // A restart with the screen off must not rebuild a tunnel the user
            // asked to keep closed until the screen is back. It stays in the
            // panel and waits for the window instead.
            if (prefs.settings().screenOffDisconnect && !screenInteractive) return ACTION_IDLE
            return ACTION_CONNECT
        }
        return if (prefs.settings().startOnBoot) ACTION_IDLE else ACTION_DISCONNECT
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
            // A node started by an attempt that never reached the data path has
            // no bridge to stop it: leaving it up in a live process started a
            // second node with the same identity on the next connect.
            if (nodeStarted) {
                nodeStarted = false
                try {
                    node.stop()
                } catch (t: Throwable) {
                    ConnectionLog.append("WARN", "node stop failed: ${t.message}")
                }
            }
        }
        worker.shutdown()
        poolWorker.shutdownNow()
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
        idle = false
        if (nodeStarted || node.isRunning) {
            // A connect while a node is still up means either the settings
            // changed (the split-tunnel list is read only on start) or a
            // previous attempt died after starting the node: tear it down and
            // build the link again from the stored settings and peers. Leaving
            // it running started a second node with the same identity, and the
            // exit node then saw two clients for one address, which is why the
            // exit link only came back after a force-stop.
            ConnectionLog.append("SERVICE", "connect with a running node, restarting")
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
            scheduleScreenPoll()
            // The screen may have gone off while the tunnel was still coming
            // up: the screen receiver fired before the supervisor existed, so
            // the two Power switches are applied here as well.
            if (settings.screenOffDisconnect) {
                pauseForScreenOff()
                return
            }
            if (settings.screenOffExitOnly) {
                supervisor?.setExitOnly(true)
            }
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
            // A node from a previous attempt must never stay up: two nodes with
            // one key look like two clients to the exit node.
            if (node.isRunning) {
                ConnectionLog.append("WARN", "the node was still running, stopping it first")
                node.stop()
                nodeStarted = false
            }
            node.start(cfg)
            nodeStarted = true
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
            // The system resolver takes a bare address. A resolver on a
            // non-default port is stored as "[address]:port" and is only
            // reachable through the bridge's DNS router, which understands
            // that form.
            if (server.startsWith("[")) continue
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

        descriptor = establishWithRetry(builder)
        return descriptor != null
    }

    /**
     * Requests the tun interface, retrying a few times. Right after a reboot the
     * system can refuse the interface for a moment: the panel action then failed
     * with `vpn_permission` on its first attempt and the user had to open the
     * app and press Connect again.
     */
    private fun establishWithRetry(builder: Builder): ParcelFileDescriptor? {
        for (attempt in 1..ESTABLISH_ATTEMPTS) {
            try {
                val fd = builder.establish()
                if (fd != null) return fd
                ConnectionLog.append("WARN", "establish returned null (attempt $attempt)")
            } catch (t: Throwable) {
                ConnectionLog.append(
                    "WARN",
                    "establish failed (attempt $attempt): ${t.message}",
                )
            }
            if (attempt < ESTABLISH_ATTEMPTS) {
                try {
                    Thread.sleep(ESTABLISH_RETRY_MS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return null
                }
            }
        }
        return null
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
                // The panel is the only consumer while the window is hidden, and
                // a fresh tick is exactly when its "0/0 peers" line becomes a
                // lie. The key check inside makes a repeat a no-op.
                updateNotification()
            },
            onPoolEmpty = {
                poolWorker.execute { refillPoolFromCache() }
            },
        ).also {
            it.start(peers, prefs.pool())
            // A connect started from the panel can run with the screen already
            // off: the supervisor has to begin at the background pace.
            supervisor = it
            updateSupervisorPace()
        }
    }

    /**
     * Refills an empty replacement pool from the catalogue the UI stored last
     * time it was open. Called by the supervisor when every active peer is
     * down and there is nothing left to swap in: without it a tunnel that lost
     * all its peers overnight stayed dead until the user opened the app.
     *
     * The probe is the same one the Peers screen runs, in rounds of five, and
     * the whole run is capped at a minute. It is skipped while the window is
     * visible: the user may be running a probe of their own there.
     */
    private fun refillPoolFromCache() {
        if (poolRefillRunning) return
        poolRefillRunning = true
        try {
            if (!isActive || stopping || VpnState.uiVisible) return
            val settings = prefs.settings()
            if (!settings.autoReplace) return
            val supervisor = supervisor ?: return
            val cached = readCachedPeers()
            if (cached.isEmpty()) {
                ConnectionLog.append("WARN", "the peer pool is empty and there is no cached catalogue")
                return
            }
            val activeUris = supervisor.currentPeers().map { it.uri }.toSet()
            val usedHosts = activeUris.map { hostOf(it) }.toSet()
            val queue = cached.filter {
                it.uri !in activeUris && hostOf(it.uri) !in usedHosts
            }
            if (queue.isEmpty()) {
                ConnectionLog.append("WARN", "the cached catalogue has no unused peer")
                return
            }
            val target = settings.peerCount.coerceAtLeast(2)
            val alive = LinkedHashMap<String, PeerEntry>()
            val deadline = SystemClock.elapsedRealtime() + POOL_PROBE_BUDGET_MS
            var index = 0
            while (index < queue.size && alive.size < target &&
                isActive && !stopping && !VpnState.uiVisible &&
                SystemClock.elapsedRealtime() < deadline
            ) {
                val end = minOf(index + POOL_PROBE_BATCH, queue.size)
                val slice = queue.subList(index, end)
                index = end
                val json = try {
                    Yggnode.probePeers(
                        JSONArray(slice.map { it.uri }).toString(),
                        POOL_PROBE_TIMEOUT_MS,
                        goLogger,
                    )
                } catch (t: Throwable) {
                    ConnectionLog.append("WARN", "pool probe failed: ${t.message}")
                    "[]"
                }
                val results = try {
                    JSONArray(json)
                } catch (_: Exception) {
                    JSONArray()
                }
                for (i in 0 until results.length()) {
                    val o = results.optJSONObject(i) ?: continue
                    if (!o.optBoolean("up", false)) continue
                    val latency = o.optDouble("latencyMs", 0.0)
                    if (latency <= 0.0) continue
                    val uri = o.optString("uri")
                    val peer = slice.firstOrNull { it.uri == uri } ?: continue
                    alive.putIfAbsent(
                        uri,
                        PeerEntry(
                            uri = uri,
                            country = peer.country,
                            city = peer.city,
                            latencyMs = latency,
                        ),
                    )
                }
            }
            if (alive.isEmpty()) {
                ConnectionLog.append("WARN", "the pool refill found no live peer")
                return
            }
            supervisor.applyPool(alive.values.toList())
            supervisor.requestCheck()
            ConnectionLog.append(
                "INFO",
                "pool refilled with ${alive.size} live peer(s) from the cache",
            )
        } finally {
            poolRefillRunning = false
        }
    }

    private data class CachedPeer(
        val uri: String,
        val country: String,
        val city: String,
    )

    /** The catalogue the UI stored on its last run, or an empty list. */
    private fun readCachedPeers(): List<CachedPeer> {
        val raw = prefs.getString(Prefs.KEY_PEER_CACHE) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            buildList {
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val uri = o.optString("uri")
                    if (uri.isBlank()) continue
                    add(
                        CachedPeer(
                            uri = uri,
                            country = o.optString("country"),
                            city = o.optString("city"),
                        ),
                    )
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun hostOf(uri: String): String = try {
        java.net.URI(uri).host?.lowercase() ?: uri
    } catch (_: Exception) {
        uri
    }

    private fun handleDisconnect(userInitiated: Boolean) {
        if (userInitiated) {
            ConnectionLog.append("SERVICE", "disconnect requested by the user")
            prefs.putString(Prefs.KEY_WANTED, "0")
        }
        // A pause for the screen is over as soon as the tunnel is closed for
        // any other reason: the screen coming back must not rebuild a tunnel
        // the user has just switched off.
        screenPaused = false
        stopping = true
        VpnState.setStatus(VpnState.STATUS_DISCONNECTING)
        try {
            teardown(keepState = false)
        } finally {
            // The UI has to leave the "Disconnecting…" state even when one of
            // the pieces below throws while it is being released.
            VpnState.setStatus(VpnState.STATUS_DISCONNECTED)
            isActive = false
            idle = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    /** Releases everything the tunnel owns. Safe to call more than once. */
    private fun teardown(keepState: Boolean) {
        stopStats()
        stopExitWatch()
        cancelWakeAlarm()
        cancelScreenPoll()
        releaseWakeLock()
        supervisor?.stop()
        supervisor = null
        bridge?.stop()
        bridge = null
        closeDescriptor()
        // The bridge stops the node on its way out, but a connect that failed
        // before the data path existed left the node running: the next attempt
        // then started a second node with the same key, and the exit node saw
        // two clients for one address.
        if (nodeStarted) {
            nodeStarted = false
            try {
                node.stop()
            } catch (t: Throwable) {
                ConnectionLog.append("WARN", "node stop failed: ${t.message}")
            }
        }
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
        idle = false
        VpnState.update {
            it.copy(
                status = VpnState.STATUS_DISCONNECTED,
                error = code,
            )
        }
        // A connect started from the panel used to make the notification vanish
        // without a word: the activity was not on screen to show the error, so
        // the user saw the tunnel disappear and had to guess why. Keep a short
        // note that opens the app instead.
        if (panelConnect) {
            panelConnect = false
            notifyFailure(code, message)
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /** A plain, dismissible notification that explains a failed connect. */
    private fun notifyFailure(code: String, message: String) {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val open = PendingIntent.getActivity(
            this,
            3,
            Intent(this, Class.forName("com.yggnode.app.MainActivity"))
                .setFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                ),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val body = if (code == "vpn_permission") {
            "$message. Open Y-Node and allow the VPN connection."
        } else {
            message
        }
        val notification = NotificationCompat.Builder(this, ALERTS_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_tile)
            .setContentTitle("Could not connect")
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_ERROR)
            .setContentIntent(open)
            .build()
        try {
            manager.notify(FAILURE_NOTIFICATION_ID, notification)
        } catch (t: Throwable) {
            ConnectionLog.append("WARN", "failure notification failed: ${t.message}")
        }
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
        val current = prefs.settings()
        if (!interactive) {
            screenOffAt = SystemClock.elapsedRealtime()
            scheduleScreenPoll()
            // The two Power switches own the screen-off state of the tunnel
            // itself; the code below only slows the loops down. Closing the
            // tunnel wins over keeping the exit link: there is nothing to
            // keep a link to once the tunnel is gone.
            if (isActive && !stopping) {
                if (current.screenOffDisconnect) {
                    pauseForScreenOff()
                    return
                }
                if (current.screenOffExitOnly) {
                    // The peer calls go into the Go node, so they belong on the
                    // worker like every other peer edit. The executor keeps
                    // the order of a quick screen off/on pair.
                    supervisor?.let { sup -> worker.execute { sup.setExitOnly(true) } }
                }
            }
        } else {
            cancelScreenPoll()
            val offAt = screenOffAt
            screenOffAt = 0L
            if (screenPaused) {
                resumeFromScreenOff()
                return
            }
            // Restoring the peers is cheap and idempotent: the supervisor
            // keeps the list that was dropped while the screen was off.
            supervisor?.let { sup -> worker.execute { sup.setExitOnly(false) } }
            // The links of a tunnel that just woke come up one by one, and the
            // panel has to follow them instead of waiting out the hidden pace.
            supervisor?.restartWarmUp()
            restartLinksAfterSleep(offAt)
        }
        if (interactive) {
            cancelWakeAlarm()
            mainHandler.removeCallbacks(releaseWakeLockRunnable)
            releaseWakeLock()
        } else if (isActive) {
            // No alarm at all without a tunnel or with auto replace off: the
            // idle app must not wake the phone for work it does not do.
            if (prefs.settings().autoReplace) scheduleWakeAlarm() else cancelWakeAlarm()
            releaseWakeLock()
        }
        // The supervisor checks much less often while the screen is off, and
        // less often again while the window is hidden: a peer that dies is
        // replaced on the next slot, which is plenty when nobody watches the
        // list. Returning to the foreground restores the normal pace.
        updateSupervisorPace()
        // Push the current figures right away so the UI is fresh on wake, but
        // only when there is a UI to refresh: with the screen off the window is
        // hidden and the next visible frame asks for its own round.
        if (interactive && VpnState.uiVisible) {
            applyUiShown()
        } else if (interactive) {
            // The window is not on screen, but the panel is: give the stats
            // loop a tick so the notification shows the numbers from this
            // moment instead of the ones from before the sleep.
            wakeStats()
        }
    }

    /**
     * A long screen-off period can leave the peer links half-dead: Android may
     * freeze the network while the device sleeps, and the Yggdrasil core has no
     * keep-alive or read deadline on a TCP link, so it keeps writing into a
     * socket that carries nothing. Recreating the links is the only way back
     * without tearing the whole tunnel down.
     */
    private fun restartLinksAfterSleep(offAt: Long) {
        if (offAt <= 0L || !isActive || stopping) return
        val slept = SystemClock.elapsedRealtime() - offAt
        if (slept < SLEEP_RESTART_MS) return
        val reason = "screen was off for ${slept / 1000}s"
        ConnectionLog.append("SERVICE", "$reason, restarting the peer links")
        worker.execute {
            val sup = supervisor
            if (sup != null) {
                // The links that survived the sleep are the ones that may hold
                // a socket the network forgot. The peers dropped by the "exit
                // node only" mode are not in this list: restoring them dials
                // them afresh, and restarting a fresh link would only cancel
                // it again.
                val kept = sup.currentPeers()
                sup.setExitOnly(false)
                sup.restartLinks(kept, reason)
            }
            requestExitCheck()
        }
    }

    /**
     * Closes the tunnel for as long as the screen is off. The service itself
     * stays in the notification panel: Android does not deliver
     * ACTION_SCREEN_ON to a manifest receiver, so the running service is the
     * only place that can hear the screen come back.
     */
    private fun pauseForScreenOff() {
        ConnectionLog.append("SERVICE", "screen off, closing the tunnel until the screen is back")
        prefs.noteScreenOffPause()
        screenPaused = true
        scheduleScreenPoll()
        // The teardown joins the node and the data path, so it runs on the
        // worker like every other connect and disconnect. A resume that comes
        // in meanwhile is queued behind it on the same thread.
        worker.execute {
            teardown(keepState = false)
            idle = true
            mainHandler.post {
                // The screen may be back already: the resume has posted its
                // own notification by now, and this one must not overwrite it.
                if (screenPaused) {
                    goForeground(VpnState.STATUS_DISCONNECTED, "Paused while the screen is off")
                }
            }
        }
    }

    /** Rebuilds the tunnel that [pauseForScreenOff] closed. */
    private fun resumeFromScreenOff() {
        if (!screenPaused || stopping || destroyed) return
        screenPaused = false
        idle = false
        panelConnect = false
        stopRequested = false
        ConnectionLog.append("SERVICE", "screen on, rebuilding the tunnel")
        // The status is set here rather than in `handleConnect`, which runs a
        // moment later on the worker: the window is already drawing, and it has
        // to show "Connecting…" instead of the state from before the pause.
        VpnState.setStatus(VpnState.STATUS_CONNECTING)
        goForeground(VpnState.STATUS_CONNECTING, "")
        worker.execute { runConnect() }
    }

    /** One fresh round for a window that just came back on screen. */
    private fun applyUiShown() {
        // The state may have changed while the window was hidden and nobody was
        // listening: a tunnel closed for the screen, peers dropped by the
        // "exit node only" mode. `update` skips the listeners in that case, so
        // the first visible frame is given the current snapshot explicitly.
        // Without this the screen came back showing the tunnel and its peers
        // exactly as they were before the pause.
        VpnState.notifyCurrent()
        // Some vendor builds miss ACTION_SCREEN_ON after a deep sleep, and the
        // cached value then keeps the tunnel at the background pace with the
        // public peers of the "exit node only" mode still dropped. A window
        // that comes back is proof the screen is on: the callback runs the
        // whole wake path, this call included, from a correct state.
        if (!screenInteractive) screenMonitor?.refresh()
        if (!isActive) return
        // Some vendor builds miss ACTION_SCREEN_ON after a deep sleep: the
        // window coming back is the second chance to replace dead links.
        val offAt = screenOffAt
        screenOffAt = 0L
        restartLinksAfterSleep(offAt)
        // The stats loop may be parked in a long screen-off sleep; a visible
        // window needs its first frame at once, not in a minute.
        updateSupervisorPace()
        wakeStats()
        pushStats()
        supervisor?.restartWarmUp()
        requestExitCheck()
    }

    /** The window went away: the supervisor drops to the hidden pace at once. */
    private fun applyUiHidden() {
        updateSupervisorPace()
        wakeStats()
    }

    /** The interval the supervisor has to use for the current visibility. */
    private fun updateSupervisorPace() {
        val supervisor = supervisor ?: return
        val autoReplace = prefs.settings().autoReplace
        supervisor.setUiVisible(VpnState.uiVisible)
        // The "exit node only" mode parks the loop on its own, from the moment
        // the peers are dropped: the pace below is what it returns to once the
        // screen is back.
        supervisor.setPace(
            when {
                // Screen off with auto replace on: one look per wake-up slot,
                // the same one the alarm gives the Go timers.
                !screenInteractive && autoReplace -> wakeupIntervalMs()
                // Screen off and nothing to replace: park the loop completely.
                // Only a real request (the alarm, a new window, a manual
                // refresh) wakes it, so an idle tunnel costs no timer at all.
                !screenInteractive -> -1L
                VpnState.uiVisible -> 0L
                // Hidden window with the screen on: still watched, but once a
                // minute is enough for a list nobody is looking at.
                else -> HIDDEN_PEER_INTERVAL_MS
            },
        )
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
        // UI is refreshed from `onUiShown` the moment the window comes back.
        // Without a tunnel or with auto replace off there is nothing to do in
        // the background, so no alarm is scheduled at all.
        if (!isActive || !prefs.settings().autoReplace) {
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

    /**
     * Re-reads the real screen state while the screen is supposed to be off.
     *
     * ACTION_SCREEN_ON cannot be declared in the manifest, and some vendor
     * builds drop it after a deep sleep. The cached "off" value then keeps the
     * stats loop parked and the public peers of the "exit node only" mode
     * dropped, so the panel shows the figures from before the sleep until the
     * window is opened. The poll runs on the main thread and only reads a flag;
     * in Doze the handler simply fires when the device is up again.
     */
    private val screenPollRunnable = object : Runnable {
        override fun run() {
            screenPollScheduled = false
            if (screenInteractive || stopping) return
            // A paused tunnel needs the signal as much as a running one: the
            // service stays in the panel and only this poll can rebuild it.
            if (!isActive && !screenPaused) return
            screenMonitor?.refresh()
            if (!screenInteractive && (isActive || screenPaused)) scheduleScreenPoll()
        }
    }

    private fun scheduleScreenPoll() {
        if (screenPollScheduled) return
        screenPollScheduled = true
        mainHandler.postDelayed(screenPollRunnable, SCREEN_POLL_MS)
    }

    private fun cancelScreenPoll() {
        screenPollScheduled = false
        mainHandler.removeCallbacks(screenPollRunnable)
    }

    private fun handleWakeup() {
        // The alarm is the only wake-up this app gets in Doze, and the cached
        // screen state may be stale when ACTION_SCREEN_ON was lost: re-read the
        // real state before deciding what this slot is for. A screen that is
        // already back runs the whole wake path, this call included.
        screenMonitor?.refresh()
        if (!screenInteractive && isActive && prefs.settings().autoReplace) {
            prefs.noteWakeUp()
            acquireWakeLock()
            mainHandler.removeCallbacks(releaseWakeLockRunnable)
            mainHandler.postDelayed(releaseWakeLockRunnable, SCREEN_OFF_WAKE_LOCK_MS)
            // The wake lock only keeps the CPU up; the Go loops sleep on their
            // own monitors and would otherwise wait out the rest of their
            // five-minute interval. The slot exists to give them one look at
            // the live links, so they are asked to do it now.
            supervisor?.requestCheck()
            requestExitCheck()
            scheduleWakeAlarm()
        } else {
            cancelWakeAlarm()
        }
    }

    private fun startStats() {
        stopStats()
        statsThread = Thread({
            while (isActive && !stopping) {
                // A throw here used to end the thread for good: the panel kept
                // the figures from that moment until the tunnel was rebuilt.
                try {
                    pushStats()
                } catch (t: Throwable) {
                    ConnectionLog.append("WARN", "stats push failed: ${t.message}")
                }
                // One second only for a visible window without "Save battery":
                // that is the only case where a human watches the counters.
                // With the window hidden the notification is the only consumer,
                // and with the screen off nothing is drawn at all: the loop then
                // waits for `wakeStats` instead of polling, so the CPU is not
                // woken for a snapshot that `pushStats` would throw away.
                val visible = screenInteractive && VpnState.uiVisible
                val sleep = when {
                    // Nothing draws the numbers while the screen is off, so the
                    // loop parks until `wakeStats` and costs no wake-up at all.
                    !screenInteractive -> 0L
                    visible && !settings.energySaving -> 1_000L
                    // Hidden window: the panel is the only consumer and it is
                    // redrawn at `HIDDEN_STATS_INTERVAL_MS` anyway.
                    else -> 15_000L
                }
                synchronized(statsSleeper) {
                    if (!isActive || stopping) return@Thread
                    try {
                        // A zero timeout means "until notified": the screen is
                        // off and there is nothing to report.
                        if (sleep <= 0L) {
                            statsSleeper.wait()
                        } else {
                            statsSleeper.wait(sleep)
                        }
                    } catch (_: InterruptedException) {
                        return@Thread
                    }
                }
            }
        }, "ygg-stats").apply {
            isDaemon = true
            start()
        }
    }

    /** Cuts the sleep of the stats loop short, for a window that just appeared. */
    private fun wakeStats() {
        synchronized(statsSleeper) { statsSleeper.notifyAll() }
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
            var registered = false
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
                if (!registered) {
                    // The first tick can run before the exit peer finished its
                    // handshake. Keep trying on the health ticks until the exit
                    // confirms the registration, otherwise the Clients page of
                    // X-Node keeps the version from the day the invite was
                    // redeemed.
                    registered = refreshRegistration(current)
                }
                val status = try {
                    node.checkExitProfiles(
                        (current.exitProfiles.size * 6000 + 4000).toLong(),
                    )
                } catch (t: Throwable) {
                    ConnectionLog.append("WARN", "exit health check failed: ${t.message}")
                    ""
                }
                noteExitHealth(status)
                pushStats()
                // The health check is an HTTP round trip through the tunnel.
                // With the window hidden it is only kept warm: the data path
                // never waits for it, so one check a minute is plenty. With the
                // screen off even that is more than the tunnel needs — the exit
                // keeps forwarding without the poll — so it runs on the same
                // five-minute slot as the supervisor.
                val base = current.healthCheckSec.coerceIn(5, 120) * 1000L
                val sleep = when {
                    // The same slot as the supervisor: the exit keeps forwarding
                    // without the poll, so this only refreshes its health.
                    !screenInteractive -> maxOf(base, wakeupIntervalMs())
                    VpnState.uiVisible -> base
                    else -> maxOf(base, 60_000L)
                }
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

    /**
     * Sends the device name and the app version to the active exit once per
     * connection. An empty invite is accepted for an address that is already
     * allowlisted, so the exit shows the current version after an app update
     * instead of the one from the day the invite was redeemed. An older exit
     * answers "invite_invalid"; that is harmless and only logged.
     *
     * Returns true when the exit accepted the refresh. A false result makes the
     * health loop retry on its next tick, which covers a peer that was still
     * connecting when the tunnel came up.
     */
    private fun refreshRegistration(current: Settings): Boolean {
        val profile = current.exitProfiles.firstOrNull {
            it.id == current.exitActiveId
        } ?: current.exitProfiles.firstOrNull() ?: return false
        // A profile without a token has not redeemed its invite yet. An empty
        // invite is only accepted for an address that is already allowlisted,
        // so asking here would just fill the exit log with "invite_invalid";
        // the app redeems the stored invite as soon as the tunnel is up.
        if (profile.token.isBlank()) return true
        val device = try {
            Build.MODEL ?: "Android"
        } catch (_: Throwable) {
            "Android"
        }
        return try {
            val raw = node.registerExit(
                profile.id,
                "",
                device,
                appVersion(),
                current.exitLabel(device),
            )
            val ok = JSONObject(raw).optBoolean("ok", false)
            if (!ok) {
                ConnectionLog.append("DEBUG", "registration refresh was refused")
            }
            ok
        } catch (t: Throwable) {
            ConnectionLog.append("WARN", "registration refresh failed: ${t.message}")
            false
        }
    }

    /**
     * Watches the health answer for the active exit and recreates its link when
     * the node stops answering.
     *
     * The Yggdrasil core has no keep-alive and no read deadline on a TCP link,
     * so a link whose path died — the radio slept, the carrier rebound the NAT
     * mapping, the Wi-Fi handover lost the flow — keeps reporting `up` and the
     * node keeps writing into a socket that carries nothing. Nothing in the
     * core ever notices, and the only way back is a fresh dial. The status API
     * poll is the one request that goes through Yggdrasil to the exit, so a
     * poll that cannot reach it is the signal: the pinned link is dropped and
     * dialled again.
     *
     * A node that is really offline is not redialled on every poll: the wait
     * doubles from a minute up to five and resets with the first healthy answer.
     */
    private fun noteExitHealth(raw: String) {
        if (raw.isBlank() || !isActive || stopping) return
        val state = try {
            val status = JSONObject(raw)
            val profiles = status.optJSONArray("profiles") ?: return
            val activeId = status.optString("activeId")
            var active: JSONObject? = null
            for (i in 0 until profiles.length()) {
                val item = profiles.optJSONObject(i) ?: continue
                if (active == null) active = item
                if (activeId.isNotEmpty() && item.optString("id") == activeId) {
                    active = item
                    break
                }
            }
            active?.optString("state").orEmpty()
        } catch (_: Exception) {
            return
        }
        when (state) {
            "online" -> {
                if (exitUnreachableCount > 0) {
                    ConnectionLog.append("INFO", "the exit node answers again")
                }
                exitUnreachableCount = 0
                exitLinkRestartBackoffMs = EXIT_LINK_RESTART_MS
            }
            // "denied" means the exit answered and refused this client: its
            // link is fine, so recreating it would only cost a handshake.
            "unreachable" -> {
                exitUnreachableCount++
                if (exitUnreachableCount < EXIT_UNREACHABLE_BEFORE_RESTART) return
                val now = SystemClock.elapsedRealtime()
                if (now < nextExitLinkRestartAt) return
                nextExitLinkRestartAt = now + exitLinkRestartBackoffMs
                exitLinkRestartBackoffMs =
                    minOf(exitLinkRestartBackoffMs * 2, EXIT_LINK_RESTART_MAX_MS)
                exitUnreachableCount = 0
                ConnectionLog.append(
                    "WARN",
                    "the exit node did not answer, recreating its link",
                )
                worker.execute {
                    val sup = supervisor ?: return@execute
                    val pinned = sup.currentPeers().filter { it.pinned }
                    if (pinned.isEmpty()) return@execute
                    sup.restartLinks(pinned, "the exit node stopped answering")
                }
            }
        }
    }

    /** Asks the exit health loop to poll right away instead of waiting a tick. */
    private fun requestExitCheck() {
        exitCheckRequested = true
        synchronized(exitSleeper) { exitSleeper.notifyAll() }
    }

    private fun pushStats() {
        val b = bridge ?: return
        // Nobody can see the figures with the screen off: the counters live in
        // the bridge and the first visible frame reads them later. Skipping the
        // snapshot keeps the event channel and the main thread quiet during the
        // sleep instead of waking them every few seconds for nothing.
        if (!screenInteractive) return
        val now = SystemClock.elapsedRealtime()
        // The window is hidden but the screen is on: the notification is the
        // only consumer, and a byte counter in the panel does not need a fresh
        // number every second. A visible window keeps the full rate.
        val visible = VpnState.uiVisible
        if (!visible && now - lastStatsPushAt < HIDDEN_STATS_INTERVAL_MS) return
        lastStatsPushAt = now
        val rx = b.rxBytes()
        val tx = b.txBytes()
        val exit = try {
            node.exitStatusJSON
        } catch (_: Throwable) {
            ""
        }
        // How many nodes route through this one. The tree only moves when a
        // peer changes its parent, so reading it once per ten seconds is
        // enough and keeps the stats tick cheap.
        if (visible && now - lastTransitAt >= TRANSIT_INTERVAL_MS) {
            lastTransitAt = now
            transitPeers = try {
                // gomobile exposes the Go int as a long.
                node.transitCount.toInt()
            } catch (_: Throwable) {
                0
            }
        }
        VpnState.update {
            it.copy(
                rxBytes = rx,
                txBytes = tx,
                exitStatus = exit,
                transitPeers = transitPeers,
            )
        }
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
        if (manager.getNotificationChannel(ALERTS_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    ALERTS_CHANNEL_ID,
                    "Connection problems",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "A connect started from the notification failed"
                    setShowBadge(true)
                },
            )
        }
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
            // A quota refusal or an operator suspension is the reason a site
            // stops opening while the tunnel itself stays up, so the panel says
            // it in one short line instead of showing only peer counts.
            if (clientSuspended()) {
                "Suspended by the operator"
            } else if (quotaExhausted()) {
                "Traffic quota exhausted"
            } else {
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
            }
        } else {
            snapshot.nodeAddress
        }
    }

    /**
     * Reads the quota of the active exit profile from the last status poll. The
     * bridge publishes the whole exit status as JSON in [VpnState], so the
     * service needs no extra call to the exit.
     */
    private fun quotaExhausted(): Boolean {
        val raw = VpnState.current.exitStatus
        if (raw.isEmpty()) return false
        return try {
            val status = JSONObject(raw)
            val profiles = status.optJSONArray("profiles") ?: return false
            val activeId = status.optString("activeId")
            for (index in 0 until profiles.length()) {
                val profile = profiles.optJSONObject(index) ?: continue
                // An unset active id means the bridge uses the first profile.
                if (activeId.isNotEmpty() && profile.optString("id") != activeId) continue
                val quota = profile.optJSONObject("quota") ?: return false
                return quota.optBoolean("exhausted")
            }
            false
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Reads the operator block of the active exit profile from the last status
     * poll. A suspended client keeps its tunnel up: only the exit refuses new
     * connections, so the notification must explain the state.
     */
    private fun clientSuspended(): Boolean {
        val raw = VpnState.current.exitStatus
        if (raw.isEmpty()) return false
        return try {
            val status = JSONObject(raw)
            val profiles = status.optJSONArray("profiles") ?: return false
            val activeId = status.optString("activeId")
            for (index in 0 until profiles.length()) {
                val profile = profiles.optJSONObject(index) ?: continue
                if (activeId.isNotEmpty() && profile.optString("id") != activeId) continue
                return profile.optBoolean("suspended")
            }
            false
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * The heading of the notification. A tunnel that sends public traffic
     * through an exit node names it, so the panel shows where the traffic
     * leaves the mesh; without an exit the heading stays short.
     */
    private fun notificationTitle(status: String): String {
        val base = when (status) {
            VpnState.STATUS_CONNECTED -> "Connected"
            VpnState.STATUS_CONNECTING -> "Connecting…"
            VpnState.STATUS_RECONNECTING -> "Reconnecting…"
            VpnState.STATUS_DISCONNECTING -> "Disconnecting…"
            else -> "Disconnected"
        }
        if (status != VpnState.STATUS_CONNECTED) return base
        val current = prefs.settings()
        if (!current.exitActive()) return base
        // An unset active id means the bridge uses the first profile.
        val profile = current.exitProfiles.firstOrNull {
            it.id == current.exitActiveId
        } ?: current.exitProfiles.firstOrNull()
        val name = profile?.name?.trim().orEmpty()
        return if (name.isEmpty()) base else "$base - $name"
    }

    private fun buildNotification(status: String, detail: String): Notification {
        val openIntent = Intent(this, Class.forName("com.yggnode.app.MainActivity"))
            .setFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        val open = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, YggVpnService::class.java).setAction(ACTION_DISCONNECT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        // Without the VPN consent nothing can be established from the panel:
        // Android only shows the consent dialog over an activity, so the action
        // opens the app instead of failing a second later.
        val needsConsent = idle && try {
            VpnService.prepare(this) != null
        } catch (_: Throwable) {
            false
        }
        val start = if (needsConsent) {
            PendingIntent.getActivity(
                this,
                2,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        } else {
            PendingIntent.getService(
                this,
                2,
                Intent(this, YggVpnService::class.java)
                    .setAction(ACTION_CONNECT)
                    .putExtra(EXTRA_FROM_PANEL, true),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val title = if (idle) "Y-Node" else notificationTitle(status)
        val body = notificationBody(status, detail)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_tile)
            .setContentTitle(title)
            .setContentText(body)
            // An idle service is the app itself after a boot: its notification
            // must stay in the panel like the tray icon of the desktop build.
            .setOngoing(idle || status != VpnState.STATUS_DISCONNECTED)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(open)
            .apply {
                if (status == VpnState.STATUS_CONNECTED || status == VpnState.STATUS_CONNECTING) {
                    addAction(0, "Disconnect", stop)
                } else if (idle) {
                    addAction(0, "Connect", start)
                }
            }
            .build()
    }

    /**
     * The text the notification carries. The heading is part of the key: a
     * switch of the exit node changes it while the counters stay the same, and
     * without it the panel would keep the name of the previous node.
     */
    private fun notificationKey(status: String, detail: String): String =
        "$idle|$status|${if (idle) "Y-Node" else notificationTitle(status)}|" +
            notificationBody(status, detail)

    private fun goForeground(status: String, detail: String) {
        val notification = buildNotification(status, detail)
        // The posted notification now carries this text; the stats thread must
        // not post the same thing again a moment later.
        lastNotificationKey = notificationKey(status, detail)
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
        val key = notificationKey(status, "")
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
