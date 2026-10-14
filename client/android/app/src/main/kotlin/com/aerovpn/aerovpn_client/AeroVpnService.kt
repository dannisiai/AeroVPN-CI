package com.aerovpn.aerovpn_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.NetworkCapabilities
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import java.io.BufferedReader
import java.io.InputStreamReader
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.URL
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * AeroVPN Android Native VPN Service
 *
 * Mirrors the current upstream sing-box-for-android (SFA) call sequence while keeping a
 * reflection-based platform adapter plus typed default-network DNS transport:
 * - Libbox.setup(SetupOptions), then CommandServer(handler, platformInterface).start()
 *   and startOrReloadService(content, OverrideOptions()) — same as Application.setupLibbox
 *   + BoxService.startCommandServer.
 * - PlatformInterface implemented via a dynamic Proxy: openTun / autoDetectInterfaceControl
 *   (protect) / getInterfaces / default interface monitor / findConnectionOwner.
 * - TUN interface returned as the raw POSIX fd; the core dups it (upstream OpenInterface).
 * - Real-time Clash API traffic telemetry poller (Bearer <clash_api.secret>).
 * - Foreground service lifecycle management.
 */
class AeroVpnService : VpnService() {

    companion object {
        private const val TAG = "AeroVpnService"
        const val ACTION_START = "com.aerovpn.action.START"
        const val ACTION_STOP = "com.aerovpn.action.STOP"
        const val EXTRA_CONFIG = "config_json"
        const val EXTRA_ASSIGNED_IP = "assigned_ip"
        const val EXTRA_COUNTRY = "country"
        const val EXTRA_CITY = "city"
        const val EXTRA_CLASH_SECRET = "clash_secret"
        const val EXTRA_KILL_SWITCH = "kill_switch"
        const val NOTIFICATION_CHANNEL_ID = "aerovpn_service_channel"
        const val NOTIFICATION_ID = 1001

        @Volatile
        var isRunning = false
            private set

        @Volatile private var isStarting = false
        @Volatile private var stopRequested = false
        @Volatile private var activeService: AeroVpnService? = null
        @Volatile private var cleanupFailed = false
        fun requestStop() {
            // Do not create a Service solely to stop an already idle VPN.
            val service = activeService
            if (service != null) {
                service.queueStop(clearError = true)
            } else if (isStarting) {
                // startForegroundService may not have delivered onCreate yet.
                markStopRequested()
            } else if (!stopRequested) {
                check(!cleanupFailed) { lastError ?: "VPN cleanup failed; restart the app" }
                lastError = null
            }
        }
        fun markStartRequested() { isStarting = true; lastError = null }
        fun markStopRequested() { stopRequested = true }
        fun dispatchFailed(message: String) {
            isStarting = false
            stopRequested = false
            lastError = message
        }

        @Volatile
        var assignedIp: String = ""
            private set

        @Volatile
        var country: String = ""
            private set

        @Volatile
        var city: String = ""
            private set

        @Volatile
        var startTime: Long = 0
            private set

        @Volatile
        var lastError: String? = null
            private set

        @Volatile
        var clashSecret: String = ""
            private set

        @Volatile
        var clashPort: Int = 9090
            private set

        @Volatile
        var systemProxyPort: Int = 0
            private set

        // Truthful core-level kill switch state (strict_route in the generated
        // config). Android has no OS-level VPN lockdown toggle like the Apple
        // platforms; reporting this flag keeps the UI honest about what is active.
        @Volatile
        var killSwitchEnabled: Boolean = false
            private set

        private val downlinkBps = AtomicLong(0)
        private val uplinkBps = AtomicLong(0)
        private val totalDown = AtomicLong(0)
        private val totalUp = AtomicLong(0)
        fun getStatsMap(): Map<String, Any?> {
            val uptime = if (isRunning && startTime > 0) (System.currentTimeMillis() - startTime) / 1000 else 0
            return mapOf(
                "status" to when {
                    stopRequested -> "disconnecting"
                    isStarting -> "connecting"
                    isRunning -> "connected"
                    lastError != null -> "error"
                    else -> "disconnected"
                },
                "assigned_ip" to assignedIp,
                "country" to country,
                "city" to city,
                "uptime_sec" to uptime,
                "kill_switch" to killSwitchEnabled,
                "downlink_bps" to downlinkBps.get(),
                "uplink_bps" to uplinkBps.get(),
                "total_down_bytes" to totalDown.get(),
                "total_up_bytes" to totalUp.get(),
                "last_error" to lastError
            )
        }
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var boxServiceInstance: Any? = null
    private var telemetryThread: Thread? = null
    @Volatile private var defaultInterfaceListener: Any? = null
    @Volatile private var defaultNetworkMonitor: AndroidDefaultNetworkMonitor? = null
    private val localResolver = AndroidLocalResolver {
        defaultNetworkMonitor?.network ?: error("missing physical default network")
    }
    @Volatile
    private var isStopping = false

    // Upstream starts/closes libbox off the main thread. Serialize native work
    // too: Flutter lifecycle serialization does not cover OS revoke callbacks.
    private val lifecycleExecutor = Executors.newSingleThreadExecutor()

    override fun onCreate() {
        super.onCreate()
        activeService = this
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val config = intent.getStringExtra(EXTRA_CONFIG) ?: ""
                markStartRequested()
                startForeground(NOTIFICATION_ID, buildForegroundNotification("Connecting - AeroVPN"))
                lifecycleExecutor.execute {
                    assignedIp = intent.getStringExtra(EXTRA_ASSIGNED_IP) ?: ""
                    country = intent.getStringExtra(EXTRA_COUNTRY) ?: ""
                    city = intent.getStringExtra(EXTRA_CITY) ?: ""
                    clashSecret = intent.getStringExtra(EXTRA_CLASH_SECRET) ?: ""
                    killSwitchEnabled = intent.getBooleanExtra(EXTRA_KILL_SWITCH, false)
                    try {
                        if (stopRequested) stopVpn(clearError = true) else startVpn(config)
                    } finally { isStarting = false }
                }
            }
            ACTION_STOP -> {
                queueStop(clearError = true)
            }
        }
        return START_NOT_STICKY
    }

    private fun queueStop(clearError: Boolean) {
        markStopRequested()
        lifecycleExecutor.execute { stopVpn(clearError) }
    }

    private fun startVpn(configJson: String) {
        lastError = null
        clashPort = parseClashPort(configJson)
        systemProxyPort = parseSystemProxyPort(configJson)

        try {
            if (systemProxyPort > 0 && Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                throw IllegalStateException("Android system proxy mode requires Android 10 or later")
            }
            // Start official sing-box / libbox core matching upstream sing-box-for-android
            startUpstreamLibbox(configJson)

            isRunning = true
            startTime = System.currentTimeMillis()
            startTelemetryPoller()

        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize upstream VPN service: ${e.message}", e)
            lastError = e.message ?: "Failed to start VPN service"
            stopVpn()
        }
    }

    /**
     * Configures the process-wide libbox runtime, mirroring sing-box-for-android
     * `Application.setupLibbox` (GPL-3.0). sing-box >= v1.13 requires Setup before a
     * CommandServer exists, so basePath / workingPath / tempPath and crash-handler
     * options reach the core. Best-effort: returns false for the legacy (< v1.13) or
     * stub AAR that has no SetupOptions class.
     */
    private fun setupLibbox(): Boolean {
        return try {
            val libboxClass = Class.forName("io.nekohasekai.libbox.Libbox")
            val setupOptionsClass = Class.forName("io.nekohasekai.libbox.SetupOptions")
            val options = setupOptionsClass.getDeclaredConstructor().newInstance()
            setAnyField(options, "basePath", filesDir.absolutePath)
            setAnyField(options, "workingPath", (getExternalFilesDir(null) ?: filesDir).absolutePath)
            setAnyField(options, "tempPath", cacheDir.absolutePath)
            setAnyField(options, "logMaxLines", 3000)
            setAnyField(options, "debug", false)
            setAnyField(options, "crashReportSource", "AeroVpnService")
            // Upstream workaround for golang/go#68760.
            setAnyField(options, "fixAndroidStack", (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0 ||
                Build.VERSION.SDK_INT in 24..25 || Build.VERSION.SDK_INT >= 28)
            val setup = libboxClass.methods.firstOrNull { it.name == "setup" && it.parameterTypes.size == 1 }
            if (setup == null) {
                Log.i(TAG, "Libbox.setup absent; skipping (legacy libbox).")
                return false
            }
            setup.invoke(null, options)
            Log.i(TAG, "Libbox setup completed (basePath=${filesDir.absolutePath}).")
            true
        } catch (e: ClassNotFoundException) {
            Log.i(TAG, "Libbox SetupOptions absent (libbox < v1.13 or stub AAR); skipping setup: ${e.message}")
            false
        } catch (e: Exception) {
            throw (e.cause ?: e)
        }
    }

    /** Assigns a gomobile struct field, supporting both generated public fields and setters. */
    private fun setAnyField(target: Any, fieldName: String, value: Any?) {
        val clazz = target.javaClass
        try {
            clazz.getField(fieldName).set(target, value)
            return
        } catch (_: Exception) {}
        val setter = "set" + fieldName.replaceFirstChar { it.uppercaseChar() }
        for (m in clazz.methods) {
            if (m.name == setter && m.parameterTypes.size == 1) {
                try {
                    m.invoke(target, value)
                    return
                } catch (_: Exception) {}
            }
        }
    }

    /** Default value for an unhandled PlatformInterface / handler method return type. */
    private fun defaultValueFor(returnType: Class<*>): Any? = when {
        returnType == Boolean::class.javaPrimitiveType || returnType == Boolean::class.javaObjectType -> false
        returnType == Int::class.javaPrimitiveType || returnType == Int::class.javaObjectType -> 0
        returnType == Long::class.javaPrimitiveType || returnType == Long::class.javaObjectType -> 0L
        returnType == String::class.java -> ""
        else -> null
    }

    /**
     * Reads the first available member from a gomobile object.
     *
     * gomobile exposes Go struct fields as public Java fields (e.g. `StringBox.value`,
     * `RoutePrefix.address`) but Go *methods* as Java methods (`TunOptions.getMTU()`),
     * so a lookup that only probes one of the two silently returns defaults. That made
     * `dns_mode` / address / route readers fall back to hardcoded values.
     */
    private fun readFirstOf(target: Any?, fieldNames: List<String>, methodNames: List<String>): Any? {
        if (target == null) return null
        val clazz = target.javaClass
        for (fieldName in fieldNames) {
            try {
                val field = clazz.getField(fieldName)
                field.isAccessible = true
                return field.get(target)
            } catch (_: Exception) {}
        }
        for (name in methodNames) {
            val method = clazz.methods.firstOrNull { it.name == name && it.parameterTypes.isEmpty() } ?: continue
            try {
                return method.invoke(target)
            } catch (_: Exception) {}
        }
        return null
    }

    /**
     * Handles CommandServerHandler callbacks (sing-box >= v1.13), mirroring
     * sing-box-for-android `BoxService : CommandServerHandler` (GPL-3.0).
     */
    private fun handleCommandServerHandlerCall(method: Method, args: Array<Any?>?): Any? {
        when (method.name) {
            // Upstream BoxService.serviceStop: the CORE asked the service to stop
            // (fatal core error, config rejected, ...). Upstream closes the TUN fd
            // and the command server; here the whole service must tear down.
            // Ignoring this callback left isRunning=true with a dead TUN - the UI
            // kept reporting "connected" while traffic flowed outside the tunnel.
            "serviceStop" -> {
                if (!isStopping) {
                    lastError = "VPN core stopped unexpectedly"
                    lifecycleExecutor.execute { stopVpn(clearError = false) }
                }
                return null
            }
            // No hot-reload path: the control plane hands out a fresh ephemeral
            // config on every connect, so a reload request only ever arrives
            // together with a stop.
            "serviceReload" -> return null
            // Upstream BoxService always returns a SystemProxyStatus object (never null);
            // this client has no system-wide proxy switch, so report unavailable.
            "getSystemProxyStatus" -> return buildSystemProxyStatus()
            "setSystemProxyEnabled", "triggerNativeCrash" -> return null
            "connectSSHAgent" -> return -1
            "writeDebugMessage" -> {
                (args?.get(0) as? String)?.let { Log.d("sing-box", it) }
                return null
            }
            else -> return defaultValueFor(method.returnType)
        }
    }

    /** libbox SystemProxyStatus with available/enabled = false (unsupported feature). */
    private fun buildSystemProxyStatus(): Any? = try {
        val statusClass = Class.forName("io.nekohasekai.libbox.SystemProxyStatus")
        val status = statusClass.getDeclaredConstructor().newInstance()
        setAnyField(status, "available", false)
        setAnyField(status, "enabled", false)
        status
    } catch (_: Exception) {
        null
    }

    /**
     * Initializes upstream sing-box / libbox runtime, mirroring sing-box-for-android
     * `BoxService.startCommandServer` + `startService` (GPL-3.0):
     *   Libbox.setup(SetupOptions) once, then
     *   CommandServer(handler, platformInterface).start()
     *   followed by startOrReloadService(content, OverrideOptions()).
     * libbox < v1.13 (and the hand-crafted stub AAR) exposed Libbox.newService instead;
     * that legacy path is kept only as a guarded fallback.
     * Reflection is used because libbox.aar is produced at build time by gomobile.
     */
    private fun startUpstreamLibbox(configJson: String) {
        try {
            val platformInterfaceClass = Class.forName("io.nekohasekai.libbox.PlatformInterface")
            val libboxClass = Class.forName("io.nekohasekai.libbox.Libbox")

            setupLibbox()

            val platformHandler = InvocationHandler { _, method, args ->
                handlePlatformInterfaceCall(method, args)
            }
            val platformProxy = Proxy.newProxyInstance(
                platformInterfaceClass.classLoader,
                arrayOf(platformInterfaceClass),
                platformHandler
            )

            // Mirrors BoxService.startCommandServer's promote/discard draft calls.
            runCatching { libboxClass.getMethod("promoteOOMDraft").invoke(null) }
            runCatching { libboxClass.getMethod("discardPowerReportDraft").invoke(null) }

            if (startCommandServer(configJson, platformProxy, platformInterfaceClass)) return

            startLegacyNewService(libboxClass, platformInterfaceClass, configJson, platformProxy)
        } catch (e: ClassNotFoundException) {
            Log.e(TAG, "libbox.aar not bundled on classpath: ${e.message}. Core VPN engine is missing.")
            lastError = "Missing libbox.aar: rebuild with core/scripts/build_android_aar.sh (gomobile bind ./experimental/libbox)."
            throw IllegalStateException(lastError, e)
        } catch (e: Exception) {
            val msg = e.cause?.message ?: e.message
            if (msg != null && (msg.contains("native") || msg.contains("UnsatisfiedLink"))) {
                lastError = "Placeholder libbox.aar without native .so: rebuild with core/scripts/build_android_aar.sh."
                throw IllegalStateException(lastError, e)
            }
            Log.e(TAG, "Error invoking upstream Libbox: ${e.message}", e)
            throw e
        }
    }

    /**
     * Current API (sing-box >= v1.13): CommandServer(handler, platformInterface).
     * Returns true when the service was started.
     */
    private fun startCommandServer(configJson: String, platformProxy: Any, platformInterfaceClass: Class<*>): Boolean {
        val commandServerClass = try {
            Class.forName("io.nekohasekai.libbox.CommandServer")
        } catch (_: ClassNotFoundException) {
            Log.i(TAG, "CommandServer absent (libbox < v1.13 or stub AAR); trying legacy newService.")
            return false
        }
        var openedServer: Any? = null
        return try {
            val handlerClass = Class.forName("io.nekohasekai.libbox.CommandServerHandler")
            val handlerHandler = InvocationHandler { _, method, args ->
                handleCommandServerHandlerCall(method, args)
            }
            val handlerProxy = Proxy.newProxyInstance(
                handlerClass.classLoader,
                arrayOf(handlerClass),
                handlerHandler
            )

            // Upstream: CommandServer(this /* handler */, platformInterface), see BoxService.kt.
            val ctor = commandServerClass.constructors.firstOrNull { c ->
                c.parameterTypes.size == 2 &&
                    c.parameterTypes[0].isAssignableFrom(handlerClass) &&
                    c.parameterTypes[1].isAssignableFrom(platformInterfaceClass)
            } ?: commandServerClass.constructors.firstOrNull { it.parameterTypes.size == 2 }
            if (ctor == null) {
                Log.w(TAG, "CommandServer has no (handler, platformInterface) constructor.")
                return false
            }

            val server = ctor.newInstance(handlerProxy, platformProxy)
            openedServer = server
            server.javaClass.getMethod("start").invoke(server)

            val reload = server.javaClass.methods.firstOrNull {
                it.name == "startOrReloadService" && it.parameterTypes.size == 2
            }
            if (reload == null) {
                runCatching { server.javaClass.getMethod("close").invoke(server) }
                Log.w(TAG, "CommandServer.startOrReloadService(String, OverrideOptions) not found.")
                return false
            }
            val overrideClass = Class.forName("io.nekohasekai.libbox.OverrideOptions")
            val overrideOptions = overrideClass.getDeclaredConstructor().newInstance()
            reload.invoke(server, configJson, overrideOptions)

            boxServiceInstance = server
            Log.i(TAG, "Started upstream Libbox via CommandServer API (sing-box >= v1.13).")
            true
        } catch (e: Exception) {
            runCatching { openedServer?.javaClass?.getMethod("closeService")?.invoke(openedServer) }
            runCatching { openedServer?.javaClass?.getMethod("close")?.invoke(openedServer) }
            // This API exists in the pinned AAR. A startup failure is real;
            // falling back to removed newService only hides its diagnostic.
            throw (e.cause ?: e)
        }
    }

    /**
     * Legacy API (sing-box < v1.13): Libbox.newService(config, platformInterface).
     * Removed upstream in v1.13.0; kept only so pre-v1.13 AARs still boot.
     */
    private fun startLegacyNewService(
        libboxClass: Class<*>,
        platformInterfaceClass: Class<*>,
        configJson: String,
        platformProxy: Any,
    ) {
        val newService = try {
            libboxClass.getMethod("newService", String::class.java, platformInterfaceClass)
        } catch (_: NoSuchMethodException) {
            lastError = "libbox.aar exposes neither CommandServer (v1.13+) nor legacy newService. " +
                "Rebuild with core/scripts/build_android_aar.sh (gomobile bind ./experimental/libbox)."
            throw IllegalStateException(lastError)
        }
        val service = newService.invoke(null, configJson, platformProxy)
        service?.javaClass?.getMethod("start")?.invoke(service)
        boxServiceInstance = service
        Log.i(TAG, "Started upstream Libbox via legacy newService API (sing-box < v1.13).")
    }

    /**
     * Handles PlatformInterface method calls routed from the Go runtime. Method names
     * mirror the gomobile Java mapping (first letter lower-cased) of upstream
     * `libbox.PlatformInterface` (experimental/libbox/platform.go). Methods the core
     * only calls for features this client does not expose return neutral defaults.
     */
    private fun handlePlatformInterfaceCall(method: Method, args: Array<Any?>?): Any? {
        when (method.name) {
            "openTun" -> return openTunFromOptions(args?.get(0))
            "autoDetectInterfaceControl", "protect" -> {
                val fd = (args?.get(0) as? Number)?.toInt() ?: 0
                val ok = protect(fd)
                check(ok) { "Cannot protect VPN outbound socket fd=$fd" }
                Log.d(TAG, "${method.name} protect socket fd=$fd success=$ok")
                return if (method.returnType == Boolean::class.javaPrimitiveType || method.returnType == Boolean::class.javaObjectType) ok else null
            }
            "usePlatformAutoDetectInterfaceControl" -> return true
            "getInterfaces" -> return createNetworkInterfaceIterator()
            "startDefaultInterfaceMonitor" -> {
                startDefaultInterfaceMonitor(args?.get(0))
                return null
            }
            "closeDefaultInterfaceMonitor" -> {
                closeDefaultInterfaceMonitor(args?.get(0))
                return null
            }
            "findConnectionOwner" -> return findConnectionOwner(
                (args?.get(0) as? Number)?.toInt() ?: 0,
                args?.get(1) as? String ?: "",
                (args?.get(2) as? Number)?.toInt() ?: 0,
                args?.get(3) as? String ?: "",
                (args?.get(4) as? Number)?.toInt() ?: 0,
            )
            // Android is not under NetworkExtension (iOS-only concept); false per upstream SFA.
            "underNetworkExtension" -> return false
            "includeAllNetworks" -> return false
            "clearDNSCache" -> return null
            "readWIFIState" -> return null
            "sendNotification" -> return null
            "cancelNotification" -> return null
            "useProcFS" -> return Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
            "usePlatformShell" -> return false
            "checkPlatformShell" -> return null
            "openShellSession" -> return null
            "lookupUser" -> return null
            "lookupSFTPServer" -> return ""
            "readSystemSSHHostKey" -> return ""
            "tailscaleHostname" -> return ""
            "usePlatformBridge" -> return false
            "createBridge" -> return null
            "usePlatformAutoRedirect" -> return false
            "createAutoRedirect" -> return null
            "localDNSTransport" -> return localResolver
            "startNeighborMonitor" -> return null
            "closeNeighborMonitor" -> return null
            "registerMyInterface" -> return null
            else -> return defaultValueFor(method.returnType)
        }
    }

    /** Reads a libbox int constant (e.g. InterfaceTypeWIFI) via reflection, with fallback. */
    private fun libboxIntConstant(name: String, fallback: Int): Int = try {
        val clazz = Class.forName("io.nekohasekai.libbox.Libbox")
        (clazz.getField(name).get(null) as? Number)?.toInt() ?: fallback
    } catch (_: Exception) {
        fallback
    }

    /** Reads a libbox string constant (e.g. DNSModeDisabled) via reflection, with fallback. */
    private fun libboxStringConstant(name: String, fallback: String): String = try {
        val clazz = Class.forName("io.nekohasekai.libbox.Libbox")
        (clazz.getField(name).get(null) as? String) ?: fallback
    } catch (_: Exception) {
        fallback
    }

    /** Builds a libbox StringIterator proxy over a list of strings. */
    private fun newStringIterator(values: List<String>): Any? = try {
        val cls = Class.forName("io.nekohasekai.libbox.StringIterator")
        var idx = 0
        val handler = InvocationHandler { _, m, _ ->
            when (m.name) {
                "hasNext" -> idx < values.size
                "next" -> if (idx < values.size) values[idx++] else ""
                "len", "count" -> values.size
                else -> null
            }
        }
        Proxy.newProxyInstance(cls.classLoader, arrayOf(cls), handler)
    } catch (_: Exception) {
        null
    }

    /**
     * Implements upstream `PlatformInterfaceWrapper.getInterfaces` (sing-box-for-android,
     * GPL-3.0): enumerate ConnectivityManager networks and map each to a libbox
     * NetworkInterface carrying name/index/type/mtu/flags/metered, DNS servers,
     * DNS search domains, gateways and address prefixes. The core relies on these
     * fields for interface selection, routing and DNS, so they must not be omitted.
     */
    private fun createNetworkInterfaceIterator(): Any? {
        return try {
            val ifaceIteratorClass = Class.forName("io.nekohasekai.libbox.NetworkInterfaceIterator")
            val ifaceClass = Class.forName("io.nekohasekai.libbox.NetworkInterface")

            val systemInterfaces = try {
                java.net.NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
            } catch (_: Exception) {
                emptyList()
            }

            val typeWifi = libboxIntConstant("InterfaceTypeWIFI", 1)
            val typeCellular = libboxIntConstant("InterfaceTypeCellular", 2)
            val typeEthernet = libboxIntConstant("InterfaceTypeEthernet", 3)
            val typeOther = libboxIntConstant("InterfaceTypeOther", 0)

            val interfaces = mutableListOf<Any>()
            val connectivity = getSystemService(ConnectivityManager::class.java)
            if (connectivity != null) {
                for (network in connectivity.allNetworks) {
                    val linkProperties = connectivity.getLinkProperties(network) ?: continue
                    val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
                    val name = linkProperties.interfaceName ?: continue
                    val sysIf = systemInterfaces.firstOrNull { it.name == name } ?: continue

                    val boxIf = try {
                        ifaceClass.getDeclaredConstructor().newInstance()
                    } catch (_: Exception) {
                        continue
                    }
                    setAnyField(boxIf, "name", name)
                    setAnyField(boxIf, "index", sysIf.index)
                    setAnyField(boxIf, "mtu", runCatching { sysIf.mtu }.getOrDefault(0))
                    setAnyField(boxIf, "dnsServer", newStringIterator(
                        linkProperties.dnsServers.mapNotNull { it.hostAddress }
                    ))
                    setAnyField(boxIf, "dnsSearchDomain", newStringIterator(
                        linkProperties.domains?.split(' ')?.filter { it.isNotEmpty() }.orEmpty()
                    ))
                    setAnyField(boxIf, "gateway", newStringIterator(
                        linkProperties.routes
                            .filter { it.destination.prefixLength == 0 }
                            .mapNotNull { it.gateway }
                            .filterNot { it.isAnyLocalAddress }
                            .mapNotNull { it.hostAddress }
                    ))
                    setAnyField(boxIf, "type", when {
                        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> typeWifi
                        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> typeCellular
                        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> typeEthernet
                        else -> typeOther
                    })
                    setAnyField(boxIf, "addresses", newStringIterator(
                        sysIf.interfaceAddresses.map { "${it.address.hostAddress}/${it.networkPrefixLength}" }
                    ))
                    var flags = 0
                    if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                        // OsConstants.IFF_UP | IFF_RUNNING
                        flags = flags or 0x1 or 0x40
                    }
                    if (sysIf.isLoopback) flags = flags or 0x8       // IFF_LOOPBACK
                    if (sysIf.isPointToPoint) flags = flags or 0x10  // IFF_POINTOPOINT
                    if (runCatching { sysIf.supportsMulticast() }.getOrDefault(false)) flags = flags or 0x1000 // IFF_MULTICAST
                    setAnyField(boxIf, "flags", flags)
                    setAnyField(boxIf, "metered", !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED))
                    interfaces.add(boxIf)
                }
            }

            if (interfaces.isEmpty()) {
                // Degraded fallback: expose up, non-loopback system interfaces by name/index.
                for (sysIf in systemInterfaces) {
                    if (sysIf.isLoopback || !sysIf.isUp) continue
                    val boxIf = try {
                        ifaceClass.getDeclaredConstructor().newInstance()
                    } catch (_: Exception) {
                        continue
                    }
                    setAnyField(boxIf, "name", sysIf.name)
                    setAnyField(boxIf, "index", sysIf.index)
                    interfaces.add(boxIf)
                }
            }

            var currentIndex = 0
            val handler = InvocationHandler { _, method, _ ->
                when (method.name) {
                    "hasNext" -> currentIndex < interfaces.size
                    "next" -> if (currentIndex < interfaces.size) interfaces[currentIndex++] else null
                    "len", "count" -> interfaces.size
                    else -> null
                }
            }
            Proxy.newProxyInstance(ifaceIteratorClass.classLoader, arrayOf(ifaceIteratorClass), handler)
        } catch (e: Exception) {
            Log.w(TAG, "Failed creating NetworkInterfaceIterator: ${e.message}")
            null
        }
    }

    private fun startDefaultInterfaceMonitor(listener: Any?) {
        defaultInterfaceListener = listener
        if (defaultNetworkMonitor == null) {
            val monitor = AndroidDefaultNetworkMonitor(this) { notifyDefaultInterface() }
            defaultNetworkMonitor = monitor
            try {
                monitor.start()
            } catch (error: Exception) {
                defaultNetworkMonitor = null
                throw error
            }
        }
        notifyDefaultInterface()
    }

    private fun closeDefaultInterfaceMonitor(listener: Any?) {
        defaultInterfaceListener = null
        defaultNetworkMonitor?.close()
        defaultNetworkMonitor = null
    }
    private fun notifyDefaultInterface() {
        val listener = defaultInterfaceListener ?: return
        try {
            val cm = getSystemService(ConnectivityManager::class.java)
            val active = defaultNetworkMonitor?.network
            var name: String? = null
            var index = -1
            if (active != null) {
                // LinkProperties/interface index can lag onAvailable. Upstream
                // retries this for up to one second on its network worker.
                for (attempt in 0 until 10) {
                    val candidate = cm?.getLinkProperties(active)?.interfaceName
                    val candidateIndex = try {
                        candidate?.let { java.net.NetworkInterface.getByName(it)?.index } ?: -1
                    } catch (_: Exception) { -1 }
                    if (!candidate.isNullOrEmpty() && candidateIndex > 0) {
                        name = candidate
                        index = candidateIndex
                        break
                    }
                    Thread.sleep(100)
                }
            }
            if (defaultInterfaceListener !== listener || defaultNetworkMonitor?.network != active) return
            val capabilities = active?.let { cm?.getNetworkCapabilities(it) }
            setUnderlyingNetworks(active?.let { arrayOf(it) })
            val update = listener.javaClass.methods.firstOrNull {
                it.name == "updateDefaultInterface" && it.parameterTypes.size == 4
            }
            if (update != null) {
                if (name.isNullOrEmpty() || index == -1) {
                    update.invoke(listener, "", -1, false, false)
                } else {
                    val expensive = capabilities?.hasCapability(
                        NetworkCapabilities.NET_CAPABILITY_NOT_METERED
                    )?.not() ?: false
                    val constrained = Build.VERSION.SDK_INT >= 28 &&
                        capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_CONGESTED) == false
                    update.invoke(listener, name, index, expensive, constrained)
                }
            }

            val updatePath = listener.javaClass.methods.firstOrNull {
                it.name == "updateNetworkPath" && it.parameterTypes.size == 1
            }
            updatePath?.invoke(
                listener,
                if (name.isNullOrEmpty()) "unsatisfied" else "satisfied interfaces=$name#$index"
            )
        } catch (e: Exception) {
            Log.d(TAG, "notifyDefaultInterface failed: ${e.message}")
        }
    }

    private fun findConnectionOwner(protocol: Int, sAddr: String, sPort: Int, dAddr: String, dPort: Int): Any? {
        // Directly reused from upstream SFA PlatformInterfaceWrapper.findConnectionOwner (GPL-3.0):
        // must also populate androidPackageNames, otherwise per-app routing/owner lookup is incomplete.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val cm = getSystemService(ConnectivityManager::class.java) ?: return null
                val uid = cm.getConnectionOwnerUid(
                    protocol,
                    InetSocketAddress(sAddr, sPort),
                    InetSocketAddress(dAddr, dPort)
                )
                if (uid == android.os.Process.INVALID_UID) return null

                val ownerClass = Class.forName("io.nekohasekai.libbox.ConnectionOwner")
                val owner = try {
                    ownerClass.getDeclaredConstructor().newInstance()
                } catch (_: Exception) {
                    Proxy.newProxyInstance(ownerClass.classLoader, arrayOf(ownerClass)) { _, m, _ ->
                        when (m.name) {
                            "getUserId" -> uid
                            else -> null
                        }
                    }
                }
                try {
                    owner.javaClass.getMethod("setUserId", Int::class.javaPrimitiveType).invoke(owner, uid)
                } catch (_: Exception) {}
                val packages = try {
                    packageManager.getPackagesForUid(uid)?.toList() ?: emptyList()
                } catch (_: Exception) {
                    emptyList<String>()
                }
                val pkgName = packages.firstOrNull() ?: ""
                try {
                    owner.javaClass.getMethod("setUserName", String::class.java).invoke(owner, pkgName)
                } catch (_: Exception) {}
                try {
                    // Upstream SFA: owner.setAndroidPackageNames(StringArray(...))
                    val stringIterClass = Class.forName("io.nekohasekai.libbox.StringIterator")
                    var idx = 0
                    val handler = java.lang.reflect.InvocationHandler { _, method, _ ->
                        when (method.name) {
                            "hasNext" -> idx < packages.size
                            "next" -> if (idx < packages.size) packages[idx++] else ""
                            "len" -> packages.size
                            else -> null
                        }
                    }
                    val stringArray = Proxy.newProxyInstance(stringIterClass.classLoader, arrayOf(stringIterClass), handler)
                    val setterNames = listOf("setAndroidPackageNames", "setAndroidPackageName")
                    for (name in setterNames) {
                        try {
                            val m = owner.javaClass.methods.firstOrNull { it.name == name && it.parameterTypes.size == 1 }
                            if (m != null) {
                                m.invoke(owner, stringArray)
                                break
                            }
                        } catch (_: Exception) {}
                    }
                } catch (_: Exception) {}
                return owner
            } catch (e: Exception) {
                Log.d(TAG, "findConnectionOwner failed: ${e.message}")
            }
        }
        return null
    }

    /**
     * Implements upstream openTun, directly reused from SagerNet/sing-box-for-android
     * app/src/main/java/io/nekohasekai/sfa/bg/VPNService.kt (GPL-3.0):
     * - session/mtu/metered/allowBypass
     * - inet4Address/inet6Address via address()/prefix()
     * - DNS only when autoRoute and dnsMode != disabled, via dnsServerAddress
     * - TIRAMISU+: inet4RouteAddress/inet6RouteAddress + excludeRoute, else inet4RouteRange/inet6RouteRange
     * - includePackage/excludePackage via addAllowed/DisallowedApplication
     * Reflection is used here because libbox.aar is provided at build time via gomobile;
     * method names mirror the gomobile-generated TunOptions API 1:1.
     */
    private fun openTunFromOptions(options: Any?): Int {
        val builder = Builder()
            .setSession("AeroVPN")

        if (systemProxyPort in 1024..65535) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                throw IllegalStateException("Android system proxy mode requires Android 10 or later")
            }
            builder.setHttpProxy(ProxyInfo.buildDirectProxy("127.0.0.1", systemProxyPort))
        }

        var mtu = 1500
        var autoRoute = true
        if (options != null) {
            val mtuValue = readFirstOf(options, listOf("mtu"), listOf("getMTU", "getMtu", "mtu")) as? Number
            mtu = mtuValue?.toInt() ?: 1500
            val autoRouteValue = readFirstOf(options, listOf("autoRoute"), listOf("getAutoRoute", "autoRoute")) as? Boolean
            autoRoute = autoRouteValue ?: true
        }
        builder.setMtu(mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        fun readPrefixIterator(methodNames: List<String>): MutableList<Pair<String, Int>> {
            val out = mutableListOf<Pair<String, Int>>()
            if (options == null) return out
            try {
                val m = options.javaClass.methods.firstOrNull { it.name in methodNames } ?: return out
                val iterator = m.invoke(options) ?: return out
                val hasNextMethod = iterator.javaClass.getMethod("hasNext")
                val nextMethod = iterator.javaClass.getMethod("next")
                while (hasNextMethod.invoke(iterator) as Boolean) {
                    val item = nextMethod.invoke(iterator)
                    when (item) {
                        is String -> {
                            if (item.contains("/")) {
                                val parts = item.split("/")
                                out.add(parts[0] to (parts.getOrNull(1)?.toIntOrNull() ?: 32))
                            } else {
                                out.add(item to 32)
                            }
                        }
                        else -> if (item != null) {
                            // RoutePrefix exposes address()/prefix() methods in the gomobile
                            // Java binding, not public fields; tolerate either shape.
                            val addr = readFirstOf(item, listOf("address"), listOf("address", "getAddress")) as? String
                            val prefix = (readFirstOf(item, listOf("prefix"), listOf("prefix", "getPrefix")) as? Number)?.toInt()
                            if (addr != null && prefix != null) {
                                out.add(addr to prefix)
                            }
                        }
                    }
                }
            } catch (_: Exception) {}
            return out
        }

        fun readStringIterator(methodNames: List<String>): MutableList<String> {
            val out = mutableListOf<String>()
            if (options == null) return out
            try {
                val m = options.javaClass.methods.firstOrNull { it.name in methodNames } ?: return out
                val iterator = m.invoke(options) ?: return out
                val hasNextMethod = iterator.javaClass.getMethod("hasNext")
                val nextMethod = iterator.javaClass.getMethod("next")
                while (hasNextMethod.invoke(iterator) as Boolean) {
                    val s = nextMethod.invoke(iterator) as? String
                    if (!s.isNullOrEmpty()) out.add(s)
                }
            } catch (_: Exception) {}
            return out
        }

        // Addresses (upstream: inet4Address + inet6Address). The address
        // families are tracked separately: the IPv6 default route fallback
        // below (upstream SFA parity) may only be used when a v6 address is
        // actually present on the TUN, otherwise establish() fails.
        var addedV4Address = false
        var addedV6Address = false
        for ((addr, prefix) in readPrefixIterator(listOf("getInet4Address", "inet4Address"))) {
            try {
                builder.addAddress(addr, prefix)
                addedV4Address = true
            } catch (_: Exception) {}
        }
        for ((addr, prefix) in readPrefixIterator(listOf("getInet6Address", "inet6Address"))) {
            try {
                builder.addAddress(addr, prefix)
                addedV6Address = true
            } catch (_: Exception) {}
        }
        if (!addedV4Address) {
            builder.addAddress("172.19.0.1", 30)
        }
        // Fail-closed IPv6: the generated config provisions a dual-stack TUN,
        // so the core normally supplies the v6 address itself. If it could not
        // be read, add the upstream example ULA so the v6 default route below
        // is still valid and IPv6 traffic cannot bypass the tunnel.
        if (!addedV6Address && autoRoute) {
            try {
                builder.addAddress("fdfe:dcba:9876::1", 126)
                addedV6Address = true
            } catch (_: Exception) {}
        }

        if (autoRoute) {
            // DNS (upstream: only when autoRoute and dnsMode != disabled).
            // `TunOptions.getDNSMode()` returns a StringBox whose `value` is a public
            // gomobile field, and the disabled marker is the *string* "disabled"
            // (sing-tun DNSModeDisabled), not an integer - so compare strings and use
            // the core's own constant when it is reachable.
            val dnsMode = readFirstOf(
                options,
                listOf("dnsMode"),
                listOf("getDNSMode", "getDnsMode", "dnsMode"),
            )
            val dnsModeValue = readFirstOf(
                dnsMode,
                listOf("value", "Value"),
                listOf("value", "getValue"),
            )?.toString()
            val dnsModeDisabledMarker = libboxStringConstant("DNSModeDisabled", "disabled")
            val dnsModeDisabled = dnsModeValue != null && dnsModeValue == dnsModeDisabledMarker
            if (!dnsModeDisabled) {
                var addedDns = false
                for (dns in readStringIterator(listOf("getDNSServerAddress", "dnsServerAddress"))) {
                    try {
                        builder.addDnsServer(dns)
                        addedDns = true
                    } catch (_: Exception) {}
                }
                if (!addedDns) {
                    builder.addDnsServer("1.1.1.1")
                }
            }

            // Routes (upstream: TIRAMISU+ uses RouteAddress+Exclude, else RouteRange)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val v4 = readPrefixIterator(listOf("getInet4RouteAddress", "inet4RouteAddress"))
                val v6 = readPrefixIterator(listOf("getInet6RouteAddress", "inet6RouteAddress"))
                if (v4.isNotEmpty()) {
                    for ((addr, prefix) in v4) {
                        try { builder.addRoute(addr, prefix) } catch (_: Exception) {}
                    }
                } else if (addedV4Address) {
                    try { builder.addRoute("0.0.0.0", 0) } catch (_: Exception) {}
                } else {
                    builder.addRoute("0.0.0.0", 0)
                }
                if (v6.isNotEmpty()) {
                    for ((addr, prefix) in v6) {
                        try { builder.addRoute(addr, prefix) } catch (_: Exception) {}
                    }
                } else if (addedV6Address) {
                    // Upstream SFA: v6 addresses without an explicit v6 route
                    // list default to the v6 default route (IPv6 leak guard).
                    try { builder.addRoute("::", 0) } catch (_: Exception) {}
                }
                for ((addr, prefix) in readPrefixIterator(listOf("getInet4RouteExcludeAddress", "inet4RouteExcludeAddress"))) {
                    try { builder.excludeRoute(IpPrefix(java.net.InetAddress.getByName(addr), prefix)) } catch (_: Exception) {}
                }
                for ((addr, prefix) in readPrefixIterator(listOf("getInet6RouteExcludeAddress", "inet6RouteExcludeAddress"))) {
                    try { builder.excludeRoute(IpPrefix(java.net.InetAddress.getByName(addr), prefix)) } catch (_: Exception) {}
                }
            } else {
                val v4r = readPrefixIterator(listOf("getInet4RouteRange", "inet4RouteRange", "getInet4RouteAddress", "inet4RouteAddress"))
                val v6r = readPrefixIterator(listOf("getInet6RouteRange", "inet6RouteRange", "getInet6RouteAddress", "inet6RouteAddress"))
                if (v4r.isNotEmpty()) {
                    for ((addr, prefix) in v4r) {
                        try { builder.addRoute(addr, prefix) } catch (_: Exception) {}
                    }
                } else {
                    builder.addRoute("0.0.0.0", 0)
                }
                for ((addr, prefix) in v6r) {
                    try { builder.addRoute(addr, prefix) } catch (_: Exception) {}
                }
                if (v6r.isEmpty() && addedV6Address) {
                    // IPv6 leak guard, pre-Tiramisu variant (upstream SFA parity).
                    try { builder.addRoute("::", 0) } catch (_: Exception) {}
                }
            }

            // Per-app packages (upstream: includePackage/excludePackage)
            for (pkg in readStringIterator(listOf("getIncludePackage", "includePackage"))) {
                try { builder.addAllowedApplication(pkg) } catch (_: Exception) {
                    Log.w(TAG, "addAllowedApplication failed for $pkg")
                }
            }
            for (pkg in readStringIterator(listOf("getExcludePackage", "excludePackage"))) {
                try { builder.addDisallowedApplication(pkg) } catch (_: Exception) {
                    Log.w(TAG, "addDisallowedApplication failed for $pkg")
                }
            }
        } else {
            builder.addRoute("0.0.0.0", 0)
        }

        val pfd = builder.establish() ?: throw IllegalStateException("Android VpnService.Builder.establish() returned null")
        // Upstream SFA keeps ParcelFileDescriptor open in service.fileDescriptor and returns pfd.fd
        // (Go runtime dups the fd in platformInterfaceWrapper.OpenInterface). Do not detach here,
        // otherwise later vpnInterface.close() becomes a no-op and stopVpn leaks the TUN.
        vpnInterface = pfd
        val fd = pfd.fd
        Log.i(TAG, "openTun successfully established TUN interface. Native fd=$fd")
        return fd
    }

    private fun parseClashPort(configJson: String): Int {
        try {
            val json = org.json.JSONObject(configJson)
            val experimental = json.optJSONObject("experimental") ?: return 9090
            val clashApi = experimental.optJSONObject("clash_api") ?: return 9090
            val controller = clashApi.optString("external_controller", "")
            val parts = controller.split(":")
            if (parts.size == 2) {
                val p = parts[1].toIntOrNull() ?: 9090
                if (p in 1024..65535) return p
            }
        } catch (_: Exception) {}
        return 9090
    }

    private fun parseSystemProxyPort(configJson: String): Int {
        try {
            val json = org.json.JSONObject(configJson)
            val inbounds = json.optJSONArray("inbounds") ?: return 0
            for (index in 0 until inbounds.length()) {
                val inbound = inbounds.optJSONObject(index) ?: continue
                if (inbound.optString("type") == "mixed" &&
                    inbound.optString("tag") == "mixed-in" &&
                    inbound.optString("listen") == "127.0.0.1") {
                    val port = inbound.optInt("listen_port", 0)
                    if (port in 1024..65535) return port
                }
            }
        } catch (_: Exception) {}
        return 0
    }

    private fun startTelemetryPoller() {
        isStopping = false
        val secret = clashSecret
        val port = clashPort
        telemetryThread = thread(start = true, isDaemon = true, name = "AeroVpnTelemetry") {
            while (!isStopping && isRunning) {
                try {
                    val url = URL("http://127.0.0.1:$port/traffic")
                    val conn = url.openConnection() as HttpURLConnection
                    conn.connectTimeout = 1500
                    conn.readTimeout = 2500
                    conn.requestMethod = "GET"
                    // Upstream clash_api auth: required when config sets a secret.
                    if (secret.isNotEmpty()) {
                        conn.setRequestProperty("Authorization", "Bearer $secret")
                    }

                    if (conn.responseCode == 200) {
                        BufferedReader(InputStreamReader(conn.inputStream)).use { reader ->
                            while (!isStopping && isRunning) {
                                val line = reader.readLine() ?: break
                                val upMatch = Regex("\"up\":\\s*(\\d+)").find(line)
                                val downMatch = Regex("\"down\":\\s*(\\d+)").find(line)
                                if (upMatch != null && downMatch != null) {
                                    val up = upMatch.groupValues[1].toLong()
                                    val down = downMatch.groupValues[1].toLong()
                                    uplinkBps.set(up)
                                    downlinkBps.set(down)
                                    totalUp.addAndGet(up)
                                    totalDown.addAndGet(down)
                                }
                            }
                        }
                    }
                } catch (_: Exception) {}
                try {
                    Thread.sleep(1000)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }
    }

    private fun stopVpn(clearError: Boolean = false) {
        markStopRequested()
        isStopping = true
        telemetryThread?.interrupt()
        telemetryThread = null
        closeDefaultInterfaceMonitor(null)

        val failures = mutableListOf<Throwable>()
        fun closeResource(action: () -> Unit) {
            try { action() } catch (error: Exception) { failures.add(error.cause ?: error) }
        }
        val server = boxServiceInstance
        if (server != null) {
            // Attempt both operations, even when stopping the core fails.
            closeResource { server.javaClass.getMethod("closeService").invoke(server) }
            closeResource {
                server.javaClass.getMethod("close").invoke(server)
                boxServiceInstance = null
            }
        }
        closeResource {
            vpnInterface?.close()
            vpnInterface = null
        }
        cleanupFailed = failures.isNotEmpty()
        if (cleanupFailed) {
            lastError = "VPN cleanup failed: " + failures.joinToString("; ") { it.message.orEmpty() }
            Log.e(TAG, lastError ?: "VPN cleanup failed")
        }
        isRunning = false
        startTime = 0
        downlinkBps.set(0)
        uplinkBps.set(0)
        // A failure surfaced through lastError must survive this cleanup (the UI
        // shows it); only an explicit user-driven stop clears it.
        if (clearError && !cleanupFailed) {
            lastError = null
        }

        // Upstream SFA (ServiceNotification.close) routes this through ServiceCompat:
        // the stopForeground(int) overload only exists on API 29+, so calling it
        // directly would NoSuchMethodError on API 21-28 devices when disconnecting.
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        // Preserve startup/core errors until an explicit user stop or retry.
        activeService = null
        lifecycleExecutor.execute {
            try { stopVpn(clearError = false) } finally {
                isStarting = false
                // Only report settled stop after the old Service is destroyed.
                // A quick reconnect must not race stopSelf()/onDestroy().
                stopRequested = false
            }
        }
        lifecycleExecutor.shutdown()
        super.onDestroy()
    }

    /**
     * The system calls this when the VPN profile is revoked (user revoked consent, or
     * another VPN app took over). Upstream `VPNService` routes it to `BoxService.onRevoke()`
     * -> `stopService()`; without it the libbox core keeps running against a dead tun fd.
     */
    override fun onRevoke() {
        Log.i(TAG, "VPN permission revoked; stopping the tunnel")
        queueStop(clearError = true)
        super.onRevoke()
    }

    fun protectSocket(socketFd: Int): Boolean {
        return protect(socketFd)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "AeroVPN Connection Status",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows live connection state of the VPN tunnel"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun buildForegroundNotification(contentText: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("AeroVPN Network")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }
}
