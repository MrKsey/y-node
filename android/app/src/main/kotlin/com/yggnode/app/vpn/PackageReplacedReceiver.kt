package com.yggnode.app.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

/**
 * Brings the tunnel back after the app itself is updated.
 *
 * Android tears the whole process down on a package replace, so an upgrade
 * silently drops the VPN. The user expects the tunnel to survive it, so the
 * service is started again when it was on before the update.
 */
class PackageReplacedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val prefs = Prefs(context)
        if (prefs.getString(Prefs.KEY_WANTED) != "1") return
        // Give the package manager a moment to settle before asking for the tun.
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                YggVpnService.connect(context)
            } catch (_: Throwable) {
                // A background start may be refused; the user can just tap connect.
            }
        }, RESTART_DELAY_MS)
    }

    private companion object {
        const val RESTART_DELAY_MS = 3_000L
    }
}
