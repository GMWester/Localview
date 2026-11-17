package io.localview.localview

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Low-latency streaming from Android hosts: the newest captured frame is scaled and
 * JPEG-compressed natively (Android's libjpeg-turbo), off the UI thread. That is far
 * faster and smaller than pixel tiles compressed in Dart, which made a phone host lag
 * by up to a couple of seconds whenever much of the screen changed.
 */
object JpegEncoder {
    private val exec = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var bitmap: Bitmap? = null
    private val out = ByteArrayOutputStream(512 * 1024)

    // While a viewer is streaming, every new screen image is encoded as soon as it is captured,
    // so the next request is answered immediately instead of waiting for the encoder.
    @Volatile private var wantedUntil = 0L
    @Volatile private var maxSide = 1440
    @Volatile private var quality = 70
    @Volatile private var ready: Map<String, Any>? = null
    @Volatile private var busy = false

    /** Called by CaptureService for every new screen image. */
    fun onNewFrame() {
        if (SystemClock.uptimeMillis() > wantedUntil || busy) return
        busy = true
        exec.execute {
            try {
                CaptureService.latest?.let { f -> encode(f, maxSide, quality)?.let { ready = it } }
            } finally {
                busy = false
            }
        }
    }

    /** The newest frame as JPEG unless it is still [lastSeq]; [done] runs on the main thread. */
    fun encodeLatest(lastSeq: Long, maxSide: Int, quality: Int, done: (Map<String, Any>?) -> Unit) {
        wantedUntil = SystemClock.uptimeMillis() + 1500
        val changed = maxSide != this.maxSide || quality != this.quality
        this.maxSide = maxSide
        this.quality = quality
        val r = ready
        if (!changed && r != null && (r["seq"] as Long) > lastSeq) {
            main.post { done(r) }
            return
        }
        exec.execute {
            val f = CaptureService.latest
            val result = if (f == null || f.seq == lastSeq) null else encode(f, maxSide, quality)
            if (result != null) ready = result
            main.post { done(result) }
        }
    }

    private fun encode(f: CaptureService.Frame, maxSide: Int, quality: Int): Map<String, Any>? = try {
        var b = bitmap
        if (b == null || b.width != f.width || b.height != f.height) {
            b?.recycle()
            b = Bitmap.createBitmap(f.width, f.height, Bitmap.Config.ARGB_8888)
            bitmap = b
        }
        b!!.copyPixelsFromBuffer(ByteBuffer.wrap(f.data))
        val s = minOf(1.0, maxSide.toDouble() / maxOf(f.width, f.height))
        val src = if (s < 0.999) {
            Bitmap.createScaledBitmap(b, maxOf(2, ((f.width * s).toInt() / 2) * 2), maxOf(2, ((f.height * s).toInt() / 2) * 2), true)
        } else b
        out.reset()
        src.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(30, 95), out)
        val r = mapOf<String, Any>("seq" to f.seq, "w" to src.width, "h" to src.height, "jpeg" to out.toByteArray())
        if (src !== b) src.recycle()
        r
    } catch (_: Exception) {
        null
    }
}
