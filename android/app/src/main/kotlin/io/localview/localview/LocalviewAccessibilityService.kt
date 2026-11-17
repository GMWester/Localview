package io.localview.localview

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.DisplayMetrics
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/** Performs remote taps, swipes, global actions and text entry. */
class LocalviewAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile var instance: LocalviewAccessibilityService? = null
    }

    override fun onServiceConnected() { instance = this }
    override fun onDestroy() { instance = null; super.onDestroy() }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    private fun screen(): Pair<Float, Float> {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        return if (Build.VERSION.SDK_INT >= 30) {
            val b = wm.maximumWindowMetrics.bounds; Pair(b.width().toFloat(), b.height().toFloat())
        } else {
            val m = DisplayMetrics(); @Suppress("DEPRECATION") wm.defaultDisplay.getRealMetrics(m)
            Pair(m.widthPixels.toFloat(), m.heightPixels.toFloat())
        }
    }

    private fun stroke(path: Path, ms: Long) {
        val g = GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, maxOf(1L, ms))).build()
        dispatchGesture(g, null, null)
    }

    // Live touch (Android 8+): the finger goes down when the remote button is pressed, follows
    // the pointer while it is held and lifts on release - no waiting for the whole gesture.
    private var live: GestureDescription.StrokeDescription? = null
    private var liveX = 0f
    private var liveY = 0f
    private var liveAt = 0L

    val supportsLiveTouch: Boolean get() = Build.VERSION.SDK_INT >= 26

    fun touchDown(x: Double, y: Double) {
        if (Build.VERSION.SDK_INT < 26) return
        val (w, h) = screen()
        liveX = (x * w).toFloat().coerceIn(0f, w - 1)
        liveY = (y * h).toFloat().coerceIn(0f, h - 1)
        liveAt = SystemClock.uptimeMillis()
        val s = GestureDescription.StrokeDescription(Path().apply { moveTo(liveX, liveY) }, 0, 1, true)
        live = s
        dispatchGesture(GestureDescription.Builder().addStroke(s).build(), null, null)
    }

    fun touchMove(x: Double, y: Double, end: Boolean) {
        if (Build.VERSION.SDK_INT < 26) return
        val prev = live ?: return
        val (w, h) = screen()
        val nx = (x * w).toFloat().coerceIn(0f, w - 1)
        val ny = (y * h).toFloat().coerceIn(0f, h - 1)
        val now = SystemClock.uptimeMillis()
        val ms = (now - liveAt).coerceIn(1L, 100L)
        val path = Path().apply { moveTo(liveX, liveY); lineTo(nx, ny) }
        val next = try {
            prev.continueStroke(path, 0, ms, !end)
        } catch (_: Exception) {
            live = null
            return
        }
        live = if (end) null else next
        liveX = nx
        liveY = ny
        liveAt = now
        dispatchGesture(GestureDescription.Builder().addStroke(next).build(), null, null)
    }

    fun tap(x: Double, y: Double, ms: Long) {
        val (w, h) = screen()
        stroke(Path().apply { moveTo((x * w).toFloat(), (y * h).toFloat()) }, ms)
    }

    fun swipe(points: DoubleArray, ms: Long) {
        if (points.size < 4) return
        val (w, h) = screen()
        val p = Path()
        p.moveTo((points[0] * w).toFloat(), (points[1] * h).toFloat())
        var i = 2
        while (i + 1 < points.size) { p.lineTo((points[i] * w).toFloat(), (points[i + 1] * h).toFloat()); i += 2 }
        stroke(p, ms)
    }

    fun scroll(x: Double, y: Double, dx: Double, dy: Double) {
        val (w, h) = screen()
        val sx = (x * w).toFloat(); val sy = (y * h).toFloat()
        val ex = (sx - dx * w * 0.06).toFloat().coerceIn(1f, w - 1)
        val ey = (sy - dy * h * 0.06).toFloat().coerceIn(1f, h - 1)
        // Short and quick: several wheel notches arrive already combined into one swipe.
        stroke(Path().apply { moveTo(sx, sy); lineTo(ex, ey) }, 90)
    }

    fun global(action: Int) {
        performGlobalAction(when (action) {
            2 -> GLOBAL_ACTION_HOME
            3 -> GLOBAL_ACTION_RECENTS
            4 -> GLOBAL_ACTION_NOTIFICATIONS
            else -> GLOBAL_ACTION_BACK
        })
    }

    private fun focused(): AccessibilityNodeInfo? = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    private fun currentText(n: AccessibilityNodeInfo): String {
        if (Build.VERSION.SDK_INT >= 26 && n.isShowingHintText) return ""
        return n.text?.toString() ?: ""
    }

    private fun setText(n: AccessibilityNodeInfo, t: String) {
        val b = Bundle()
        b.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, t)
        n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, b)
    }

    fun typeText(t: String) {
        val n = focused() ?: return
        setText(n, currentText(n) + t)
    }

    fun key(k: String) {
        val n = focused() ?: return
        when (k) {
            "backspace" -> { val c = currentText(n); if (c.isNotEmpty()) setText(n, c.dropLast(1)) }
            "enter" -> if (Build.VERSION.SDK_INT >= 30) {
                n.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
            } else {
                setText(n, currentText(n) + "\n")
            }
        }
    }
}
