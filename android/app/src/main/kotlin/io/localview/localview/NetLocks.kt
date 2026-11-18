package io.localview.localview

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build

/**
 * Keeps Wi-Fi responsive while Localview runs, also in the background: the multicast lock lets
 * discovery broadcasts from other devices through (Android drops them to save power otherwise,
 * so this device kept vanishing from their Nearby lists), and the Wi-Fi lock keeps power saving
 * from adding delay to the stream and input. Held once for the whole process.
 */
object NetLocks {
    private var multicast: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    @Synchronized
    fun hold(ctx: Context) {
        val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
        if (multicast == null) try {
            multicast = wifi.createMulticastLock("localview-discovery").apply { setReferenceCounted(false); acquire() }
        } catch (_: Exception) {}
        if (wifiLock == null) try {
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifiLock = wifi.createWifiLock(mode, "localview").apply { setReferenceCounted(false); acquire() }
        } catch (_: Exception) {}
    }

    @Synchronized
    fun release() {
        try { multicast?.release() } catch (_: Exception) {}
        try { wifiLock?.release() } catch (_: Exception) {}
        multicast = null
        wifiLock = null
    }
}
