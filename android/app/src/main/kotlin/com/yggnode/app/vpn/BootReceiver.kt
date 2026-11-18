package com.yggnode.app.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService

/**
 * Brings the app back when the phone boots.
 *
 * Android has no tray: the "minimized" app is the foreground service and its
 * ongoing notification. With "Start with the system" on, the service is started
 * without a window. It connects only when the user asked for it ("Connect on
 * launch") or left the tunnel running before the reboot; otherwise it waits in
 * the notification panel with a Connect action.
 *
 * Nothing happens when the option is off, when the app has no peers or identity
 * yet, or when the VPN consent is missing: the consent dialog can only be shown
 * by the UI, so a boot start without it would only fail.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != ACTION_QUICKBOOT) return

        val prefs = Prefs(context)
        val settings = prefs.settings()
        if (!settings.startOnBoot) return
        if (prefs.peers().isEmpty() || prefs.identity() == null) return

        val connect = prefs.getString(Prefs.KEY_WANTED) == "1" || settings.connectOnLaunch
        if (connect && VpnService.prepare(context) != null) return

        try {
            YggVpnService.start(context, connect)
        } catch (_: Throwable) {
            // Android may refuse a background start; the user can open the app.
        }
    }

    private companion object {
        /** Some vendors send this instead of BOOT_COMPLETED. */
        const val ACTION_QUICKBOOT = "android.intent.action.QUICKBOOT_POWERON"
    }
}
