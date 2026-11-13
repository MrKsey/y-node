package com.yggnode.app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings as AndroidSettings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.yggnode.app.vpn.AppCatalog
import com.yggnode.app.vpn.ConnectionLog
import com.yggnode.app.vpn.PeerEntry
import com.yggnode.app.vpn.Prefs
import com.yggnode.app.vpn.VpnState
import com.yggnode.app.vpn.YggVpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import java.util.concurrent.Executors
import yggnode.Yggnode

/**
 * Hosts the Flutter UI and the three channels it uses:
 *
 *  - `vpn`     commands: prepare, connect, disconnect, state, peers, probes;
 *  - `status`  a stream of [VpnState] snapshots;
 *  - `storage` a tiny key/value store shared with the VPN service.
 *
 * All the tunnel work happens in [YggVpnService]; this activity only forwards
 * commands and, when Android asks for it, shows the VPN permission dialog.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val VPN_CHANNEL = "com.yggnode.app/vpn"
        private const val STATUS_CHANNEL = "com.yggnode.app/status"
        private const val STORAGE_CHANNEL = "com.yggnode.app/storage"

        private const val REQUEST_PREPARE = 1001
        private const val REQUEST_NOTIFICATIONS = 1002
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Everything that talks to the Go node or to Android goes here. It used to
     * be one thread for all of it, which meant a long peer probe (minutes on a
     * slow network) held back the app list, the DNS check and the identity: the
     * Apps tab spun forever and the first connect looked dead.
     */
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "ygg-bridge").apply { isDaemon = true }
    }

    /** Peer probes only. Kept apart so a discovery never blocks the UI calls. */
    private val probeWorker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "ygg-probe").apply { isDaemon = true }
    }

    private lateinit var prefs: Prefs
    private var pendingPrepare: MethodChannel.Result? = null

    private val goLogger = object : yggnode.Logger {
        override fun log(level: String, message: String) {
            ConnectionLog.append("YGG/${level.uppercase()}", message)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        prefs = Prefs(this)
        ConnectionLog.init(this, versionName())
        ConnectionLog.enabled = prefs.settings().logging

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, VPN_CHANNEL).setMethodCallHandler { call, result ->
            handleVpnCall(call, result)
        }
        MethodChannel(messenger, STORAGE_CHANNEL).setMethodCallHandler { call, result ->
            handleStorageCall(call, result)
        }
        EventChannel(messenger, STATUS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                private var listener: ((VpnState.Snapshot) -> Unit)? = null

                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    val sink = events ?: return
                    val l: (VpnState.Snapshot) -> Unit = { snapshot ->
                        mainHandler.post {
                            try {
                                sink.success(snapshot.toMap())
                            } catch (_: Exception) {
                            }
                        }
                    }
                    listener = l
                    VpnState.addListener(l)
                    sink.success(VpnState.current.toMap())
                }

                override fun onCancel(arguments: Any?) {
                    listener?.let { VpnState.removeListener(it) }
                    listener = null
                }
            },
        )
    }

    // ------------------------------------------------------------------
    // VPN commands
    // ------------------------------------------------------------------

    private fun handleVpnCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> prepareVpn(result)

            "connect" -> {
                if (prefs.peers().isEmpty()) {
                    result.error("no_peers", "No peers configured", null)
                    return
                }
                try {
                    YggVpnService.connect(this)
                    result.success(true)
                } catch (t: Throwable) {
                    // Android 12+ refuses a foreground service started from the
                    // background; the UI has to know instead of waiting for a
                    // state that never comes.
                    ConnectionLog.append("ERROR", "connect command failed: ${t.message}")
                    result.error("connect_failed", t.message, null)
                }
            }

            "disconnect" -> {
                try {
                    YggVpnService.disconnect(this)
                    result.success(true)
                } catch (t: Throwable) {
                    ConnectionLog.append("ERROR", "disconnect command failed: ${t.message}")
                    result.error("disconnect_failed", t.message, null)
                }
            }

            "getState" -> result.success(VpnState.current.toMap())

            "applyPeers" -> {
                val peers = PeerEntry.listFromJson(call.argument<String>("peers"))
                val pool = PeerEntry.listFromJson(call.argument<String>("pool"))
                // The store is what a connect reads, so it is written here; the
                // running supervisor is updated on the worker because that call
                // goes into the Go node. The answer waits for the supervisor:
                // the UI applies an exit switch right after this call, and a
                // disconnect racing with it must not restore the old peer list.
                prefs.savePeers(peers)
                prefs.savePool(pool)
                worker.execute {
                    YggVpnService.applyPeers(peers, pool)
                    mainHandler.post {
                        try {
                            result.success(null)
                        } catch (_: Exception) {
                            // The activity went away while the peers were applied.
                        }
                    }
                }
            }

            "probePeers" -> {
                val uris = call.argument<List<String>>("uris") ?: emptyList()
                val timeout = (call.argument<Int>("timeoutMs") ?: 8000).toLong()
                probeWorker.execute {
                    val json = try {
                        Yggnode.probePeers(JSONArray(uris).toString(), timeout, goLogger)
                    } catch (t: Throwable) {
                        ConnectionLog.append("ERROR", "probe failed: ${t.message}")
                        "[]"
                    }
                    mainHandler.post {
                        try {
                            result.success(json)
                        } catch (_: Exception) {
                            // The activity went away while the probe was running.
                        }
                    }
                }
            }

            "refreshPeers" -> {
                YggVpnService.refreshPeers()
                result.success(null)
            }

            "checkDns" -> {
                val servers = call.argument<List<String>>("servers") ?: emptyList()
                val timeout = call.argument<Int>("timeoutMs") ?: 4000
                worker.execute {
                    val json = YggVpnService.checkDns(JSONArray(servers).toString(), timeout)
                    mainHandler.post { result.success(json) }
                }
            }

            "fetchUrl" -> {
                val url = call.argument<String>("url") ?: ""
                val timeout = call.argument<Int>("timeoutMs") ?: 20000
                if (url.isEmpty()) {
                    result.error("bad_url", "The URL is empty", null)
                    return
                }
                worker.execute {
                    val json = YggVpnService.fetchUrl(url, timeout)
                    mainHandler.post { result.success(json) }
                }
            }

            "exitStatus" -> worker.execute {
                val json = YggVpnService.exitStatus()
                mainHandler.post { result.success(json) }
            }

            "applyExitConfig" -> worker.execute {
                val applied = YggVpnService.applyExitConfig()
                mainHandler.post { result.success(applied) }
            }

            "checkExit" -> {
                val timeout = call.argument<Int>("timeoutMs") ?: 8000
                worker.execute {
                    val json = YggVpnService.checkExitProfiles(timeout)
                    mainHandler.post { result.success(json) }
                }
            }

            "testExitUdp" -> {
                val timeout = call.argument<Int>("timeoutMs") ?: 15000
                worker.execute {
                    val json = YggVpnService.testExitUdp(timeout)
                    mainHandler.post { result.success(json) }
                }
            }

            "testExitIpv6" -> {
                val timeout = call.argument<Int>("timeoutMs") ?: 15000
                worker.execute {
                    val json = YggVpnService.testExitIPv6(timeout)
                    mainHandler.post { result.success(json) }
                }
            }

            "publicIp" -> {
                val via = call.argument<String>("via") ?: "exit"
                val timeout = call.argument<Int>("timeoutMs") ?: 12000
                worker.execute {
                    val json = YggVpnService.publicIp(via, timeout)
                    mainHandler.post { result.success(json) }
                }
            }

            "registerExit" -> {
                val profileId = call.argument<String>("profileId") ?: ""
                val invite = call.argument<String>("invite") ?: ""
                if (invite.isBlank()) {
                    result.error("invite_missing", "The invite token is empty", null)
                    return
                }
                worker.execute {
                    val json = YggVpnService.registerExit(profileId, invite)
                    mainHandler.post { result.success(json) }
                }
            }

            "generateIdentity" -> worker.execute {
                val identity = try {
                    val generated = Yggnode.generateKey()
                    val key = org.json.JSONObject(generated).optString("privateKey")
                    Yggnode.summaryForPrivateKey(key)
                } catch (t: Throwable) {
                    """{"error":"${t.message}"}"""
                }
                mainHandler.post { result.success(identity) }
            }

            "getLog" -> worker.execute {
                // Up to 512 KB from the disk: never on the main thread.
                val text = ConnectionLog.read()
                mainHandler.post { result.success(text) }
            }
            "clearLog" -> worker.execute {
                ConnectionLog.clear()
                mainHandler.post { result.success(null) }
            }

            "logPath" -> result.success(ConnectionLog.path())
            "logSize" -> result.success(ConnectionLog.sizeBytes())

            "setLogging" -> {
                ConnectionLog.enabled = call.argument<Boolean>("enabled") ?: true
                result.success(null)
            }

            "listApps" -> worker.execute {
                val apps = AppCatalog.list(this).map {
                    mapOf(
                        "package" to it.packageName,
                        "label" to it.label,
                        "system" to it.isSystem,
                    )
                }
                mainHandler.post { result.success(apps) }
            }

            "appIcon" -> {
                val pkg = call.argument<String>("package") ?: ""
                worker.execute {
                    val bytes = AppCatalog.icon(this, pkg)
                    mainHandler.post { result.success(bytes) }
                }
            }

            "defaultBrowser" -> worker.execute {
                val packageName = try {
                    val intent = Intent(
                        Intent.ACTION_VIEW,
                        Uri.parse("https://example.com"),
                    ).addCategory(Intent.CATEGORY_BROWSABLE)
                    @Suppress("DEPRECATION")
                    val resolved = packageManager.resolveActivity(
                        intent,
                        PackageManager.MATCH_DEFAULT_ONLY,
                    )
                    resolved?.activityInfo?.packageName ?: ""
                } catch (_: Throwable) {
                    ""
                }
                mainHandler.post { result.success(packageName) }
            }

            "isBatteryExempt" -> result.success(isBatteryExempt())

            "requestBatteryExemption" -> {
                requestBatteryExemption()
                result.success(null)
            }

            "openBatteryOptimizationList" -> {
                try {
                    startActivity(Intent(AndroidSettings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                } catch (t: Throwable) {
                    ConnectionLog.append("WARN", "battery settings unavailable: ${t.message}")
                }
                result.success(null)
            }

            "hasNotificationPermission" -> result.success(hasNotificationPermission())

            "requestNotifications" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    !hasNotificationPermission()
                ) {
                    ActivityCompat.requestPermissions(
                        this,
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        REQUEST_NOTIFICATIONS,
                    )
                }
                result.success(null)
            }

            "openAppSettings" -> {
                val intent = Intent(AndroidSettings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.fromParts("package", packageName, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                result.success(null)
            }

            "yggVersion" -> worker.execute {
                // The first call into the Go runtime loads the shared library
                // and can take a moment; it must not block the main thread and
                // with it every other platform channel.
                val version = try {
                    Yggnode.getVersion()
                } catch (_: Throwable) {
                    ""
                }
                mainHandler.post { result.success(version) }
            }
            "appVersion" -> result.success(versionName())

            else -> result.notImplemented()
        }
    }

    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = try {
            VpnService.prepare(this)
        } catch (t: Throwable) {
            result.error("prepare_failed", t.message, null)
            return
        }
        if (intent == null) {
            result.success(true)
            return
        }
        if (pendingPrepare != null) {
            // A dialog whose result never arrived (the activity was recreated
            // while it was open) must not block every later attempt.
            pendingPrepare?.success(false)
            pendingPrepare = null
        }
        pendingPrepare = result
        try {
            startActivityForResult(intent, REQUEST_PREPARE)
        } catch (t: Throwable) {
            pendingPrepare = null
            result.error("prepare_failed", t.message, null)
        }
    }

    @Deprecated("FlutterActivity uses the platform result callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PREPARE) return
        val result = pendingPrepare ?: return
        pendingPrepare = null
        result.success(resultCode == Activity.RESULT_OK)
    }

    override fun onResume() {
        super.onResume()
        // On Android 12 the VPN consent dialog can come back without a result
        // (the activity may be recreated behind it). If the permission is
        // already granted, finish the waiting call here.
        val result = pendingPrepare ?: return
        val intent = try {
            VpnService.prepare(this)
        } catch (_: Throwable) {
            null
        }
        if (intent == null) {
            pendingPrepare = null
            result.success(true)
        }
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    private fun handleStorageCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "get" -> {
                val key = call.argument<String>("key") ?: ""
                result.success(prefs.getString(key))
            }

            "put" -> {
                val key = call.argument<String>("key") ?: ""
                val value = call.argument<String>("value") ?: ""
                prefs.putString(key, value)
                if (key == Prefs.KEY_SETTINGS) {
                    ConnectionLog.enabled = prefs.settings().logging
                }
                result.success(null)
            }

            "remove" -> {
                prefs.remove(call.argument<String>("key") ?: "")
                result.success(null)
            }

            "all" -> result.success(prefs.snapshot())

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private fun isBatteryExempt(): Boolean {
        val pm = getSystemService(POWER_SERVICE) as? PowerManager ?: return true
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestBatteryExemption() {
        if (isBatteryExempt()) return
        try {
            val intent = Intent(AndroidSettings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                .setData(Uri.parse("package:$packageName"))
            startActivity(intent)
        } catch (_: Exception) {
            try {
                startActivity(Intent(AndroidSettings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (_: Exception) {
            }
        }
    }

    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun versionName(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName ?: "?"
    } catch (_: Exception) {
        "?"
    }

    override fun onDestroy() {
        pendingPrepare?.let {
            pendingPrepare = null
            it.error("cancelled", "The activity was closed", null)
        }
        super.onDestroy()
    }
}
