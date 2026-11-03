package com.yggnode.app.vpn

import android.os.Handler
import android.os.Looper
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The connection state shared between the VPN service and the Flutter UI.
 *
 * The service is the only writer; the UI subscribes and receives a snapshot on
 * every change. Keeping the state here rather than in the service means the app
 * still shows the right thing after the activity is recreated.
 */
object VpnState {
    const val STATUS_DISCONNECTED = "disconnected"
    const val STATUS_CONNECTING = "connecting"
    const val STATUS_CONNECTED = "connected"
    const val STATUS_RECONNECTING = "reconnecting"
    const val STATUS_DISCONNECTING = "disconnecting"

    data class Snapshot(
        val status: String = STATUS_DISCONNECTED,
        val stage: String = "",
        val error: String? = null,
        val nodeAddress: String = "",
        val subnet: String = "",
        val publicKey: String = "",
        val rxBytes: Long = 0,
        val txBytes: Long = 0,
        val peersUp: Int = 0,
        val peersTotal: Int = 0,
        val latencyMs: Double = 0.0,
        val connectedAt: Long = 0,
        val dns: String = "",
        val mtu: Int = 1280,
        val peersJson: String = "[]",
        val exitStatus: String = "",
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "status" to status,
            "stage" to stage,
            "error" to error,
            "nodeAddress" to nodeAddress,
            "subnet" to subnet,
            "publicKey" to publicKey,
            "rxBytes" to rxBytes,
            "txBytes" to txBytes,
            "peersUp" to peersUp,
            "peersTotal" to peersTotal,
            "latencyMs" to latencyMs,
            "connectedAt" to connectedAt,
            "dns" to dns,
            "mtu" to mtu,
            "peers" to peersJson,
            "exitStatus" to exitStatus,
        )
    }

    private val main = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArrayList<(Snapshot) -> Unit>()

    @Volatile
    var current: Snapshot = Snapshot()
        private set

    /** Applies a change and notifies the listeners on the main thread. */
    fun update(transform: (Snapshot) -> Snapshot) {
        val next = transform(current)
        if (next == current) return
        current = next
        val payload = next
        main.post {
            for (listener in listeners) {
                try {
                    listener(payload)
                } catch (_: Exception) {
                }
            }
        }
    }

    fun setStatus(status: String, error: String? = null) {
        update { it.copy(status = status, error = error) }
    }

    fun setStage(stage: String) {
        update { it.copy(stage = stage) }
    }

    fun reset() {
        update {
            Snapshot(
                nodeAddress = it.nodeAddress,
                subnet = it.subnet,
                publicKey = it.publicKey,
                mtu = it.mtu,
            )
        }
    }

    fun addListener(listener: (Snapshot) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (Snapshot) -> Unit) {
        listeners.remove(listener)
    }
}
