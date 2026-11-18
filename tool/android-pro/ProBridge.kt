package io.localview.localview

import android.content.Context
import android.os.Build
import android.util.Base64
import android.util.DisplayMetrics
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.security.SecureRandom
import java.util.concurrent.Executors

/**
 * Localview Pro: talks to [ProInputServer] (real mouse & keyboard events). Coordinates arrive
 * normalized (0..1) and are converted to screen pixels here.
 */
object ProBridge {
    /** A connection to the helper on 127.0.0.1 (fails within a second when it isn't running). */
    private fun helperSocket(): java.net.Socket = java.net.Socket().apply {
        tcpNoDelay = true
        connect(java.net.InetSocketAddress("127.0.0.1", ProInputServer.PORT), 1000)
    }

    private val exec = Executors.newSingleThreadExecutor()
    private var socket: java.net.Socket? = null
    private var out: OutputStream? = null
    private var reader: BufferedReader? = null
    @Volatile private var running = false

    private fun token(ctx: Context): String {
        val prefs = ctx.getSharedPreferences("localview_pro", Context.MODE_PRIVATE)
        prefs.getString("token", null)?.let { return it }
        val b = ByteArray(24).also { SecureRandom().nextBytes(it) }
        val t = b.joinToString("") { "%02x".format(it) }
        prefs.edit().putString("token", t).apply()
        return t
    }

    /** The helper's messages (start-up, errors); the computer's ADB dialog shows them. */
    const val LOG = "/data/local/tmp/localview_pro.log"

    /**
     * Health check on its own short-lived connection (never queued behind input): running,
     * and whether Android accepts the events it injects.
     */
    private fun status(ctx: Context): Map<String, Any?> {
        val base = mapOf("pro" to true, "command" to command(ctx), "log" to LOG)
        return try {
            val s = helperSocket()
            s.soTimeout = 1500
            try {
                s.outputStream.write("${token(ctx)}\np\n".toByteArray())
                val r = BufferedReader(InputStreamReader(s.inputStream))
                if (r.readLine() != "ok") return base + mapOf("running" to false, "error" to "The helper did not accept this app (restart it)")
                val p = (r.readLine() ?: "").split(' ')
                if (p.firstOrNull() != "pong") return base + mapOf("running" to false, "error" to "The helper did not answer")
                val ok = p.getOrNull(1)?.toLongOrNull() ?: 0L
                val bad = p.getOrNull(2)?.toLongOrNull() ?: 0L
                val err = p.getOrNull(3)?.let { try { String(Base64.decode(it, Base64.DEFAULT)) } catch (_: Exception) { "" } } ?: ""
                // Android refuses everything it sends: use touch input instead.
                val working = !(bad > 0 && ok == 0L)
                base + mapOf("running" to working, "injected" to ok, "refused" to bad,
                    "error" to if (working) null else "Android refused the helper's input: $err")
            } finally {
                try { s.close() } catch (_: Exception) {}
            }
        } catch (_: Exception) {
            base + mapOf("running" to false)
        }
    }

    // Input goes through a queue to a writer thread, so a slow or stuck helper can never block
    // the app; pointer moves are merged (only the newest one waits).
    private val queue = java.util.concurrent.LinkedBlockingDeque<String>()
    @Volatile private var pendingMove: String? = null
    private val moveLock = Object()
    @Volatile private var writer: Thread? = null

    private fun enqueue(ctx: Context, line: String) {
        if (line.startsWith("m ")) {
            synchronized(moveLock) {
                val had = pendingMove != null
                pendingMove = line
                if (!had) queue.add("\u0000move")
            }
        } else {
            synchronized(moveLock) {
                // Keep the order: a waiting move goes first.
                pendingMove?.let { queue.add(it); pendingMove = null; queue.remove("\u0000move") }
            }
            queue.add(line)
        }
        if (queue.size > 500) queue.clear() // helper gone and nobody noticed: don't grow forever
        if (writer?.isAlive != true) {
            writer = Thread({
                while (true) {
                    var l = queue.take()
                    if (l == "\u0000move") l = synchronized(moveLock) { pendingMove.also { pendingMove = null } } ?: continue
                    sendLine(ctx, l) // only this thread uses the input connection
                }
            }, "localview-pro-writer").apply { isDaemon = true; start() }
        }
    }

    /** One command that needs an answer, on its own short-lived connection. */
    private fun ask(ctx: Context, line: String): String? = try {
        val s = helperSocket()
        s.soTimeout = 1500
        try {
            s.outputStream.write("${token(ctx)}\n$line\n".toByteArray())
            val r = BufferedReader(InputStreamReader(s.inputStream))
            if (r.readLine() == "ok") r.readLine() else null
        } finally {
            try { s.close() } catch (_: Exception) {}
        }
    } catch (_: Exception) { null }

    /** Shell command that starts the helper (run it over ADB); keeps running after ADB disconnects. */
    private fun command(ctx: Context): String =
        "CLASSPATH=${ctx.applicationInfo.sourceDir} setsid app_process /system/bin io.localview.localview.ProInputServer " +
            "${token(ctx)} > $LOG 2>&1 < /dev/null &"

    /** Connects (or reconnects) to the helper. Runs on [exec]. */
    private fun connect(ctx: Context): Boolean {
        if (socket != null) return true
        return try {
            val s = helperSocket()
            s.soTimeout = 2000
            val o = s.outputStream
            val r = BufferedReader(InputStreamReader(s.inputStream))
            o.write("${token(ctx)}\n".toByteArray())
            if (r.readLine() != "ok") { s.close(); return false }
            socket = s; out = o; reader = r; running = true
            true
        } catch (_: Exception) {
            running = false
            false
        }
    }

    /**
     * The device's whole sound output from the helper (Android 12+), PCM s16le stereo 48 kHz; the
     * speaker stays silent while it is open. null if the helper isn't running or can't capture it.
     */
    fun openAudio(ctx: Context): java.io.InputStream? {
        if (android.os.Build.VERSION.SDK_INT < 31) return null
        return try {
            val s = helperSocket()
            s.soTimeout = 2000
            s.outputStream.write("${token(ctx)}\naudio\n".toByteArray())
            val i = s.inputStream
            fun line(): String {
                val b = StringBuilder()
                while (true) {
                    val c = i.read()
                    if (c < 0 || c == '\n'.code) return b.toString()
                    b.append(c.toChar())
                }
            }
            if (line() != "ok" || line() != "ok") { s.close(); return null }
            s.soTimeout = 0
            object : java.io.FilterInputStream(i) {
                override fun close() { try { s.close() } catch (_: Exception) {} }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun drop() {
        try { socket?.close() } catch (_: Exception) {}
        socket = null; out = null; reader = null; running = false
    }

    private fun sendLine(ctx: Context, line: String, reply: Boolean = false): String? {
        if (!connect(ctx)) return null
        return try {
            out!!.write("$line\n".toByteArray())
            if (reply) reader!!.readLine() else ""
        } catch (_: Exception) {
            drop(); null
        }
    }

    private fun screen(ctx: Context): Pair<Float, Float> {
        val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        return if (Build.VERSION.SDK_INT >= 30) {
            val b = wm.maximumWindowMetrics.bounds; Pair(b.width().toFloat(), b.height().toFloat())
        } else {
            val m = DisplayMetrics(); @Suppress("DEPRECATION") wm.defaultDisplay.getRealMetrics(m)
            Pair(m.widthPixels.toFloat(), m.heightPixels.toFloat())
        }
    }

    private fun px(ctx: Context, args: Map<String, Any?>?): String {
        val (w, h) = screen(ctx)
        val x = ((args?.get("x") as? Number)?.toFloat() ?: 0f) * (w - 1)
        val y = ((args?.get("y") as? Number)?.toFloat() ?: 0f) * (h - 1)
        return "$x $y"
    }

    fun handle(ctx: Context, method: String, args: Map<String, Any?>?, result: MethodChannel.Result): Boolean {
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        fun async(block: () -> Any?) = exec.execute { val r = block(); main.post { result.success(r) } }
        when (method) {
            "pro.status" -> Thread {
                val st = status(ctx)
                main.post { result.success(st) }
            }.start()
            "pro.move" -> { enqueue(ctx, "m ${px(ctx, args)}"); result.success(true) }
            "pro.button" -> {
                enqueue(ctx, "b ${(args?.get("button") as? Number)?.toInt() ?: 0} ${if (args?.get("down") == true) 1 else 0} ${px(ctx, args)}")
                result.success(true)
            }
            "pro.scroll" -> {
                enqueue(ctx, "s ${px(ctx, args)} ${(args?.get("dx") as? Number)?.toFloat() ?: 0f} ${(args?.get("dy") as? Number)?.toFloat() ?: 0f}")
                result.success(true)
            }
            "pro.key" -> {
                val code = keyCode((args?.get("hid") as? Number)?.toInt() ?: 0)
                if (code != 0) enqueue(ctx, "k $code ${if (args?.get("down") == true) 1 else 0}")
                result.success(code != 0)
            }
            "pro.stop" -> async {
                // The helper stops itself and every other copy (the app may not kill shell processes).
                val r = ask(ctx, "q")
                drop()
                r == "bye"
            }
            "pro.text" -> async {
                val t = args?.get("text") as? String ?: ""
                ask(ctx, "t ${Base64.encodeToString(t.toByteArray(), Base64.NO_WRAP)}") == "ok"
            }
            else -> return false
        }
        return true
    }

    /** USB HID usage (keyboard page) -> Android key code. */
    private fun keyCode(hid: Int): Int {
        val u = hid and 0xFFFF
        return when (u) {
            in 0x04..0x1D -> KeyEvent.KEYCODE_A + (u - 0x04)
            in 0x1E..0x26 -> KeyEvent.KEYCODE_1 + (u - 0x1E)
            0x27 -> KeyEvent.KEYCODE_0
            0x28 -> KeyEvent.KEYCODE_ENTER
            0x29 -> KeyEvent.KEYCODE_ESCAPE
            0x2A -> KeyEvent.KEYCODE_DEL
            0x2B -> KeyEvent.KEYCODE_TAB
            0x2C -> KeyEvent.KEYCODE_SPACE
            0x2D -> KeyEvent.KEYCODE_MINUS
            0x2E -> KeyEvent.KEYCODE_EQUALS
            0x2F -> KeyEvent.KEYCODE_LEFT_BRACKET
            0x30 -> KeyEvent.KEYCODE_RIGHT_BRACKET
            0x31, 0x64 -> KeyEvent.KEYCODE_BACKSLASH
            0x33 -> KeyEvent.KEYCODE_SEMICOLON
            0x34 -> KeyEvent.KEYCODE_APOSTROPHE
            0x35 -> KeyEvent.KEYCODE_GRAVE
            0x36 -> KeyEvent.KEYCODE_COMMA
            0x37 -> KeyEvent.KEYCODE_PERIOD
            0x38 -> KeyEvent.KEYCODE_SLASH
            0x39 -> KeyEvent.KEYCODE_CAPS_LOCK
            in 0x3A..0x45 -> KeyEvent.KEYCODE_F1 + (u - 0x3A)
            0x46 -> KeyEvent.KEYCODE_SYSRQ
            0x47 -> KeyEvent.KEYCODE_SCROLL_LOCK
            0x48 -> KeyEvent.KEYCODE_BREAK
            0x49 -> KeyEvent.KEYCODE_INSERT
            0x4A -> KeyEvent.KEYCODE_MOVE_HOME
            0x4B -> KeyEvent.KEYCODE_PAGE_UP
            0x4C -> KeyEvent.KEYCODE_FORWARD_DEL
            0x4D -> KeyEvent.KEYCODE_MOVE_END
            0x4E -> KeyEvent.KEYCODE_PAGE_DOWN
            0x4F -> KeyEvent.KEYCODE_DPAD_RIGHT
            0x50 -> KeyEvent.KEYCODE_DPAD_LEFT
            0x51 -> KeyEvent.KEYCODE_DPAD_DOWN
            0x52 -> KeyEvent.KEYCODE_DPAD_UP
            0x53 -> KeyEvent.KEYCODE_NUM_LOCK
            0x54 -> KeyEvent.KEYCODE_NUMPAD_DIVIDE
            0x55 -> KeyEvent.KEYCODE_NUMPAD_MULTIPLY
            0x56 -> KeyEvent.KEYCODE_NUMPAD_SUBTRACT
            0x57 -> KeyEvent.KEYCODE_NUMPAD_ADD
            0x58 -> KeyEvent.KEYCODE_NUMPAD_ENTER
            in 0x59..0x61 -> KeyEvent.KEYCODE_NUMPAD_1 + (u - 0x59)
            0x62 -> KeyEvent.KEYCODE_NUMPAD_0
            0x63 -> KeyEvent.KEYCODE_NUMPAD_DOT
            0x65 -> KeyEvent.KEYCODE_MENU
            0xE0 -> KeyEvent.KEYCODE_CTRL_LEFT
            0xE1 -> KeyEvent.KEYCODE_SHIFT_LEFT
            0xE2 -> KeyEvent.KEYCODE_ALT_LEFT
            0xE3 -> KeyEvent.KEYCODE_META_LEFT
            0xE4 -> KeyEvent.KEYCODE_CTRL_RIGHT
            0xE5 -> KeyEvent.KEYCODE_SHIFT_RIGHT
            0xE6 -> KeyEvent.KEYCODE_ALT_RIGHT
            0xE7 -> KeyEvent.KEYCODE_META_RIGHT
            else -> 0
        }
    }
}
