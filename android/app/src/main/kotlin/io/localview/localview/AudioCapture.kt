package io.localview.localview

import android.Manifest
import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.os.Build

/**
 * Captures what apps play (Android 10+, AudioPlaybackCapture on the screen-sharing MediaProjection)
 * as 48 kHz stereo 16-bit PCM, so it can play on the controlling device instead. While it runs the
 * phone's media volume is set to zero: the capture taps the sound before the speaker volume, so the
 * controlling device still gets it at full level. Apps that forbid capture (some DRM players) stay silent.
 */
object AudioCapture {
    const val RATE = 48000
    @Volatile private var record: AudioRecord? = null
    @Volatile private var proIn: java.io.InputStream? = null
    private var thread: Thread? = null
    private val lock = Object()
    private var buf = ByteArray(RATE * 4) // up to 1 s waiting
    private var len = 0
    private var savedVolume = -1

    fun supported(): Boolean = Build.VERSION.SDK_INT >= 29

    fun permitted(ctx: Context): Boolean =
        Build.VERSION.SDK_INT >= 29 && ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /** null on success, else the reason. */
    @SuppressLint("MissingPermission")
    @TargetApi(29)
    fun start(ctx: Context, silencePhone: Boolean): String? {
        if (silencePhone && startPro(ctx)) return null
        if (Build.VERSION.SDK_INT < 29) return "Android 10 or newer is needed to send the phone's sound"
        if (!permitted(ctx)) return "Allow Localview to record audio on the phone (it is used to capture the sound apps play)"
        val p = CaptureService.activeProjection ?: return "Screen sharing is not running on the phone"
        synchronized(lock) {
            if (record == null) {
                val cfg = AudioPlaybackCaptureConfiguration.Builder(p)
                    .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                    .addMatchingUsage(AudioAttributes.USAGE_GAME)
                    .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                    .build()
                val fmt = AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_IN_STEREO).build()
                val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT)
                val r = try {
                    AudioRecord.Builder().setAudioFormat(fmt).setBufferSizeInBytes(maxOf(min * 2, RATE / 5 * 4))
                        .setAudioPlaybackCaptureConfig(cfg).build()
                } catch (e: Exception) {
                    return "The phone's sound cannot be captured: ${e.message}"
                }
                if (r.state != AudioRecord.STATE_INITIALIZED) { r.release(); return "The phone's sound cannot be captured" }
                try { r.startRecording() } catch (e: Exception) { r.release(); return "The phone's sound cannot be captured: ${e.message}" }
                record = r
                len = 0
                thread = Thread({
                    val chunk = ByteArray(RATE / 50 * 4) // 20 ms
                    while (record === r) {
                        val n = r.read(chunk, 0, chunk.size)
                        if (n <= 0) { if (n < 0) break else continue }
                        synchronized(lock) {
                            if (len + n > buf.size) len = 0 // nobody reads: drop the old sound
                            System.arraycopy(chunk, 0, buf, len, n)
                            len += n
                        }
                    }
                }, "localview-audio").apply { start() }
            }
        }
        silence(ctx, silencePhone)
        return null
    }

    /**
     * Localview Pro (Android 12+): the helper records the whole sound output, which moves it off the
     * speaker - no volume change, and apps that forbid capture are included.
     */
    private fun startPro(ctx: Context): Boolean {
        synchronized(lock) { if (proIn != null) return true; if (record != null) return false }
        val input = ProBridge.openAudio(ctx) ?: return false
        synchronized(lock) { proIn = input; len = 0 }
        thread = Thread({
            val chunk = ByteArray(RATE / 50 * 4)
            try {
                while (proIn === input) {
                    val n = input.read(chunk)
                    if (n < 0) break
                    if (n == 0) continue
                    synchronized(lock) {
                        if (len + n > buf.size) len = 0
                        System.arraycopy(chunk, 0, buf, len, n)
                        len += n
                    }
                }
            } catch (_: Exception) {}
            synchronized(lock) { if (proIn === input) proIn = null }
        }, "localview-pro-audio").apply { start() }
        return true
    }

    /** Sound captured since the last call (PCM s16le, stereo, 48 kHz), or null. */
    fun read(): ByteArray? = synchronized(lock) {
        if (len == 0) null else buf.copyOf(len).also { len = 0 }
    }

    fun stop(ctx: Context) {
        val (r, pin) = synchronized(lock) { val x = record; val y = proIn; record = null; proIn = null; len = 0; Pair(x, y) }
        try { pin?.close() } catch (_: Exception) {}
        try { r?.stop() } catch (_: Exception) {}
        thread?.join(200)
        thread = null
        r?.release()
        silence(ctx, false)
    }

    private fun silence(ctx: Context, on: Boolean) {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            if (on && savedVolume < 0) {
                savedVolume = am.getStreamVolume(AudioManager.STREAM_MUSIC)
                am.setStreamVolume(AudioManager.STREAM_MUSIC, 0, 0)
            } else if (!on && savedVolume >= 0) {
                // Put the volume back unless the user changed it meanwhile.
                if (am.getStreamVolume(AudioManager.STREAM_MUSIC) == 0) am.setStreamVolume(AudioManager.STREAM_MUSIC, savedVolume, 0)
                savedVolume = -1
            }
        } catch (_: Exception) {}
    }
}
