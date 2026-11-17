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
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

open class MainActivity : FlutterActivity() {
    companion object {
        /** Channel to the Flutter UI; used by the VR activity to report back. */
        var channel: MethodChannel? = null
    }

    private val reqCapture = 4711
    private var pendingCapture: MethodChannel.Result? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var myChannel: MethodChannel? = null

    // The main window's Flutter engine outlives the activity, so connections keep running
    // after the window is closed (KeepAliveService keeps the process). Viewer windows get
    // their own engine each.
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        if (this is ViewerActivity) return null
        FlutterEngineCache.getInstance().get("main")?.let { return it }
        val engine = FlutterEngine(context.applicationContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put("main", engine)
        return engine
    }

    override fun shouldDestroyEngineWithHost(): Boolean = this is ViewerActivity

    /** True unless [apk] is known to be signed with a different key than this app. */
    private fun sameSigner(apk: String): Boolean = try {
        fun signers(p: android.content.pm.PackageInfo?): Set<String> = when {
            p == null -> emptySet()
            Build.VERSION.SDK_INT >= 28 -> (p.signingInfo?.apkContentsSigners ?: emptyArray()).map { it.toCharsString() }.toSet()
            else -> @Suppress("DEPRECATION") (p.signatures ?: emptyArray()).map { it.toCharsString() }.toSet()
        }
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
            else @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES
        val update = signers(packageManager.getPackageArchiveInfo(apk, flags))
        update.isEmpty() || update == signers(packageManager.getPackageInfo(packageName, flags))
    } catch (_: Exception) {
        true
    }

    /** Mounted storage volumes (internal storage, SD cards, USB drives) with their paths. */
    private fun storageVolumes(): List<Map<String, Any?>> {
        val sm = getSystemService(Context.STORAGE_SERVICE) as StorageManager
        val out = mutableListOf<Map<String, Any?>>()
        for (v in sm.storageVolumes) {
            val state = v.state
            if (state != Environment.MEDIA_MOUNTED && state != Environment.MEDIA_MOUNTED_READ_ONLY) continue
            val path = if (Build.VERSION.SDK_INT >= 30) {
                v.directory?.absolutePath
            } else {
                try { v.javaClass.getMethod("getPath").invoke(v) as? String } catch (_: Exception) { null }
            } ?: continue
            out.add(mapOf(
                "path" to path,
                "description" to v.getDescription(this),
                "primary" to v.isPrimary,
                "removable" to v.isRemovable,
                "uuid" to v.uuid,
            ))
        }
        return out
    }

    override fun onResume() {
        super.onResume()
        // The VR activity reports to whichever Localview window was used last.
        myChannel?.let { channel = it }
    }

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
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "localview/android")
        channel = ch
        myChannel = ch
        ch.setMethodCallHandler { call, result ->
            @Suppress("UNCHECKED_CAST")
            if (XrBridge.handle(this, call.method, call.arguments as? Map<String, Any?>, result)) return@setMethodCallHandler
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
                // Extra viewer windows (new task; a separate panel on Android XR / Meta Quest).
                "openWindow" -> {
                    val launch = call.argument<String>("launch")
                    val title = call.argument<String>("title")
                    val i = Intent(this, ViewerActivity::class.java)
                        .putExtra(ViewerActivity.EXTRA_LAUNCH, launch)
                        .putExtra(ViewerActivity.EXTRA_TITLE, title)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NEW_DOCUMENT or
                            Intent.FLAG_ACTIVITY_MULTIPLE_TASK or Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT)
                    try {
                        startActivity(i)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("window", e.message, null)
                    }
                }
                "viewerLaunch" -> result.success(intent?.getStringExtra(ViewerActivity.EXTRA_LAUNCH))
                "closeWindow" -> { finishAndRemoveTask(); result.success(null) }
                "setKeepAlive" -> {
                    KeepAliveService.update(this, call.argument<Boolean>("on") == true, call.argument<String>("tip") ?: "")
                    result.success(null)
                }
                "setRotation" -> {
                    // portrait | landscape | auto. Apps that fix their own orientation keep it.
                    val mode = call.argument<String>("mode") ?: "auto"
                    if (Build.VERSION.SDK_INT >= 23 && !Settings.System.canWrite(this)) {
                        startActivity(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:$packageName"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success("permission")
                    } else {
                        try {
                            val cr = contentResolver
                            if (mode == "auto") {
                                Settings.System.putInt(cr, Settings.System.ACCELEROMETER_ROTATION, 1)
                            } else {
                                Settings.System.putInt(cr, Settings.System.ACCELEROMETER_ROTATION, 0)
                                Settings.System.putInt(cr, Settings.System.USER_ROTATION,
                                    if (mode == "landscape") android.view.Surface.ROTATION_90 else android.view.Surface.ROTATION_0)
                            }
                            result.success(null)
                        } catch (e: Exception) {
                            result.success(e.message ?: "failed")
                        }
                    }
                }
                "grabJpeg" -> {
                    val last = (call.argument<Number>("last") ?: -1).toLong()
                    JpegEncoder.encodeLatest(last, call.argument<Int>("maxSide") ?: 1920, call.argument<Int>("quality") ?: 70) {
                        result.success(it)
                    }
                }
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
                "installApk" -> {
                    // In-app update: hand the downloaded APK to the system installer.
                    val file = java.io.File(call.argument<String>("path")!!)
                    if (!sameSigner(file.path)) {
                        // Android refuses updates signed with another key ("package conflicts").
                        result.success("signature")
                    } else if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                        result.success("permission")
                    } else {
                        val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.updates", file)
                        startActivity(
                            Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success("ok")
                    }
                }
                "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                "storageVolumes" -> result.success(storageVolumes())
                "adbStatus" -> AdbInfo.status(this) { result.success(it) }
                "openDeveloperOptions" -> {
                    try { startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)) } catch (_: Exception) {}
                    result.success(null)
                }
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
