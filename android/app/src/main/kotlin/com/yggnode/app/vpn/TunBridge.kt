package com.yggnode.app.vpn

import yggnode.Node
import yggnode.PacketWriter
import yggnode.Protector
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicLong

/**
 * Moves IP packets between the Android TUN descriptor and the Yggdrasil node.
 *
 * Two threads, each with one reusable buffer: reading the TUN and handing the
 * packet to Go, and pulling a packet out of Go and writing it to the TUN. No
 * allocation happens per packet, which matters because the tunnel runs for hours
 * on a phone.
 *
 * Packets addressed into Yggdrasil go to the node. Everything else is ordinary
 * internet traffic of the apps in the VPN allow list: Android never lets those
 * apps fall back to the real network, so it is handed to the userspace stack
 * (tun2socks) that forwards it through a protected socket.
 *
 * Stopping is deliberately blunt: the node is stopped first, which unblocks the
 * pending Recv, then the streams are closed, which unblocks the pending read.
 * Both threads then see a closed tunnel and exit.
 */
class TunBridge(
    private val node: Node,
    private val input: FileInputStream,
    private val output: FileOutputStream,
    private val mtu: Int,
    private val onLog: (String, String) -> Unit,
    private val onError: (Throwable) -> Unit,
    private val onActivity: (Int) -> Unit,
) {
    // A little slack over the MTU: the kernel may hand back a larger buffer and
    // the Yggdrasil core trims it itself.
    private val bufferSize = mtu + 256

    private val rx = AtomicLong(0)
    private val tx = AtomicLong(0)

    /** The first few DNS queries of a session are logged: a `.ygg` name that does
     *  not resolve is the most common support question and the source address of
     *  the query explains most of them. */
    private val dnsQueries = AtomicLong(0)
    private val dnsReplies = AtomicLong(0)
    private val dnsYggQueries = AtomicLong(0)
    private val dnsYggReplies = AtomicLong(0)

    @Volatile
    private var running = true

    /** True once the userspace stack is up and can take non-Ygg packets. */
    @Volatile
    private var forwarding = false

    /** The two writers share one descriptor, so writes are serialised. */
    private val writeLock = Any()

    private var upstream: Thread? = null
    private var downstream: Thread? = null

    /**
     * Writes one packet back into the tunnel. Called by the Go stack on its own
     * thread; the bytes are copied into the descriptor before returning.
     */
    private val packetWriter = object : PacketWriter {
        override fun writePacket(packet: ByteArray): Boolean {
            return try {
                synchronized(writeLock) { output.write(packet) }
                rx.addAndGet(packet.size.toLong())
                onActivity(packet.size)
                true
            } catch (_: Throwable) {
                false
            }
        }
    }

    /**
     * Starts the userspace stack that carries ordinary internet traffic of the
     * apps in the allow list. [protector] binds the upstream sockets to the real
     * network; [exitConfig] enables the SOCKS5 exit and the split-DNS router.
     */
    fun startForwarding(protector: Protector, ipv4Address: String, exitConfig: String) {
        try {
            node.enableTun2Socks(
                protector,
                packetWriter,
                mtu.toLong(),
                ipv4Address,
                exitConfig,
            )
            forwarding = true
            onLog("INFO", "tun2socks ready, ordinary traffic goes through $ipv4Address")
        } catch (t: Throwable) {
            forwarding = false
            onLog("ERROR", "tun2socks did not start: ${t.message}")
        }
    }

    fun start() {
        upstream = Thread({ pumpUpstream() }, "ygg-tun-up").apply {
            priority = Thread.NORM_PRIORITY + 1
            start()
        }
        downstream = Thread({ pumpDownstream() }, "ygg-tun-down").apply {
            priority = Thread.NORM_PRIORITY + 1
            start()
        }
    }

    private fun pumpUpstream() {
        val buf = ByteArray(bufferSize)
        try {
            while (running) {
                val n = input.read(buf)
                if (n <= 0) continue
                if (!dispatch(buf, n)) continue
            }
        } catch (t: Throwable) {
            if (running) onError(t)
        }
        onLog("INFO", "upstream loop finished")
    }

    /**
     * Sends one packet where it belongs and returns false when it was dropped.
     * Yggdrasil traffic goes to the node, everything else to the userspace stack.
     */
    private fun dispatch(buf: ByteArray, n: Int): Boolean {
        if (n < 20) return false
        when ((buf[0].toInt() and 0xF0) shr 4) {
            4 -> {
                // IPv4 only exists in the tunnel when the allow list is active:
                // the apps in it cannot reach the real network on their own.
                if (!forwarding) return false
                return forward(buf, n, "ipv4")
            }

            6 -> {
                // The kernel queues its own housekeeping on the TUN as well: DAD
                // probes with source :: and MLD/neighbour discovery from the
                // link-local address it assigned to the interface. Yggdrasil
                // rejects anything that does not come from 200::/7, so drop it
                // here instead of filling the log with warnings.
                if (!isYggSource(buf)) return false
                if (isYggDestination(buf)) {
                    noteDns(buf, n)
                    return try {
                        node.send(buf, n.toLong())
                        tx.addAndGet(n.toLong())
                        onActivity(n)
                        true
                    } catch (t: Throwable) {
                        // One bad packet must not take the tunnel down.
                        onLog("WARN", "send dropped: ${t.message}")
                        false
                    }
                }
                // A global IPv6 address outside Yggdrasil is ordinary internet.
                if (!forwarding) return false
                return forward(buf, n, "ipv6")
            }

            else -> return false
        }
    }

    private fun forward(buf: ByteArray, n: Int, family: String): Boolean {
        return try {
            node.sendToStack(buf, n.toLong())
            tx.addAndGet(n.toLong())
            onActivity(n)
            true
        } catch (t: Throwable) {
            onLog("WARN", "$family forward dropped: ${t.message}")
            false
        }
    }

    private fun pumpDownstream() {
        val buf = ByteArray(bufferSize)
        try {
            while (running) {
                val n = node.recv(buf)
                if (n <= 0) continue
                noteDnsReply(buf, n.toInt())
                synchronized(writeLock) { output.write(buf, 0, n.toInt()) }
                rx.addAndGet(n)
                onActivity(n.toInt())
            }
        } catch (t: Throwable) {
            if (running) onError(t)
        }
        onLog("INFO", "downstream loop finished")
    }

    fun rxBytes(): Long = rx.get()

    fun txBytes(): Long = tx.get()

    /**
     * Logs the DNS packets of a session. `.ygg` names are always logged: a name
     * that does not resolve is the most common support question, and the pair of
     * lines shows at once whether the query left the tunnel and whether an
     * answer came back. Everything else is capped so the journal stays readable.
     */
    private fun noteDns(packet: ByteArray, length: Int) {
        val udp = udpHeader(packet, length) ?: return
        if (udp.dstPort != 53) return
        val ygg = isYggName(packet, udp)
        if (ygg) {
            if (dnsYggQueries.incrementAndGet() > MAX_YGG_DNS_LOGS) return
        } else if (dnsQueries.incrementAndGet() > MAX_DNS_LOGS) {
            return
        }
        logDns(if (ygg) "DNS query .ygg" else "DNS query", packet, udp, reply = false)
    }

    private fun noteDnsReply(packet: ByteArray, length: Int) {
        val udp = udpHeader(packet, length) ?: return
        if (udp.srcPort != 53) return
        val ygg = isYggName(packet, udp)
        if (ygg) {
            if (dnsYggReplies.incrementAndGet() > MAX_YGG_DNS_LOGS) return
        } else if (dnsReplies.incrementAndGet() > MAX_DNS_LOGS) {
            return
        }
        logDns(if (ygg) "DNS reply .ygg" else "DNS reply", packet, udp, reply = true)
    }

    /** True when the question section of the message asks for a `.ygg` name. */
    private fun isYggName(packet: ByteArray, udp: UdpHeader): Boolean {
        val name = questionName(packet, udp)
        return name.endsWith(".ygg", ignoreCase = true)
    }

    /** An IPv6 UDP header plus where its payload starts. */
    private class UdpHeader(
        val srcPort: Int,
        val dstPort: Int,
        val payloadOffset: Int,
        val payloadLength: Int,
    )

    private fun udpHeader(packet: ByteArray, length: Int): UdpHeader? {
        if (length < 48 || packet[6].toInt() != 17) return null
        val src = ((packet[40].toInt() and 0xFF) shl 8) or (packet[41].toInt() and 0xFF)
        val dst = ((packet[42].toInt() and 0xFF) shl 8) or (packet[43].toInt() and 0xFF)
        val udpLength = ((packet[44].toInt() and 0xFF) shl 8) or (packet[45].toInt() and 0xFF)
        if (udpLength < 8) return null
        val payload = minOf(udpLength - 8, length - 48)
        return UdpHeader(src, dst, 48, payload)
    }

    private fun logDns(label: String, packet: ByteArray, udp: UdpHeader, reply: Boolean) {
        try {
            val src = InetAddress.getByAddress(packet.copyOfRange(8, 24)).hostAddress
            val dst = InetAddress.getByAddress(packet.copyOfRange(24, 40)).hostAddress
            val detail = describeDns(packet, udp.payloadOffset, udp.payloadLength, reply)
            onLog(
                "INFO",
                "$label $src:${udp.srcPort} -> $dst:${udp.dstPort}$detail",
            )
        } catch (_: Throwable) {
        }
    }

    /**
     * Renders the interesting part of a DNS message: transaction id, response
     * code, question type and answer count. A `.ygg` name that only exists as an
     * AAAA record is answered with NXDOMAIN for the A query, which browsers
     * treat as "no such host" even when the AAAA answer is right there.
     */
    private fun describeDns(packet: ByteArray, offset: Int, length: Int, reply: Boolean): String {
        if (length < 12) return ""
        val end = offset + length
        val id = u16(packet, offset)
        val flags = u16(packet, offset + 2)
        val questions = u16(packet, offset + 4)
        val answers = u16(packet, offset + 6)

        val name = questionName(packet, offset, end)
        val qtype = questionType(packet, offset, end)

        val text = StringBuilder()
        text.append(" id=0x").append(Integer.toHexString(id))
        if (reply) text.append(" rcode=").append(flags and 0x0F)
        text.append(" q=").append(qtypeName(qtype))
        text.append(" name=").append(name)
        text.append(" qd=").append(questions)
        if (reply) text.append(" an=").append(answers)
        return text.toString()
    }

    private fun questionName(packet: ByteArray, udp: UdpHeader): String =
        questionName(packet, udp.payloadOffset, udp.payloadOffset + udp.payloadLength)

    /** The QNAME of the first question, dots between labels, no trailing dot. */
    private fun questionName(packet: ByteArray, offset: Int, end: Int): String {
        val name = StringBuilder()
        var p = offset + 12
        var guard = 0
        while (p < end && guard < 255) {
            val label = packet[p].toInt() and 0xFF
            if (label == 0) break
            if (label and 0xC0 != 0) break
            if (name.isNotEmpty()) name.append('.')
            for (i in 1..label) {
                if (p + i < end) name.append((packet[p + i].toInt() and 0xFF).toChar())
            }
            p += label + 1
            guard += label
        }
        return name.toString()
    }

    private fun questionType(packet: ByteArray, offset: Int, end: Int): Int {
        var p = offset + 12
        var guard = 0
        while (p < end && guard < 255) {
            val label = packet[p].toInt() and 0xFF
            if (label == 0) {
                p++
                break
            }
            if (label and 0xC0 != 0) {
                p += 2
                break
            }
            p += label + 1
            guard += label
        }
        return if (p + 2 <= end) u16(packet, p) else -1
    }

    private fun qtypeName(type: Int): String = when (type) {
        1 -> "A"
        28 -> "AAAA"
        65 -> "HTTPS"
        12 -> "PTR"
        16 -> "TXT"
        else -> type.toString()
    }

    private fun u16(packet: ByteArray, offset: Int): Int =
        ((packet[offset].toInt() and 0xFF) shl 8) or (packet[offset + 1].toInt() and 0xFF)

    /**
     * True when the packet's source address belongs to Yggdrasil's `200::/7`.
     *
     * The kernel also queues its own housekeeping on the TUN: DAD probes with
     * source `::` and MLD/neighbour discovery from the link-local address it
     * assigned to the interface. The node rejects all of them with "incorrect
     * source address", which only fills the log.
     */
    private fun isYggSource(packet: ByteArray): Boolean {
        val first = packet[8].toInt() and 0xFF
        return first == 0x02 || first == 0x03
    }

    /** True when the packet is addressed to Yggdrasil's `200::/7`. */
    private fun isYggDestination(packet: ByteArray): Boolean {
        val first = packet[24].toInt() and 0xFF
        return first == 0x02 || first == 0x03
    }

    fun stop() {
        if (!running) return
        running = false
        // Stop the node first: it unblocks the pending Recv.
        try {
            node.stop()
        } catch (_: Throwable) {
        }
        try {
            input.close()
        } catch (_: Throwable) {
        }
        try {
            output.close()
        } catch (_: Throwable) {
        }
        upstream?.interrupt()
        downstream?.interrupt()
        upstream = null
        downstream = null
    }

    private companion object {
        const val MAX_DNS_LOGS = 4
        const val MAX_YGG_DNS_LOGS = 20
    }
}
