package com.yggnode.app.vpn

import android.content.Context
import android.content.SharedPreferences

/**
 * The single source of truth for everything the VPN service needs while the
 * Flutter UI is not running. The Dart side reads and writes the same keys
 * through the storage channel, so the two never disagree.
 */
class Prefs(context: Context) {
    private val sp: SharedPreferences =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun getString(key: String): String? = sp.getString(key, null)

    fun putString(key: String, value: String) {
        sp.edit().putString(key, value).apply()
    }

    fun remove(key: String) {
        sp.edit().remove(key).apply()
    }

    fun snapshot(): Map<String, String> {
        val out = HashMap<String, String>()
        for ((k, v) in sp.all) {
            if (v is String) out[k] = v
        }
        return out
    }

    fun settings(): Settings = Settings.fromJson(getString(KEY_SETTINGS))

    fun saveSettings(settings: Settings) = putString(KEY_SETTINGS, settings.toJson().toString())

    fun peers(): List<PeerEntry> = PeerEntry.listFromJson(getString(KEY_PEERS))

    fun savePeers(peers: List<PeerEntry>) = putString(KEY_PEERS, PeerEntry.listToJson(peers))

    fun pool(): List<PeerEntry> = PeerEntry.listFromJson(getString(KEY_POOL))

    fun savePool(pool: List<PeerEntry>) = putString(KEY_POOL, PeerEntry.listToJson(pool))

    /** The last error seen for each peer, so it survives a recovered link. */
    fun peerErrors(): MutableMap<String, PeerErrorRecord> =
        PeerErrorRecord.mapFromJson(getString(KEY_PEER_ERRORS))

    fun savePeerErrors(errors: Map<String, PeerErrorRecord>) =
        putString(KEY_PEER_ERRORS, PeerErrorRecord.mapToJson(errors))

    fun identity(): Identity? = Identity.fromJson(getString(KEY_IDENTITY))

    fun saveIdentity(identity: Identity) =
        putString(KEY_IDENTITY, identity.toJson().toString())

    fun splitApps(): List<String> {
        val raw = getString(KEY_SPLIT_APPS) ?: return emptyList()
        return try {
            val arr = org.json.JSONArray(raw)
            buildList { for (i in 0 until arr.length()) add(arr.optString(i)) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun saveSplitApps(apps: List<String>) =
        putString(KEY_SPLIT_APPS, org.json.JSONArray(apps).toString())

    /** True when the user has already completed the first-run wizard. */
    fun isOnboarded(): Boolean = getString(KEY_ONBOARDED) == "1"

    fun setOnboarded() = putString(KEY_ONBOARDED, "1")

    companion object {
        private const val FILE = "y_node_store"

        const val KEY_SETTINGS = "settings"
        const val KEY_PEERS = "peers"
        const val KEY_POOL = "pool"
        const val KEY_IDENTITY = "identity"
        const val KEY_SPLIT_APPS = "split_apps"
        const val KEY_ONBOARDED = "onboarded"
        const val KEY_BOOK = "book"
        const val KEY_LOCALE = "locale"
        const val KEY_THEME = "theme"
        const val KEY_COUNTRY = "country"
        const val KEY_PEERS_UPDATED = "peers_updated_at"
        const val KEY_PEER_SNAPSHOT = "peers_snapshot"
        const val KEY_PEER_ERRORS = "peer_errors"

        /** "1" while the user wants the tunnel up, "0" after a manual disconnect.
         *  It survives a package replace so the tunnel can be brought back. */
        const val KEY_WANTED = "vpn_wanted"
    }
}
