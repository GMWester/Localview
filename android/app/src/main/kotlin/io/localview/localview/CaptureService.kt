package io.localview.localview

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.DisplayMetrics
import android.view.WindowManager

/** Foreground service that mirrors the screen into an ImageReader (MediaProjection). */
class CaptureService : Service() {
    /** One captured screen image (RGBA); [seq] increases with every new image. */
    class Frame(val width: Int, val height: Int, val data: ByteArray, val seq: Long)

    companion object {
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        @Volatile var latest: Frame? = null
        @Volatile var running = false
        private var frameCounter = 0L
        const val MAX_SIDE = 1920
    }

    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private val thread = HandlerThread("localview-capture").apply { start() }
    private val handler = Handler(thread.looper)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel("capture", "Remote control", NotificationManager.IMPORTANCE_LOW))
            Notification.Builder(this, "capture")
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        val n = builder.setContentTitle("Localview").setContentText("This screen can be viewed by your paired devices")
            .setSmallIcon(android.R.drawable.ic_menu_view).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        else startForeground(1, n)

        val code = intent?.getIntExtra(EXTRA_CODE, 0) ?: 0
        @Suppress("DEPRECATION")
        val data: Intent? = intent?.getParcelableExtra(EXTRA_DATA)
        if (data == null) { stopSelf(); return START_NOT_STICKY }
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val p = mpm.getMediaProjection(code, data) ?: run { stopSelf(); return START_NOT_STICKY }
        projection = p
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() { stopSelf() }
        }, handler)

        val (w, h) = captureSize()
        val r = newReader(w, h)
        val dpi = resources.displayMetrics.densityDpi
        display = p.createVirtualDisplay("localview", w, h, dpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, handler)
        // Follow rotation (turning the phone, or a viewer switching portrait / landscape).
        val dm = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        dm.registerDisplayListener(displayListener, handler)
        running = true
        return START_NOT_STICKY
    }

    private var captureW = 0
    private var captureH = 0

    /** Current screen size (follows rotation), scaled to at most MAX_SIDE, even numbers. */
    private fun captureSize(): Pair<Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION") wm.defaultDisplay.getRealMetrics(metrics)
        val sw = metrics.widthPixels
        val sh = metrics.heightPixels
        val scale = minOf(1.0, MAX_SIDE.toDouble() / maxOf(sw, sh))
        return Pair(((sw * scale).toInt() / 2) * 2, ((sh * scale).toInt() / 2) * 2)
    }

    private fun newReader(w: Int, h: Int): ImageReader {
        captureW = w
        captureH = h
        val r = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        r.setOnImageAvailableListener({ ir ->
            val img = try { ir.acquireLatestImage() } catch (_: Exception) { null } ?: return@setOnImageAvailableListener
            try {
                val plane = img.planes[0]
                val buf = plane.buffer
                val rowStride = plane.rowStride
                val iw = img.width
                val ih = img.height
                val out = ByteArray(iw * ih * 4)
                if (rowStride == iw * 4) {
                    buf.get(out, 0, out.size)
                } else {
                    for (y in 0 until ih) {
                        buf.position(y * rowStride)
                        buf.get(out, y * iw * 4, iw * 4)
                    }
                }
                latest = Frame(iw, ih, out, ++frameCounter)
                JpegEncoder.onNewFrame()
            } finally {
                img.close()
            }
        }, handler)
        reader = r
        return r
    }

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(id: Int) {}
        override fun onDisplayRemoved(id: Int) {}
        override fun onDisplayChanged(id: Int) {
            if (id != android.view.Display.DEFAULT_DISPLAY) return
            val (w, h) = captureSize()
            if (w == captureW && h == captureH) return
            val vd = display ?: return
            val old = reader
            val r = newReader(w, h)
            vd.resize(w, h, resources.displayMetrics.densityDpi)
            vd.surface = r.surface
            old?.close()
        }
    }

    override fun onDestroy() {
        try { (getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).unregisterDisplayListener(displayListener) } catch (_: Exception) {}
        running = false
        latest = null
        display?.release()
        reader?.close()
        try { projection?.stop() } catch (_: Exception) {}
        thread.quitSafely()
        super.onDestroy()
    }
}
