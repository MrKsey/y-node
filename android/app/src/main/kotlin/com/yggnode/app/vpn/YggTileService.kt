package com.yggnode.app.vpn

import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick Settings tile: one tap connects or disconnects.
 *
 * When the VPN permission has not been granted yet the tile cannot show the
 * system dialog itself, so it opens it as an activity and the user confirms
 * there.
 */
class YggTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        val status = VpnState.current.status
        if (status == VpnState.STATUS_CONNECTED ||
            status == VpnState.STATUS_CONNECTING ||
            status == VpnState.STATUS_RECONNECTING
        ) {
            YggVpnService.disconnect(this)
        } else {
            val permission = VpnService.prepare(this)
            if (permission != null) {
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        startActivityAndCollapse(
                            PendingIntent.getActivity(
                                this,
                                0,
                                permission,
                                PendingIntent.FLAG_IMMUTABLE,
                            ),
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        startActivityAndCollapse(permission)
                    }
                } catch (_: Exception) {
                }
            } else {
                YggVpnService.connect(this)
            }
        }
        updateTile()
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        val status = VpnState.current.status
        tile.state = when (status) {
            VpnState.STATUS_CONNECTED,
            VpnState.STATUS_CONNECTING,
            VpnState.STATUS_RECONNECTING,
            -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        tile.label = "Y-Node"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = when (status) {
                VpnState.STATUS_CONNECTED -> "Connected"
                VpnState.STATUS_CONNECTING -> "Connecting"
                VpnState.STATUS_RECONNECTING -> "Reconnecting"
                else -> "Off"
            }
        }
        tile.updateTile()
    }
}
