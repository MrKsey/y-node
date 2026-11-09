package com.yggnode.app.vpn

import org.json.JSONArray
import org.json.JSONObject

/** One peer, either an active one or a replacement candidate from the pool. */
data class PeerEntry(
    val uri: String,
    val country: String = "",
    val city: String = "",
    val latencyMs: Double = 0.0,
    val tcpRttMs: Double = 0.0,
    val pinned: Boolean = false,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("uri", uri)
        put("country", country)
        put("city", city)
        put("latencyMs", latencyMs)
        put("tcpRttMs", tcpRttMs)
        if (pinned) put("pinned", true)
    }

    companion object {
        fun fromJson(o: JSONObject): PeerEntry = PeerEntry(
            uri = o.optString("uri"),
            country = o.optString("country"),
            city = o.optString("city"),
            latencyMs = o.optDouble("latencyMs", 0.0),
            tcpRttMs = o.optDouble("tcpRttMs", 0.0),
            pinned = o.optBoolean("pinned", false),
        )

        fun listFromJson(raw: String?): List<PeerEntry> {
            if (raw.isNullOrBlank()) return emptyList()
            return try {
                val arr = JSONArray(raw)
                buildList {
                    for (i in 0 until arr.length()) {
                        val o = arr.optJSONObject(i) ?: continue
                        val uri = o.optString("uri")
                        if (uri.isNotBlank()) add(fromJson(o))
                    }
                }
            } catch (_: Exception) {
                emptyList()
            }
        }

        fun listToJson(list: List<PeerEntry>): String {
            val arr = JSONArray()
            list.forEach { arr.put(it.toJson()) }
            return arr.toString()
        }
    }
}

/** The last error a peer reported, kept after the link recovers. */
data class PeerErrorRecord(
    val message: String,
    val lastSeenUnix: Long,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("message", message)
        put("lastSeenUnix", lastSeenUnix)
    }

    companion object {
        fun mapFromJson(raw: String?): MutableMap<String, PeerErrorRecord> {
            if (raw.isNullOrBlank()) return mutableMapOf()
            return try {
                val o = JSONObject(raw)
                val out = mutableMapOf<String, PeerErrorRecord>()
                val keys = o.keys()
                while (keys.hasNext()) {
                    val uri = keys.next()
                    val item = o.optJSONObject(uri) ?: continue
                    val message = item.optString("message")
                    if (message.isBlank()) continue
                    out[uri] = PeerErrorRecord(
                        message = message,
                        lastSeenUnix = item.optLong("lastSeenUnix", 0L),
                    )
                }
                out
            } catch (_: Exception) {
                mutableMapOf()
            }
        }

        fun mapToJson(map: Map<String, PeerErrorRecord>): String {
            val o = JSONObject()
            for ((uri, record) in map) o.put(uri, record.toJson())
            return o.toString()
        }
    }
}

/** One exit node known to the app. The list order is the failover order. */
data class ExitProfile(
    val id: String,
    val name: String,
    val address: String,
    val socksPort: Int = 1080,
    val apiPort: Int = 1080,
    /** API token issued by the exit; empty until the first registration. */
    val token: String = "",
    /** Resolver published by the exit, empty when it runs without DNS. */
    val dnsAddress: String = "",
    val dnsPort: Int = 53,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("name", name)
        put("address", address)
        put("socksPort", socksPort)
        put("apiPort", apiPort)
        if (token.isNotEmpty()) put("token", token)
        if (dnsAddress.isNotEmpty()) put("dnsAddress", dnsAddress)
        if (dnsAddress.isNotEmpty() && dnsPort != 53) put("dnsPort", dnsPort)
    }

    companion object {
        fun fromJson(o: JSONObject): ExitProfile? {
            val address = o.optString("address").trim()
            if (address.isEmpty()) return null
            val socks = o.optInt("socksPort", 1080)
            val api = o.optInt("apiPort", 1080)
            val id = o.optString("id").ifBlank { "$address:$socks" }
            return ExitProfile(
                id = id,
                name = o.optString("name").ifBlank { address },
                address = address,
                socksPort = socks,
                apiPort = api,
                token = o.optString("token").trim(),
                dnsAddress = o.optString("dnsAddress").trim(),
                dnsPort = o.optInt("dnsPort", 53),
            )
        }

        fun listFromJson(raw: String?): List<ExitProfile> {
            if (raw.isNullOrBlank()) return emptyList()
            return try {
                val arr = JSONArray(raw)
                buildList {
                    for (i in 0 until arr.length()) {
                        val o = arr.optJSONObject(i) ?: continue
                        fromJson(o)?.let { add(it) }
                    }
                }
            } catch (_: Exception) {
                emptyList()
            }
        }
    }
}

/** The single connection configuration of the app. */
data class Settings(
    val peerCount: Int = 3,
    val autoReplace: Boolean = true,
    val deadPeerTimeoutSec: Int = 45,
    val healthCheckSec: Int = 15,
    val dnsMode: String = DNS_YGGDRASIL,
    val dnsServers: List<String> = DEFAULT_DNS,
    val mtu: Int = 1280,
    val splitEnabled: Boolean = false,
    val splitApps: List<String> = emptyList(),
    val energySaving: Boolean = false,
    val logging: Boolean = false,
    val probeTimeoutMs: Int = 8000,
    val probeBatch: Int = 5,
    val exitEnabled: Boolean = false,
    val exitProfiles: List<ExitProfile> = emptyList(),
    val exitActiveId: String = "",
    val exitFallbackDirect: Boolean = true,
    val exitLocalDns: Boolean = true,
    val exitUdp: Boolean = true,
    val exitDnsServers: List<String> = DEFAULT_EXIT_DNS,
    val exitLocalDnsServers: List<String> = emptyList(),
) {
    /** The DNS servers that should be handed to the tunnel, empty for system DNS. */
    fun effectiveDns(): List<String> = when (dnsMode) {
        DNS_SYSTEM -> emptyList()
        else -> dnsServers.map { it.trim() }.filter { it.isNotEmpty() }
    }

    /** True when public traffic should be sent through an exit node. */
    fun exitActive(): Boolean = exitEnabled && exitProfiles.isNotEmpty()

    /**
     * The JSON contract of the Go bridge. `systemDns` are the resolvers of the
     * real network, used for local names; `yggDns` resolve `.ygg` names inside
     * Yggdrasil; `dns` are the public resolvers the exit queries over TCP.
     */
    fun exitConfigJson(systemDns: List<String>): String {
        val profiles = JSONArray()
        exitProfiles.forEach { profiles.put(it.toJson()) }
        // An explicit local list wins over the resolvers of the real network.
        val local = exitLocalDnsServers.ifEmpty { systemDns }
        val public = exitDnsServers.ifEmpty { DEFAULT_EXIT_DNS }
        return JSONObject().apply {
            put("enabled", exitActive())
            put("profiles", profiles)
            put("activeId", exitActiveId)
            put("fallbackDirect", exitFallbackDirect)
            put("dns", JSONArray(public))
            put("systemDns", JSONArray(local))
            put("yggDns", JSONArray(effectiveDns()))
            put("localDns", exitLocalDns)
            // UDP through the exit (DNS, QUIC). A false value makes the bridge
            // drop public datagrams instead of leaking them around the exit.
            put("udp", exitUdp)
        }.toString()
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("peerCount", peerCount)
        put("autoReplace", autoReplace)
        put("deadPeerTimeoutSec", deadPeerTimeoutSec)
        put("healthCheckSec", healthCheckSec)
        put("dnsMode", dnsMode)
        put("dnsServers", JSONArray(dnsServers))
        put("mtu", mtu)
        put("splitEnabled", splitEnabled)
        put("splitApps", JSONArray(splitApps))
        put("energySaving", energySaving)
        put("logging", logging)
        put("probeTimeoutMs", probeTimeoutMs)
        put("probeBatch", probeBatch)
        put("exitEnabled", exitEnabled)
        put("exitProfiles", JSONArray().apply { exitProfiles.forEach { put(it.toJson()) } })
        put("exitActiveId", exitActiveId)
        put("exitFallbackDirect", exitFallbackDirect)
        put("exitLocalDns", exitLocalDns)
        put("exitUdp", exitUdp)
        put("exitDnsServers", JSONArray(exitDnsServers))
        put("exitLocalDnsServers", JSONArray(exitLocalDnsServers))
    }

    companion object {
        const val DNS_YGGDRASIL = "yggdrasil"
        const val DNS_SYSTEM = "system"
        const val DNS_CUSTOM = "custom"

        val DEFAULT_DNS = listOf("308:84:68:55::", "308:25:40:bd::")
        val DEFAULT_EXIT_DNS = listOf("1.1.1.1", "9.9.9.9")

        fun fromJson(raw: String?): Settings {
            if (raw.isNullOrBlank()) return Settings()
            return try {
                val o = JSONObject(raw)
                val d = Settings()
                Settings(
                    peerCount = o.optInt("peerCount", d.peerCount).coerceIn(1, 20),
                    autoReplace = o.optBoolean("autoReplace", d.autoReplace),
                    deadPeerTimeoutSec = o.optInt("deadPeerTimeoutSec", d.deadPeerTimeoutSec)
                        .coerceIn(15, 300),
                    healthCheckSec = o.optInt("healthCheckSec", d.healthCheckSec)
                        .coerceIn(5, 120),
                    dnsMode = o.optString("dnsMode", d.dnsMode),
                    dnsServers = o.optJSONArray("dnsServers")?.let { arr ->
                        buildList { for (i in 0 until arr.length()) add(arr.optString(i)) }
                    }?.filter { it.isNotBlank() }?.takeIf { it.isNotEmpty() } ?: d.dnsServers,
                    mtu = o.optInt("mtu", d.mtu).coerceIn(1280, 65535),
                    splitEnabled = o.optBoolean("splitEnabled", d.splitEnabled),
                    splitApps = o.optJSONArray("splitApps")?.let { arr ->
                        buildList { for (i in 0 until arr.length()) add(arr.optString(i)) }
                    } ?: d.splitApps,
                    energySaving = o.optBoolean("energySaving", d.energySaving),
                    logging = o.optBoolean("logging", d.logging),
                    probeTimeoutMs = o.optInt("probeTimeoutMs", d.probeTimeoutMs)
                        .coerceIn(3000, 20000),
                    probeBatch = o.optInt("probeBatch", d.probeBatch).coerceIn(3, 10),
                    exitEnabled = o.optBoolean("exitEnabled", d.exitEnabled),
                    exitProfiles = ExitProfile.listFromJson(
                        o.optJSONArray("exitProfiles")?.toString(),
                    ),
                    exitActiveId = o.optString("exitActiveId", d.exitActiveId),
                    exitFallbackDirect = o.optBoolean(
                        "exitFallbackDirect",
                        d.exitFallbackDirect,
                    ),
                    exitLocalDns = o.optBoolean("exitLocalDns", d.exitLocalDns),
                    exitUdp = o.optBoolean("exitUdp", d.exitUdp),
                    exitDnsServers = o.optJSONArray("exitDnsServers")?.let { arr ->
                        buildList { for (i in 0 until arr.length()) add(arr.optString(i)) }
                    }?.filter { it.isNotBlank() }?.takeIf { it.isNotEmpty() } ?: d.exitDnsServers,
                    exitLocalDnsServers = o.optJSONArray("exitLocalDnsServers")?.let { arr ->
                        buildList { for (i in 0 until arr.length()) add(arr.optString(i)) }
                    }?.filter { it.isNotBlank() } ?: d.exitLocalDnsServers,
                )
            } catch (_: Exception) {
                Settings()
            }
        }
    }
}

/** The persistent node identity: the address must survive restarts. */
data class Identity(
    val privateKey: String,
    val publicKey: String,
    val address: String,
    val subnet: String = "",
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("privateKey", privateKey)
        put("publicKey", publicKey)
        put("address", address)
        put("subnet", subnet)
    }

    companion object {
        fun fromJson(raw: String?): Identity? {
            if (raw.isNullOrBlank()) return null
            return try {
                val o = JSONObject(raw)
                val key = o.optString("privateKey")
                if (key.isBlank()) null else Identity(
                    privateKey = key,
                    publicKey = o.optString("publicKey"),
                    address = o.optString("address"),
                    subnet = o.optString("subnet"),
                )
            } catch (_: Exception) {
                null
            }
        }
    }
}
