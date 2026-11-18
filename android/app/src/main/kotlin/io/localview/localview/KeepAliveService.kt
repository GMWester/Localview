package io.localview.localview

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keep running in the background: while Localview is connected to other devices, this
 * foreground service keeps the app process (and its Flutter engine with the connections and
 * shared drives) alive after the window is closed or swiped away.
 */
class KeepAliveService : Service() {
    companion object {
        const val EXTRA_TEXT = "text"
        @Volatile var running = false

        fun update(context: Context, on: Boolean, text: String) {
            val i = Intent(context, KeepAliveService::class.java).putExtra(EXTRA_TEXT, text)
            if (on) {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
            } else if (running) {
                context.stopService(i)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        NetLocks.hold(this)
        running = true
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel("connections", "Connections", NotificationManager.IMPORTANCE_LOW))
            Notification.Builder(this, "connections")
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = builder.setContentTitle("Localview")
            .setContentText(intent?.getStringExtra(EXTRA_TEXT) ?: "Connected in the background")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(2, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(2, n)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }
}
