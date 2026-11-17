package io.localview.localview

import android.content.Context
import io.flutter.plugin.common.MethodChannel

/**
 * Real mouse & keyboard input ("Localview Pro"). The regular Android build has no such
 * helper; the android-pro branch replaces this file with the real bridge.
 */
object ProBridge {
    fun handle(ctx: Context, method: String, args: Map<String, Any?>?, result: MethodChannel.Result): Boolean {
        if (method == "pro.status") {
            result.success(mapOf("pro" to false))
            return true
        }
        return false
    }
}
