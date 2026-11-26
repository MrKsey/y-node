package com.yggnode.app.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.PowerManager

/**
 * Tracks whether the screen is on.
 *
 * The tunnel keeps running either way, but the work that exists only for the UI
 * — the per-second traffic reporter and the notification redraw — is suspended
 * while the screen is off, so an idle tunnel does not wake the CPU once a second.
 *
 * ACTION_SCREEN_ON/OFF cannot be declared in the manifest, so the receiver is
 * registered for as long as the service lives.
 */
class ScreenStateMonitor(
    private val context: Context,
    private val onChanged: (Boolean) -> Unit,
) {
    private val powerManager =
        context.getSystemService(Context.POWER_SERVICE) as? PowerManager

    @Volatile
    var isInteractive: Boolean = powerManager?.isInteractive ?: true
        private set

    private var registered = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_ON -> update(true)
                Intent.ACTION_SCREEN_OFF -> update(false)
                // Delivered when the user unlocks the phone. Some vendor builds
                // drop ACTION_SCREEN_ON after a deep sleep but still send this
                // one, and by the time the window is opened the phone is always
                // unlocked: the second signal costs nothing and ends the
                // "exit node only" mode before the app is even visible.
                Intent.ACTION_USER_PRESENT -> update(true)
            }
        }
    }

    private fun update(interactive: Boolean) {
        if (interactive == isInteractive) return
        isInteractive = interactive
        onChanged(interactive)
    }

    fun start() {
        if (registered) return
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        try {
            context.registerReceiver(receiver, filter)
            registered = true
        } catch (_: Exception) {
        }
        isInteractive = powerManager?.isInteractive ?: true
    }

    fun stop() {
        if (!registered) return
        try {
            context.unregisterReceiver(receiver)
        } catch (_: Exception) {
        }
        registered = false
    }

    /**
     * Re-reads the real screen state. Some vendor builds miss
     * ACTION_SCREEN_ON after a deep sleep, and the cached value would keep the
     * service at the background pace with the "exit node only" peers still
     * dropped. A changed value runs the same path a real broadcast would.
     */
    fun refresh() {
        update(powerManager?.isInteractive ?: true)
    }
}
