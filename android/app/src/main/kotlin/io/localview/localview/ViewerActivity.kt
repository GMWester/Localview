package io.localview.localview

import android.app.ActivityManager
import android.os.Bundle

/**
 * An extra Localview window showing one device / monitor. Started by [MainActivity]
 * ("openWindow") in its own task, so phones show it as a separate app window and
 * Android XR / Meta Quest as a separate panel. Runs its own Flutter engine; the Dart
 * side starts in viewer mode when it finds [EXTRA_LAUNCH].
 */
class ViewerActivity : MainActivity() {
    companion object {
        const val EXTRA_LAUNCH = "io.localview.viewer.launch"
        const val EXTRA_TITLE = "io.localview.viewer.title"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: return
        setTitle(title)
        @Suppress("DEPRECATION")
        setTaskDescription(ActivityManager.TaskDescription(title))
    }
}
