package io.localview.localview

import android.content.Context
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.view.Display

/**
 * The built-in screen's current size in logical pixels (what input and capture use), following
 * rotation. Read from the display itself: window metrics of an app or service context can keep
 * the vertical size after the screen turned. (No extra rotation check: Display.Mode sizes turn
 * with the screen on some devices, so "correcting" by them forced a vertical size in 1.11.2.)
 */
object DisplaySize {
    fun current(ctx: Context): Pair<Float, Float> {
        val (w, h) = currentInt(ctx)
        return Pair(w.toFloat(), h.toFloat())
    }

    fun currentInt(ctx: Context): Pair<Int, Int> {
        val dm = ctx.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val p = Point()
        @Suppress("DEPRECATION") dm.getDisplay(Display.DEFAULT_DISPLAY).getRealSize(p)
        return Pair(p.x, p.y)
    }
}
