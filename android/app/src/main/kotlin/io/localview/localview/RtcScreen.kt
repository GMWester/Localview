package io.localview.localview

import android.view.Surface
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.StateProvider
import com.cloudwebrtc.webrtc.utils.EglUtils
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSource

/**
 * Game mode on Android: Localview's screen capture (the MediaProjection that is already running)
 * feeds a WebRTC video track, which flutter_webrtc then encodes in hardware (H.264) like a camera.
 * Registered with flutter_webrtc as a normal local stream, so the Dart side uses it as usual.
 */
object RtcScreen {
    private var helper: SurfaceTextureHelper? = null
    private var surface: Surface? = null
    private var source: VideoSource? = null

    @Synchronized
    fun start(): Map<String, Any?> {
        stop()
        val svc = CaptureService.instance ?: throw IllegalStateException("Screen sharing is not running")
        val plugin = FlutterWebRTCPlugin.sharedSingleton ?: throw IllegalStateException("WebRTC is not ready")
        val factory = plugin.peerConnectionFactory ?: throw IllegalStateException("WebRTC is not ready")
        val state = FlutterWebRTCPlugin::class.java.getDeclaredField("methodCallHandler")
            .apply { isAccessible = true }.get(plugin) as StateProvider

        val src = factory.createVideoSource(true)
        val h = SurfaceTextureHelper.create("localview-rtc-screen", EglUtils.getRootEglBaseContext())
            ?: throw IllegalStateException("No video surface")
        val (w, hh) = svc.size()
        h.setTextureSize(w, hh)
        val observer = src.capturerObserver
        observer.onCapturerStarted(true)
        // Frames go straight to the encoder. While the screen is still, WebRTC's screen-share mode
        // repeats the last frame itself (an older copy re-sent here showed stale pictures).
        h.startListening { frame -> observer.onFrameCaptured(frame) }
        val s = Surface(h.surfaceTexture)
        svc.useSurface(s) { nw, nh -> h.setTextureSize(nw, nh) }
        helper = h
        surface = s
        source = src

        val trackId = state.nextTrackUUID
        val streamId = state.nextStreamUUID
        val track = factory.createVideoTrack(trackId, src)
        val stream = factory.createLocalMediaStream(streamId)
        stream.addTrack(track)
        val local = LocalVideoTrack(track)
        src.setVideoProcessor(local)
        state.putLocalTrack(trackId, local)
        state.putLocalStream(streamId, stream)
        return mapOf(
            "streamId" to streamId,
            "audioTracks" to emptyList<Any>(),
            "videoTracks" to listOf(mapOf(
                "enabled" to true, "id" to trackId, "kind" to "video", "label" to "video",
                "readyState" to "live", "remote" to false,
                "settings" to mapOf("width" to w, "height" to hh),
            )),
            "width" to w, "height" to hh,
        )
    }

    /** Back to still images (also when the stream ends). */
    @Synchronized
    fun stop() {
        val h = helper ?: return
        CaptureService.instance?.useSurface(null, null)
        try { h.stopListening() } catch (_: Exception) {}
        try { source?.capturerObserver?.onCapturerStopped() } catch (_: Exception) {}
        surface?.release()
        h.dispose()
        helper = null
        surface = null
        source = null
    }
}
