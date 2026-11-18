package io.localview.localview

import android.content.Context
import android.os.Build
import android.provider.Settings

/**
 * Without Localview Pro the panel can't be switched off while it is being shared (an overlay would
 * be captured too), so the brightness goes to its minimum instead. The previous brightness is kept
 * in preferences, so it comes back even if Localview was closed meanwhile.
 */
object ScreenDim {
    private const val PREFS = "localview_dim"

    /** null on success, "permission" if "Modify system settings" is still needed, else the reason. */
    fun set(ctx: Context, dim: Boolean): String? {
        if (Build.VERSION.SDK_INT >= 23 && !Settings.System.canWrite(ctx)) return if (dim) "permission" else null
        val cr = ctx.contentResolver
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return try {
            if (dim) {
                if (!prefs.contains("brightness")) {
                    prefs.edit()
                        .putInt("brightness", Settings.System.getInt(cr, Settings.System.SCREEN_BRIGHTNESS, 128))
                        .putInt("mode", Settings.System.getInt(cr, Settings.System.SCREEN_BRIGHTNESS_MODE, 0))
                        .commit()
                }
                Settings.System.putInt(cr, Settings.System.SCREEN_BRIGHTNESS_MODE, Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL)
                Settings.System.putInt(cr, Settings.System.SCREEN_BRIGHTNESS, 0)
            } else if (prefs.contains("brightness")) {
                Settings.System.putInt(cr, Settings.System.SCREEN_BRIGHTNESS, prefs.getInt("brightness", 128))
                Settings.System.putInt(cr, Settings.System.SCREEN_BRIGHTNESS_MODE, prefs.getInt("mode", 0))
                prefs.edit().clear().commit()
            }
            null
        } catch (e: Exception) {
            e.message ?: "failed"
        }
    }
}
