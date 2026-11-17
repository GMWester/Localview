package io.localview.localview

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Build
import android.os.SystemClock
import android.util.Base64
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import java.io.BufferedReader
import java.io.InputStreamReader
import java.lang.reflect.Method

/**
 * Localview Pro: real mouse and keyboard input on Android.
 *
 * Runs as its own process with adb "shell" privileges (started over ADB with
 * `CLASSPATH=<this APK> app_process / io.localview.localview.ProInputServer <token>`), which
 * may inject input events like a physical mouse and keyboard - something normal apps cannot do.
 * The Localview app connects over the abstract local socket "localview_pro_input" and must send
 * the per-install token first; then one command per line (coordinates in screen pixels):
 *
 *   m x y                 mouse moves (hover, or drag while a button is held)
 *   b button down x y     mouse button (0 left, 1 right, 2 middle; down 1/0)
 *   s x y dx dy           wheel (dy > 0 scrolls down, dx > 0 right)
 *   k keycode down        Android key code (modifiers are tracked for meta state)
 *   t base64              text through the virtual keyboard; replies "ok" or "no" (unmappable)
 *   p                     ping; replies "pong"
 */
object ProInputServer {
    const val SOCKET = "localview_pro_input"

    private lateinit var inject: Method
    private lateinit var manager: Any
    private var setActionButton: Method? = null

    private var downTime = 0L
    private var buttons = 0
    private var meta = 0
    private var lastX = 0f
    private var lastY = 0f

    @JvmStatic
    fun main(args: Array<String>) {
        val token = args.firstOrNull() ?: run { System.err.println("usage: ProInputServer <token>"); return }
        manager = if (Build.VERSION.SDK_INT >= 34) {
            Class.forName("android.hardware.input.InputManagerGlobal").getMethod("getInstance").invoke(null)!!
        } else {
            Class.forName("android.hardware.input.InputManager").getMethod("getInstance").invoke(null)!!
        }
        inject = manager.javaClass.getMethod("injectInputEvent", InputEvent::class.java, Int::class.javaPrimitiveType)
        setActionButton = try {
            MotionEvent::class.java.getMethod("setActionButton", Int::class.javaPrimitiveType)
        } catch (_: Exception) { null }
        val server = try { LocalServerSocket(SOCKET) } catch (e: Exception) {
            System.err.println("Localview Pro input is already running")
            return
        }
        println("Localview Pro input ready")
        while (true) {
            val s = server.accept()
            Thread { serve(s, token) }.start()
        }
    }

    private fun serve(s: LocalSocket, token: String) {
        try {
            val r = BufferedReader(InputStreamReader(s.inputStream))
            val out = s.outputStream
            if (r.readLine() != token) { s.close(); return }
            out.write("ok\n".toByteArray())
            while (true) {
                val line = r.readLine() ?: break
                val p = line.split(' ')
                synchronized(this) {
                    when (p[0]) {
                        "m" -> move(p[1].toFloat(), p[2].toFloat())
                        "b" -> button(p[1].toInt(), p[2] == "1", p[3].toFloat(), p[4].toFloat())
                        "s" -> scroll(p[1].toFloat(), p[2].toFloat(), p[3].toFloat(), p[4].toFloat())
                        "k" -> key(p[1].toInt(), p[2] == "1")
                        "t" -> out.write((if (text(String(Base64.decode(p[1], Base64.DEFAULT)))) "ok\n" else "no\n").toByteArray())
                        "p" -> out.write("pong\n".toByteArray())
                    }
                }
            }
        } catch (_: Exception) {
        } finally {
            try { s.close() } catch (_: Exception) {}
        }
    }

    private fun send(e: InputEvent) {
        try { inject.invoke(manager, e, 0 /* INJECT_INPUT_EVENT_MODE_ASYNC */) } catch (_: Exception) {}
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
