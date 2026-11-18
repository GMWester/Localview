package io.localview.localview

import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.lang.reflect.Method

/**
 * Localview Pro: real mouse and keyboard input on Android.
 *
 * Runs as its own process with adb "shell" privileges (started over ADB with
 * `CLASSPATH=<this APK> app_process / io.localview.localview.ProInputServer <token>`), which
 * may inject input events like a physical mouse and keyboard - something normal apps cannot do.
 * The Localview app connects over TCP on 127.0.0.1:$PORT and must send
 * the per-install token first; then one command per line (coordinates in screen pixels):
 *
 *   m x y                 mouse moves (hover, or drag while a button is held)
 *   b button down x y     mouse button (0 left, 1 right, 2 middle; down 1/0)
 *   s x y dx dy           wheel (dy > 0 scrolls down, dx > 0 right)
 *   k keycode down        Android key code (modifiers are tracked for meta state)
 *   t base64              text through the virtual keyboard; replies "ok" or "no" (unmappable)
 *   p                     ping; replies "pong <injected> <refused> <base64 last error>"
 *   d on                  screen panel on (1) / off (0) while the picture keeps being captured; replies
 *                         "ok" or "no <base64 error>" (the power button also turns it back on)
 *   q                     replies "bye", stops every other helper (old versions too), then exits
 *   audio                 (Android 12+) replies "ok", then streams the device's whole sound output as
 *                         PCM s16le stereo 48 kHz until the connection closes, or replies "no". While
 *                         this runs the sound plays only through Localview, not the device's speaker.
 */
object ProInputServer {
    /**
     * TCP port on 127.0.0.1. (An abstract unix socket can't be used: SELinux doesn't let normal
     * apps connect to sockets of the shell user, so the app never reached the helper.)
     */
    const val PORT = 38917

    private lateinit var inject: Method
    private lateinit var manager: Any
    private var setActionButton: Method? = null

    private var downTime = 0L
    private var buttons = 0
    private var meta = 0
    private var lastX = 0f
    private var lastY = 0f
    @Volatile private var injected = 0L
    @Volatile private var refused = 0L
    @Volatile private var lastError = ""

    @JvmStatic
    fun main(args: Array<String>) {
        val token = args.firstOrNull() ?: run { System.err.println("usage: ProInputServer <token>"); return }
        // The sound capture needs a (system) context, created on a thread with a looper.
        try {
            Looper.prepareMainLooper()
            ProAudio.init()
        } catch (_: Throwable) {}
        manager = if (Build.VERSION.SDK_INT >= 34) {
            Class.forName("android.hardware.input.InputManagerGlobal").getMethod("getInstance").invoke(null)!!
        } else {
            Class.forName("android.hardware.input.InputManager").getMethod("getInstance").invoke(null)!!
        }
        inject = manager.javaClass.getMethod("injectInputEvent", InputEvent::class.java, Int::class.javaPrimitiveType)
        setActionButton = try {
            MotionEvent::class.java.getMethod("setActionButton", Int::class.javaPrimitiveType)
        } catch (_: Exception) { null }
        // A new start replaces any helper still running (older versions included).
        val stopped = stopOthers()
        if (stopped > 0) println("Stopped $stopped older Localview Pro helper(s)")
        var server: java.net.ServerSocket? = null
        for (attempt in 0 until 20) {
            server = try {
                java.net.ServerSocket(PORT, 16, java.net.InetAddress.getByName("127.0.0.1"))
            } catch (_: Exception) { null }
            if (server != null) break
            Thread.sleep(100) // the port is freed shortly after the old helper exits
        }
        if (server == null) {
            System.err.println("Localview Pro input: port $PORT is in use by another program")
            return
        }
        println("Localview Pro input ready (Android ${Build.VERSION.RELEASE}, API ${Build.VERSION.SDK_INT}, ${manager.javaClass.name})")
        while (true) {
            val s = server.accept()
            Thread { serve(s, token) }.start()
        }
    }

    private fun serve(s: java.net.Socket, token: String) {
        s.tcpNoDelay = true
        try {
            val r = BufferedReader(InputStreamReader(s.inputStream))
            val out = s.outputStream
            if (r.readLine() != token) { s.close(); return }
            out.write("ok\n".toByteArray())
            while (true) {
                val line = r.readLine() ?: break
                val p = line.split(' ')
                if (p[0] == "audio") { ProAudio.stream(out); break }
                try { synchronized(this) {
                    when (p[0]) {
                        "m" -> move(p[1].toFloat(), p[2].toFloat())
                        "b" -> button(p[1].toInt(), p[2] == "1", p[3].toFloat(), p[4].toFloat())
                        "s" -> scroll(p[1].toFloat(), p[2].toFloat(), p[3].toFloat(), p[4].toFloat())
                        "k" -> key(p[1].toInt(), p[2] == "1")
                        "t" -> out.write((if (text(String(Base64.decode(p[1], Base64.DEFAULT)))) "ok\n" else "no\n").toByteArray())
                        "d" -> {
                            val err = ProScreen.set(p[1] == "1")
                            out.write((if (err == null) "ok\n" else "no ${Base64.encodeToString(err.toByteArray(), Base64.NO_WRAP)}\n").toByteArray())
                        }
                        "q" -> {
                            out.write("bye\n".toByteArray())
                            out.flush()
                            stopOthers()
                            ProScreen.set(true)
                            System.exit(0)
                        }
                        "p" -> out.write("pong $injected $refused ${Base64.encodeToString(lastError.toByteArray(), Base64.NO_WRAP)}\n".toByteArray())
                    }
                } } catch (e: java.io.IOException) {
                    throw e
                } catch (e: Exception) {
                    // A malformed command must not end the connection.
                    System.err.println("bad command '$line': $e")
                }
            }
        } catch (_: Exception) {
        } finally {
            try { s.close() } catch (_: Exception) {}
        }
    }

    /** Kills every other ProInputServer process (same shell user, so allowed). Returns how many. */
    fun stopOthers(): Int {
        val me = android.os.Process.myPid()
        var n = 0
        val dirs = java.io.File("/proc").listFiles() ?: return 0
        for (d in dirs) {
            val pid = d.name.toIntOrNull() ?: continue
            if (pid == me) continue
            val cmd = try { java.io.File(d, "cmdline").readBytes() } catch (_: Exception) { continue }
            if (String(cmd).contains("io.localview.localview.ProInputServer")) {
                try { android.os.Process.killProcess(pid); n++ } catch (_: Exception) {}
            }
        }
        return n
    }

    private fun send(e: InputEvent) {
        try {
            if (inject.invoke(manager, e, 0 /* INJECT_INPUT_EVENT_MODE_ASYNC */) == false) {
                refused++
                lastError = "Android refused the event"
            } else injected++
        } catch (t: Throwable) {
            refused++
            val c = (t as? java.lang.reflect.InvocationTargetException)?.targetException ?: t
            if (lastError.isEmpty() || refused < 5) System.err.println("inject failed: $c")
            lastError = c.toString()
        }
    }

    private fun motion(action: Int, x: Float, y: Float, actionButton: Int = 0, vscroll: Float = 0f, hscroll: Float = 0f) {
        val now = SystemClock.uptimeMillis()
        val props = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_MOUSE }
        val coords = MotionEvent.PointerCoords().apply {
            this.x = x; this.y = y
            pressure = if (buttons != 0) 1f else 0f
            size = 1f
            if (vscroll != 0f) setAxisValue(MotionEvent.AXIS_VSCROLL, vscroll)
            if (hscroll != 0f) setAxisValue(MotionEvent.AXIS_HSCROLL, hscroll)
        }
        val e = MotionEvent.obtain(if (buttons != 0) downTime else now, now, action, 1, arrayOf(props), arrayOf(coords),
            meta, buttons, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0)
        if (actionButton != 0) try { setActionButton?.invoke(e, actionButton) } catch (_: Exception) {}
        send(e)
        e.recycle()
    }

    private fun move(x: Float, y: Float) {
        lastX = x; lastY = y
        motion(if (buttons == 0) MotionEvent.ACTION_HOVER_MOVE else MotionEvent.ACTION_MOVE, x, y)
    }

    private fun button(b: Int, down: Boolean, x: Float, y: Float) {
        lastX = x; lastY = y
        val bit = when (b) { 1 -> MotionEvent.BUTTON_SECONDARY; 2 -> MotionEvent.BUTTON_TERTIARY; else -> MotionEvent.BUTTON_PRIMARY }
        if (down) {
            if (buttons and bit != 0) return
            val first = buttons == 0
            buttons = buttons or bit
            if (first) {
                downTime = SystemClock.uptimeMillis()
                motion(MotionEvent.ACTION_DOWN, x, y)
            }
            motion(MotionEvent.ACTION_BUTTON_PRESS, x, y, bit)
        } else {
            if (buttons and bit == 0) return
            buttons = buttons and bit.inv()
            motion(MotionEvent.ACTION_BUTTON_RELEASE, x, y, bit)
            if (buttons == 0) motion(MotionEvent.ACTION_UP, x, y)
        }
    }

    private fun scroll(x: Float, y: Float, dx: Float, dy: Float) {
        motion(MotionEvent.ACTION_SCROLL, x, y, vscroll = -dy, hscroll = dx)
    }

    private fun metaFor(code: Int): Int = when (code) {
        KeyEvent.KEYCODE_SHIFT_LEFT -> KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON
        KeyEvent.KEYCODE_SHIFT_RIGHT -> KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_RIGHT_ON
        KeyEvent.KEYCODE_CTRL_LEFT -> KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
        KeyEvent.KEYCODE_CTRL_RIGHT -> KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_RIGHT_ON
        KeyEvent.KEYCODE_ALT_LEFT -> KeyEvent.META_ALT_ON or KeyEvent.META_ALT_LEFT_ON
        KeyEvent.KEYCODE_ALT_RIGHT -> KeyEvent.META_ALT_ON or KeyEvent.META_ALT_RIGHT_ON
        KeyEvent.KEYCODE_META_LEFT -> KeyEvent.META_META_ON or KeyEvent.META_META_LEFT_ON
        KeyEvent.KEYCODE_META_RIGHT -> KeyEvent.META_META_ON or KeyEvent.META_META_RIGHT_ON
        else -> 0
    }

    private fun key(code: Int, down: Boolean) {
        val m = metaFor(code)
        if (m != 0) meta = if (down) meta or m else meta and m.inv()
        val now = SystemClock.uptimeMillis()
        send(KeyEvent(now, now, if (down) KeyEvent.ACTION_DOWN else KeyEvent.ACTION_UP, code, 0, meta,
            KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD))
    }

    private fun text(t: String): Boolean {
        val events = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD).getEvents(t.toCharArray()) ?: return false
        for (e in events) send(e)
        return true
    }
}

/**
 * The device's whole sound output (REMOTE_SUBMIX), which the shell user may record. Recording it
 * routes the sound away from the speaker, so it plays only on the controlling device - the same
 * approach scrcpy uses for its "output" audio source.
 */
@SuppressLint("PrivateApi", "DiscouragedPrivateApi", "MissingPermission", "WrongConstant")
object ProAudio {
    private const val RATE = 48000
    private const val SHELL = "com.android.shell"
    private var context: Context? = null

    /** Builds a context that identifies as the shell package (must run on a looper thread). */
    fun init() {
        if (Build.VERSION.SDK_INT < 31) return
        val at = Class.forName("android.app.ActivityThread")
        val thread = at.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
        at.getDeclaredField("sCurrentActivityThread").apply { isAccessible = true }.set(null, thread)
        at.getDeclaredField("mSystemThread").apply { isAccessible = true }.setBoolean(thread, true)
        val sys = at.getDeclaredMethod("getSystemContext").apply { isAccessible = true }.invoke(thread) as Context
        context = ShellContext(sys)
    }

    @TargetApi(31)
    private class ShellContext(base: Context) : ContextWrapper(base) {
        override fun getPackageName(): String = SHELL
        override fun getOpPackageName(): String = SHELL
        override fun getAttributionSource(): AttributionSource =
            AttributionSource.Builder(2000 /* shell uid */).setPackageName(SHELL).build()
        override fun getApplicationContext(): Context = this
    }

    @TargetApi(31)
    private fun open(): AudioRecord? {
        val ctx = context ?: return null
        val fmt = AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_IN_STEREO).build()
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        val r = AudioRecord.Builder().setContext(ctx).setAudioSource(MediaRecorder.AudioSource.REMOTE_SUBMIX)
            .setAudioFormat(fmt).setBufferSizeInBytes(maxOf(min * 8, RATE / 5 * 4)).build()
        if (r.state != AudioRecord.STATE_INITIALIZED) { r.release(); return null }
        r.startRecording()
        return r
    }

    fun stream(out: OutputStream) {
        val r = if (Build.VERSION.SDK_INT >= 31) try { open() } catch (e: Throwable) {
            System.err.println("Localview Pro sound: ${e.message}"); null
        } else null
        if (r == null) { out.write("no\n".toByteArray()); return }
        try {
            out.write("ok\n".toByteArray())
            val buf = ByteArray(RATE / 50 * 4) // 20 ms
            while (true) {
                val n = r.read(buf, 0, buf.size)
                if (n < 0) break
                if (n > 0) out.write(buf, 0, n)
            }
        } catch (_: Exception) {
        } finally {
            try { r.stop() } catch (_: Exception) {}
            r.release()
        }
    }
}

/**
 * Turns the device's display panel off (or on) while apps keep drawing, so screen capture
 * continues: the picture only shows on the controlling computer and the device runs cooler.
 * The same calls scrcpy uses; they need the shell user's privileges.
 */
@SuppressLint("PrivateApi", "DiscouragedPrivateApi", "BlockedPrivateApi")
object ProScreen {
    private val sc: Class<*> by lazy { Class.forName("android.view.SurfaceControl") }

    private val displayControl: Class<*>? by lazy {
        if (Build.VERSION.SDK_INT < 34) return@lazy null
        try {
            // Android 14+: the display tokens live in the system server's DisplayControl.
            val factory = Class.forName("com.android.internal.os.ClassLoaderFactory")
            val create = factory.getDeclaredMethod("createClassLoader", String::class.java, String::class.java, String::class.java,
                ClassLoader::class.java, Int::class.javaPrimitiveType, Boolean::class.javaPrimitiveType, String::class.java)
            val cp = android.system.Os.getenv("SYSTEMSERVERCLASSPATH")
            val loader = create.invoke(null, cp, null, null, ClassLoader.getSystemClassLoader(), 0, true, null) as ClassLoader
            val c = loader.loadClass("com.android.server.display.DisplayControl")
            val load = Runtime::class.java.getDeclaredMethod("loadLibrary0", Class::class.java, String::class.java)
            load.isAccessible = true
            load.invoke(Runtime.getRuntime(), c, "android_servers")
            c
        } catch (t: Throwable) {
            System.err.println("DisplayControl: $t")
            null
        }
    }

    private fun tokens(): List<android.os.IBinder> {
        val dc = displayControl
        if (dc != null) {
            val ids = dc.getMethod("getPhysicalDisplayIds").invoke(null) as LongArray
            val tok = dc.getMethod("getPhysicalDisplayToken", Long::class.javaPrimitiveType)
            return ids.toList().mapNotNull { tok.invoke(null, it) as? android.os.IBinder }
        }
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                val ids = sc.getMethod("getPhysicalDisplayIds").invoke(null) as LongArray
                val tok = sc.getMethod("getPhysicalDisplayToken", Long::class.javaPrimitiveType)
                return ids.toList().mapNotNull { tok.invoke(null, it) as? android.os.IBinder }
            } catch (_: NoSuchMethodException) {}
        }
        val t = try {
            sc.getMethod("getInternalDisplayToken").invoke(null)
        } catch (_: NoSuchMethodException) {
            sc.getMethod("getBuiltInDisplay", Int::class.javaPrimitiveType).invoke(null, 0)
        }
        return listOfNotNull(t as? android.os.IBinder)
    }

    /** null on success, else the reason. */
    @Synchronized
    fun set(on: Boolean): String? = try {
        val m = sc.getMethod("setDisplayPowerMode", android.os.IBinder::class.java, Int::class.javaPrimitiveType)
        val all = tokens()
        if (all.isEmpty()) "no display found"
        else {
            for (t in all) m.invoke(null, t, if (on) 2 /* POWER_MODE_NORMAL */ else 0 /* POWER_MODE_OFF */)
            null
        }
    } catch (t: Throwable) {
        val c = (t as? java.lang.reflect.InvocationTargetException)?.targetException ?: t
        System.err.println("screen power: $c")
        c.toString()
    }
}
