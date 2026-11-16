package io.localview.localview

import android.Manifest
import android.app.Activity
import android.app.UiModeManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val reqCapture = 4711
    private var pendingCapture: MethodChannel.Result? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("localview-discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        try { multicastLock?.release() } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "localview/android").setMethodCallHandler { call, result ->
            val a11y = LocalviewAccessibilityService.instance
            fun d(k: String) = (call.argument<Number>(k) ?: 0.0).toDouble()
            when (call.method) {
                "startCapture" -> {
                    if (CaptureService.running) { result.success(true); return@setMethodCallHandler }
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                    }
                    val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                    pendingCapture = result
                    @Suppress("DEPRECATION")
                    startActivityForResult(mpm.createScreenCaptureIntent(), reqCapture)
                }
                "stopCapture" -> { stopService(Intent(this, CaptureService::class.java)); result.success(null) }
                "isCapturing" -> result.success(CaptureService.running)
                "grab" -> {
                    val f = CaptureService.latest
                    if (f == null) result.success(null)
                    else result.success(mapOf("w" to f.width, "h" to f.height, "data" to f.data))
                }
                "accessibilityEnabled" -> result.success(isAccessibilityEnabled())
                "openAccessibilitySettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                "requestAllFilesAccess" -> { requestAllFilesAccess(); result.success(null) }
                "isTv" -> {
                    val ui = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                    result.success(ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
                        packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK))
                }
                "addDrive" -> {
                    DriveProvider.drives[call.argument<String>("id")!!] =
                        DriveProvider.Drive(call.argument<String>("name")!!, call.argument<String>("url")!!)
                    notifyRoots(); result.success(null)
                }
                "removeDrive" -> {
                    DriveProvider.drives.remove(call.argument<String>("id")!!)
                    notifyRoots(); result.success(null)
                }
                "tap" -> { a11y?.tap(d("x"), d("y"), 60); result.success(a11y != null) }
                "longPress" -> { a11y?.tap(d("x"), d("y"), 800); result.success(a11y != null) }
                "swipe" -> {
                    val pts = call.argument<DoubleArray>("points") ?: DoubleArray(0)
                    a11y?.swipe(pts, (call.argument<Number>("ms") ?: 300).toLong()); result.success(a11y != null)
                }
                "scroll" -> { a11y?.scroll(d("x"), d("y"), d("dx"), d("dy")); result.success(a11y != null) }
                "global" -> { a11y?.global(call.argument<Int>("action") ?: 1); result.success(a11y != null) }
                "text" -> { a11y?.typeText(call.argument<String>("text") ?: ""); result.success(a11y != null) }
                "key" -> { a11y?.key(call.argument<String>("key") ?: ""); result.success(a11y != null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun notifyRoots() {
        contentResolver.notifyChange(DocumentsContract.buildRootsUri("$packageName.documents"), null)
    }

    private fun isAccessibilityEnabled(): Boolean {
        val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val me = ComponentName(this, LocalviewAccessibilityService::class.java).flattenToString()
        return enabled.split(':').any { it.equals(me, ignoreCase = true) }
    }

    private fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    private fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")))
            } catch (_: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE), 2)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != reqCapture) return
        val r = pendingCapture
        pendingCapture = null
        if (resultCode != Activity.RESULT_OK || data == null) { r?.success(false); return }
        val i = Intent(this, CaptureService::class.java)
            .putExtra(CaptureService.EXTRA_CODE, resultCode)
            .putExtra(CaptureService.EXTRA_DATA, data)
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
        r?.success(true)
    }
}
