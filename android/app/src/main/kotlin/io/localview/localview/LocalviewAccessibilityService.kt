package io.localview.localview

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.os.Bundle
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
        stroke(Path().apply { moveTo(sx, sy); lineTo(ex, ey) }, 200)
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
