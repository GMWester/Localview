package io.localview.localview

import android.content.Context
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.view.Display

/**
 * The built-in screen's current size in pixels, following rotation. Read from the display itself:
 * window metrics of the app or service context can keep the portrait size after the screen turned
 * (the app is in the background), which put remote clicks in the wrong places in landscape.
 */
object DisplaySize {
    fun current(ctx: Context): Pair<Float, Float> {
        val dm = ctx.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val d = dm.getDisplay(Display.DEFAULT_DISPLAY)
        val p = Point()
        @Suppress("DEPRECATION") d.getRealSize(p)
        return Pair(p.x.toFloat(), p.y.toFloat())
    }
}
