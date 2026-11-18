package io.localview.localview

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import java.net.InetAddress
import java.net.NetworkInterface

/**
 * ADB over Localview: finds this device's own adb ports. Android 11+ "Wireless debugging"
 * announces them over mDNS (_adb-tls-connect while it is on, _adb-tls-pairing while the
 * "Pair device with pairing code" dialog is open); classic `adb tcpip` uses
 * service.adb.tcp.port (usually 5555).
 */
object AdbInfo {
    private const val CONNECT = "_adb-tls-connect._tcp."
    private const val PAIRING = "_adb-tls-pairing._tcp."

    fun status(ctx: Context, done: (Map<String, Any?>) -> Unit) {
        val cr = ctx.contentResolver
        val dev = Settings.Global.getInt(cr, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) == 1
        val adb = Settings.Global.getInt(cr, Settings.Global.ADB_ENABLED, 0) == 1
        val wireless = Settings.Global.getInt(cr, "adb_wifi_enabled", 0) == 1
        val legacy = try {
            val sp = Class.forName("android.os.SystemProperties")
            (sp.getMethod("get", String::class.java).invoke(null, "service.adb.tcp.port") as String).toIntOrNull()
        } catch (_: Exception) { null }
        val base = mapOf<String, Any?>(
            "developerOptions" to dev, "usbDebugging" to adb, "wireless" to wireless,
            "legacy" to legacy?.takeIf { it > 0 }, "sdk" to android.os.Build.VERSION.SDK_INT,
        )
        if (!wireless) { done(base + mapOf("connect" to emptyList<Int>(), "pairing" to emptyList<Int>())); return }
        // Fast path: adbd publishes its wireless port as a property (not readable on every device).
        val tls = try {
            val sp = Class.forName("android.os.SystemProperties")
            (sp.getMethod("get", String::class.java).invoke(null, "service.adb.tls.port") as String).toIntOrNull()
        } catch (_: Exception) { null }
        // With the port already known, the network lookup only has to find a pairing code dialog.
        discover(ctx, if (tls != null && tls > 0) 1200L else 2500L) { connect, pairing ->
            val c = (connect + listOfNotNull(tls?.takeIf { it > 0 })).distinct()
            done(base + mapOf("connect" to c, "pairing" to pairing))
        }
    }

    private fun localAddresses(): Set<InetAddress> = try {
        NetworkInterface.getNetworkInterfaces().toList().flatMap { it.inetAddresses.toList() }.toSet()
    } catch (_: Exception) { emptySet() }

    /**
     * Browses both service types for ~2.5 s and keeps the ones on this device. Always answers
     * within ~5 s: on some devices resolving a service never calls back.
     */
    private fun discover(ctx: Context, browseMs: Long, report: (List<Int>, List<Int>) -> Unit) {
        var answered = false
        val main0 = Handler(Looper.getMainLooper())
        lateinit var connect0: MutableSet<Int>
        lateinit var pairing0: MutableSet<Int>
        fun done(c: List<Int>, p: List<Int>) { if (!answered) { answered = true; report(c, p) } }
        main0.postDelayed({ done(connect0.sorted(), pairing0.sorted()) }, 5000)
        val nsd = ctx.getSystemService(Context.NSD_SERVICE) as NsdManager
        val main = Handler(Looper.getMainLooper())
        val mine = localAddresses()
        val found = mutableListOf<NsdServiceInfo>()
        val connect = mutableSetOf<Int>()
        val pairing = mutableSetOf<Int>()
        connect0 = connect
        pairing0 = pairing
        val listeners = mutableListOf<NsdManager.DiscoveryListener>()
        for (type in listOf(CONNECT, PAIRING)) {
            val l = object : NsdManager.DiscoveryListener {
                override fun onServiceFound(info: NsdServiceInfo) { synchronized(found) { found.add(info) } }
                override fun onServiceLost(info: NsdServiceInfo) {}
                override fun onDiscoveryStarted(t: String) {}
                override fun onDiscoveryStopped(t: String) {}
                override fun onStartDiscoveryFailed(t: String, e: Int) {}
                override fun onStopDiscoveryFailed(t: String, e: Int) {}
            }
            try {
                nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, l)
                listeners.add(l)
            } catch (_: Exception) {}
        }
        main.postDelayed({
            for (l in listeners) try { nsd.stopServiceDiscovery(l) } catch (_: Exception) {}
            val queue = synchronized(found) { ArrayDeque(found) }
            // NsdManager resolves one service at a time.
            fun next() {
                val s = queue.removeFirstOrNull() ?: run { done(connect.sorted(), pairing.sorted()); return }
                try {
                    @Suppress("DEPRECATION")
                    nsd.resolveService(s, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(info: NsdServiceInfo, e: Int) { main.post { next() } }
                        override fun onServiceResolved(info: NsdServiceInfo) {
                            @Suppress("DEPRECATION")
                            val host = info.host
                            if (host != null && (host in mine || host.isLoopbackAddress)) {
                                if (info.serviceType.contains("pairing")) pairing.add(info.port) else connect.add(info.port)
                            }
                            main.post { next() }
                        }
                    })
                } catch (_: Exception) { main.post { next() } }
            }
            next()
        }, browseMs)
    }
}
