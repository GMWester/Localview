package io.localview.localview

import android.content.Context
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.view.Display
import android.view.Surface

/**
 * The built-in screen's current size in pixels (logical pixels, what input and capture use),
 * always matching the current rotation. Size readings outside the visible app can stay at the
 * previous orientation after the screen turned, so the result is checked against the display's
 * rotation and swapped when it doesn't match; otherwise remote clicks land in the wrong places
 * and the picture of a horizontal screen gets black bars.
 */
object DisplaySize {
    fun current(ctx: Context): Pair<Float, Float> {
        val (w, h) = currentInt(ctx)
        return Pair(w.toFloat(), h.toFloat())
    }

    fun currentInt(ctx: Context): Pair<Int, Int> {
        val dm = ctx.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val d = dm.getDisplay(Display.DEFAULT_DISPLAY)
        val p = Point()
        @Suppress("DEPRECATION") d.getRealSize(p)
        var w = p.x
        var h = p.y
        // Natural orientation from the panel itself (phones: portrait; some tablets: landscape).
        val mode = d.mode
        val naturalLandscape = mode.physicalWidth > mode.physicalHeight
        val turned = d.rotation == Surface.ROTATION_90 || d.rotation == Surface.ROTATION_270
        val wantLandscape = turned != naturalLandscape
        if ((w > h) != wantLandscape && w != h) { val t = w; w = h; h = t }
        return Pair(w, h)
    }
}
