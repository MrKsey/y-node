package com.yggnode.app.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper

/**
 * Watches the underlying (non-VPN) networks and reports when one appears or goes
 * away.
 *
 * A Yggdrasil link is a TCP/QUIC connection bound to whatever network was up when
 * it was dialled. Switching from Wi-Fi to mobile data therefore breaks every
 * link, and without this the tunnel would stay "connected" while carrying
 * nothing. Knowing about the change lets the service ask the node to dial again
 * on the new network.
 *
 * Only Wi-Fi, cellular and ethernet are watched, so the callbacks never fire for
 * our own VPN interface.
 */
class NetworkMonitor(
    context: Context,
    private val onChanged: (String) -> Unit,
) {
    private val manager = context.getSystemService(ConnectivityManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val known = mutableSetOf<Network>()

    @Volatile
    private var primed = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val isNew = synchronized(known) { known.add(network) }
            if (isNew) notify("available ${describe(network)}")
        }

        override fun onLost(network: Network) {
            val removed = synchronized(known) { known.remove(network) }
            if (removed) notify("lost ${describe(network)}")
        }
    }

    private fun describe(network: Network): String {
        val caps = try {
            manager?.getNetworkCapabilities(network)
        } catch (_: Exception) {
            null
        } ?: return "network"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "network"
        }
    }

    private fun notify(reason: String) {
        if (!primed) return
        onChanged(reason)
    }

    fun start() {
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        try {
            manager?.registerNetworkCallback(request, callback)
        } catch (_: Exception) {
            // A missing ConnectivityManager must never crash the service.
        }
        handler.postDelayed({ primed = true }, PRIME_DELAY_MS)
    }

    fun stop() {
        try {
            manager?.unregisterNetworkCallback(callback)
        } catch (_: Exception) {
        }
        synchronized(known) { known.clear() }
    }

    /** True when at least one underlying network is currently available. */
    fun hasNetwork(): Boolean = synchronized(known) { known.isNotEmpty() }

    private companion object {
        const val PRIME_DELAY_MS = 1_000L
    }
}
