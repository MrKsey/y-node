package com.yggnode.app.vpn

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.LinkedBlockingQueue

/**
 * The connection log shared by Kotlin and the Yggdrasil core.
 *
 * Every session starts with a header that carries the app version and the
 * connection parameters, so a log attached to a bug report explains itself. The
 * file is capped at 512 KB: when it overflows it is cleared and starts over,
 * which keeps the newest session instead of growing without bound.
 *
 * Lines are written from a single background thread, so a burst of core log
 * lines never blocks the VPN data path.
 */
object ConnectionLog {
    private const val FILE_NAME = "connection_log.txt"
    private const val MAX_BYTES = 512L * 1024L
    private const val MAX_PENDING = 2000

    private var file: File? = null
    private val queue = LinkedBlockingQueue<String>(MAX_PENDING)
    private val formatter = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)
    private var writer: Thread? = null

    @Volatile
    var enabled: Boolean = false

    @Volatile
    private var appVersion: String = "?"

    fun init(context: Context, version: String = appVersion) {
        appVersion = version
        if (file != null) return
        val dir = context.getExternalFilesDir(null) ?: context.filesDir
        file = File(dir, FILE_NAME)
        startWriter()
    }

    private fun startWriter() {
        if (writer != null) return
        val t = Thread({
            while (true) {
                val line = try {
                    queue.take()
                } catch (_: InterruptedException) {
                    return@Thread
                }
                appendToFile(line)
            }
        }, "ygg-log-writer")
        t.isDaemon = true
        t.start()
        writer = t
    }

    private fun appendToFile(line: String) {
        val f = file ?: return
        try {
            if (f.exists() && f.length() > MAX_BYTES) {
                f.writeText("")
            }
            f.appendText(line)
        } catch (_: Exception) {
            // A full or unavailable storage must never break the tunnel.
        }
    }

    private fun timestamp(): String = synchronized(formatter) {
        formatter.format(Date())
    }

    fun append(tag: String, message: String) {
        if (!enabled) return
        if (file == null) return
        val clean = message.trimEnd()
        if (clean.isEmpty()) return
        val line = "${timestamp()} ${tag.padEnd(10)} $clean\n"
        if (!queue.offer(line)) {
            // The writer is behind: drop the line rather than grow without bound.
        }
    }

    /** Starts a new session block; the previous content is kept. */
    fun startSession(details: String) {
        // A disabled log must stay untouched: without this guard every connect
        // still appended a session header, so the file kept growing even though
        // the switch was off.
        if (!enabled) return
        if (file == null) return
        val divider = "=".repeat(64)
        val header = buildString {
            append("\n")
            append(divider).append("\n")
            append("=== NEW SESSION  ").append(timestamp()).append(" ===\n")
            append("App: Y-Node ").append(appVersion).append("\n")
            append(details.trimEnd()).append("\n")
            append(divider).append("\n")
        }
        // The header must land before any line that follows it.
        try {
            queue.put(header)
        } catch (_: InterruptedException) {
        }
    }

    fun read(): String {
        val f = file ?: return ""
        return try {
            if (f.exists()) f.readText() else ""
        } catch (_: Exception) {
            ""
        }
    }

    fun clear() {
        val f = file ?: return
        try {
            f.writeText("")
        } catch (_: Exception) {
        }
    }

    fun path(): String = file?.absolutePath ?: ""

    fun sizeBytes(): Long = try {
        file?.length() ?: 0L
    } catch (_: Exception) {
        0L
    }
}
