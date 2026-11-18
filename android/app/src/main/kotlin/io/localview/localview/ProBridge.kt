package io.localview.localview

import android.content.Context
import io.flutter.plugin.common.MethodChannel

/**
 * Real mouse & keyboard input ("Localview Pro"). The regular Android build has no such
 * helper; the android-pro branch replaces this file with the real bridge.
 */
object ProBridge {
    /** The device's whole sound output from the Pro helper; never available in the regular build. */
    @Suppress("UNUSED_PARAMETER")
    fun openAudio(ctx: Context): java.io.InputStream? = null

    /** Display panel off/on: needs the Pro helper; the regular build answers "not running". */
    @Suppress("UNUSED_PARAMETER")
    fun screenPower(ctx: Context, on: Boolean): String? = "not running"

    fun handle(ctx: Context, method: String, args: Map<String, Any?>?, result: MethodChannel.Result): Boolean {
        if (method == "pro.status") {
            result.success(mapOf("pro" to false))
            return true
        }
        return false
    }
}
