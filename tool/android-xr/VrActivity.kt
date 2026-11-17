package io.localview.localview

import android.app.NativeActivity
import android.os.Bundle
import android.view.WindowManager

/**
 * Immersive OpenXR activity (native code in libLocalview_vr.so) that plays
 * SteamVR games streamed from a PC running the Localview SteamVR driver.
 */
class VrActivity : NativeActivity() {
    companion object {
        init {
            System.loadLibrary("localview_vr")
        }

        @JvmStatic external fun nativeConnect(host: String, port: Int, keyHex: String)

        var running = false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        running = true
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    // Called from native code (any thread).
    @Suppress("unused")
    fun onDisplayInfo(json: String) = runOnUiThread { MainActivity.channel?.invokeMethod("vr.displayInfo", json) }

    @Suppress("unused")
    fun onVrEnded(unused: String) = runOnUiThread { MainActivity.channel?.invokeMethod("vr.ended", null) }

    @Suppress("unused")
    fun onVrError(message: String) = runOnUiThread { MainActivity.channel?.invokeMethod("vr.error", message) }
}
