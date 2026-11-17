package io.localview.localview

import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

/**
 * Android XR theater hooks. This is the stub used by the phone/tablet/TV builds;
 * the android-xr branch replaces it with the Jetpack XR SceneCore implementation.
 */
object XrBridge {
    fun handle(activity: FlutterActivity, method: String, args: Map<String, Any?>?, result: MethodChannel.Result): Boolean {
        if (!method.startsWith("xr.")) return false
        when (method) {
            "xr.available" -> result.success(false)
            else -> result.success(false)
        }
        return true
    }
}
