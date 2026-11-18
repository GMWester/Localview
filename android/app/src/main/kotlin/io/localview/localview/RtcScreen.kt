package io.localview.localview

import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.StateProvider
import com.cloudwebrtc.webrtc.utils.EglUtils
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoFrame
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
    private var idle: HandlerThread? = null
    @Volatile private var lastFrameAt = 0L
    @Volatile private var lastCopy: VideoFrame? = null
    @Volatile private var lastCopyAt = 0L

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
        h.startListening { frame ->
            val now = System.nanoTime()
            lastFrameAt = now
            observer.onFrameCaptured(frame)
            // A CPU copy now and then, re-sent while the screen is still, so a viewer that
            // (re)joins or lost a packet gets a picture without waiting for the screen to change.
            if (now - lastCopyAt > 400_000_000L) {
                lastCopyAt = now
                val copy = try { frame.buffer.toI420() } catch (_: Exception) { null }
                if (copy != null) {
                    val old = lastCopy
                    lastCopy = VideoFrame(copy, frame.rotation, now)
                    old?.release()
                }
            }
        }
        val s = Surface(h.surfaceTexture)
        svc.useSurface(s) { nw, nh -> h.setTextureSize(nw, nh) }
        helper = h
        surface = s
        source = src
        lastFrameAt = System.nanoTime()

        val t = HandlerThread("localview-rtc-idle").apply { start() }
        idle = t
        val ih = Handler(t.looper)
        ih.post(object : Runnable {
            override fun run() {
                if (idle !== t) return
                val f = lastCopy
                if (f != null && System.nanoTime() - lastFrameAt > 500_000_000L) {
                    f.retain()
                    observer.onFrameCaptured(VideoFrame(f.buffer, f.rotation, System.nanoTime()))
                    f.release()
                }
                ih.postDelayed(this, 500)
            }
        })

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
        idle?.quitSafely()
        idle = null
        try { h.stopListening() } catch (_: Exception) {}
        try { source?.capturerObserver?.onCapturerStopped() } catch (_: Exception) {}
        lastCopy?.release()
        lastCopy = null
        surface?.release()
        h.dispose()
        helper = null
        surface = null
        source = null
    }
}
