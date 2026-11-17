package io.localview.localview

import android.util.Log
import androidx.lifecycle.lifecycleScope
import androidx.xr.runtime.Session
import androidx.xr.runtime.SessionCreateSuccess
import androidx.xr.runtime.math.FloatSize2d
import androidx.xr.runtime.math.Pose
import androidx.xr.runtime.math.Vector3
import androidx.xr.scenecore.SpatialEnvironment
import androidx.xr.scenecore.scene
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Virtual-Desktop-style theater on Android XR (Jetpack XR SceneCore 1.0):
 * switches to Full Space, turns the app's main panel into a large screen in
 * front of the user and sets the surroundings (black void, passthrough or the
 * system environment).
 */
object XrBridge {
    private const val TAG = "LocalviewXR"
    private var session: Session? = null
    private var savedSize: FloatSize2d? = null
    private var savedPose: Pose? = null

    private suspend fun ensure(activity: FlutterActivity): Session? {
        session?.let { return it }
        return try {
            when (val r = withContext(Dispatchers.IO) { Session.create(activity) }) {
                is SessionCreateSuccess -> r.session.also { session = it }
                else -> null
            }
        } catch (e: Throwable) {
            Log.w(TAG, "XR session unavailable: $e")
            null
        }
    }

    fun handle(activity: FlutterActivity, method: String, args: Map<String, Any?>?, result: MethodChannel.Result): Boolean {
        if (!method.startsWith("xr.")) return false
        activity.lifecycleScope.launch {
            val s = ensure(activity)
            if (s == null) {
                result.success(false)
                return@launch
            }
            try {
                when (method) {
                    "xr.available" -> result.success(true)
                    "xr.enterTheater" -> {
                        val width = ((args?.get("width") as? Number)?.toFloat() ?: 3.0f).coerceIn(0.8f, 12f)
                        val distance = ((args?.get("distance") as? Number)?.toFloat() ?: 2.5f).coerceIn(0.8f, 15f)
                        val aspect = ((args?.get("aspect") as? Number)?.toFloat() ?: (16f / 9f)).coerceIn(0.4f, 4f)
                        val scene = s.scene
                        scene.requestFullSpace()
                        val panel = scene.mainPanelEntity
                        if (savedSize == null) {
                            savedSize = panel.size
                            savedPose = panel.getPose()
                        }
                        panel.size = FloatSize2d(width, width / aspect)
                        panel.cornerRadius = 0.02f
                        panel.setPose(Pose(Vector3(0f, 0.1f, -distance)))
                        applyEnvironment(s, args?.get("environment") as? String ?: "void")
                        result.success(true)
                    }
                    "xr.setEnvironment" -> {
                        applyEnvironment(s, args?.get("environment") as? String ?: "void")
                        result.success(true)
                    }
                    "xr.exitTheater" -> {
                        val scene = s.scene
                        val panel = scene.mainPanelEntity
                        savedSize?.let { panel.size = it }
                        savedPose?.let { panel.setPose(it) }
                        savedSize = null
                        savedPose = null
                        scene.spatialEnvironment.preferredSpatialEnvironment = null
                        scene.requestHomeSpace()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                Log.w(TAG, "XR call $method failed: $e")
                result.success(false)
            }
        }
        return true
    }

    private fun applyEnvironment(s: Session, env: String) {
        val e = s.scene.spatialEnvironment
        when (env) {
            "passthrough" -> e.preferredPassthroughOpacity = 1.0f
            "system" -> {
                e.preferredPassthroughOpacity = 0.0f
                e.preferredSpatialEnvironment = null
            }
            else -> { // "void": dark cinema
                e.preferredPassthroughOpacity = 0.0f
                e.preferredSpatialEnvironment = SpatialEnvironment.SpatialEnvironmentPreference(null, null)
            }
        }
    }
}
