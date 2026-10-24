// SPDX-License-Identifier: GPL-3.0-or-later
// Android VpnService + sing-box(libbox) 平台接口。
// 部分实现参考 sing-box-for-android（SFA，GPL-3.0-or-later，© nekohasekai）的 VPNService.kt / PlatformInterfaceWrapper.kt。
package dev.proxypilot.proxypilot_mobile.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.OsConstants
import dev.proxypilot.proxypilot_mobile.R
import io.nekohasekai.libbox.BridgeOptions
import io.nekohasekai.libbox.BridgeSession
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.NeighborUpdateListener
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.OutboundGroupItemIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.PlatformUser
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.ShellSession
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.io.File
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.InterfaceAddress
import java.util.concurrent.Executors
import io.nekohasekai.libbox.NetworkInterface as BoxInterface

class ProxyVpnService : VpnService(), PlatformInterface, CommandServerHandler {
    companion object {
        const val ACTION_START = "dev.proxypilot.START"
        const val ACTION_STOP = "dev.proxypilot.STOP"
        const val EXTRA_NAME = "name"
        private const val CHANNEL = "vpn"
        private const val NOTIFY_ID = 1

        fun configFile(ctx: Context) = File(ctx.filesDir, "running-config.json")
    }

    private val worker = Executors.newSingleThreadExecutor()
    private var commandServer: CommandServer? = null
    private var statusClient: CommandClient? = null
    private var tunFd: ParcelFileDescriptor? = null
    private var profileName = ""
    @Volatile private var stopping = false

    private val connectivity by lazy { getSystemService(ConnectivityManager::class.java) }

    // ---------------- 生命周期 ----------------

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> worker.execute { stopCore(null) }
            ACTION_START -> {
                profileName = intent.getStringExtra(EXTRA_NAME) ?: "WQ's Proxy VPN"
                startForegroundCompat("正在连接：$profileName")
                worker.execute { startCore() }
            }
            else -> {
                // 系统重启服务（或“始终开启 VPN”）但没有我们的启动参数：不自行运行旧配置，直接停止。
                if (VpnHub.state != VpnHub.State.STARTED && VpnHub.state != VpnHub.State.STARTING) {
                    stopSelf()
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun startCore() {
        if (commandServer != null) {
            VpnHub.log("startCore ignored: already running")
            return
        }
        stopping = false
        VpnHub.setState(VpnHub.State.STARTING)
        try {
            if (prepare(this) != null) throw IllegalStateException("缺少 VPN 授权")
            val config = configFile(this).readText()
            VpnHub.ensureSetup(this)
            val server = CommandServer(this, this)
            server.start()
            commandServer = server
            startNetworkMonitor()
            server.startOrReloadService(config, OverrideOptions())
            startStatusClient()
            VpnHub.setState(VpnHub.State.STARTED)
            updateNotification("已连接：$profileName")
        } catch (e: Throwable) {
            VpnHub.log("start failed: ${e.message}")
            stopCore("启动失败：${e.message ?: e.javaClass.simpleName}")
        }
    }

    /** 停止核心并释放所有资源。[error] 非空时以错误状态结束。 */
    @Synchronized
    private fun stopCore(error: String?) {
        if (stopping && error == null) return
        stopping = true
        if (VpnHub.state == VpnHub.State.STARTED) VpnHub.setState(VpnHub.State.STOPPING)
        runCatching { statusClient?.disconnect() }
        statusClient = null
        commandServer?.let { s ->
            runCatching { s.closeService() }.onFailure { VpnHub.log("closeService: ${it.message}") }
            runCatching { s.close() }
        }
        commandServer = null
        runCatching { tunFd?.close() }
        tunFd = null
        stopNetworkMonitor()
        if (error != null) VpnHub.setState(VpnHub.State.ERROR, error) else VpnHub.setState(VpnHub.State.STOPPED)
        runCatching { configFile(this).delete() } // 运行配置含凭据，停止后立即删除
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE) else @Suppress("DEPRECATION") stopForeground(true)
        stopSelf()
    }

    override fun onRevoke() {
        worker.execute { stopCore("VPN 授权已被系统或其他 VPN 应用撤销") }
    }

    override fun onDestroy() {
        if (commandServer != null) stopCore("服务被系统销毁")
        worker.shutdown()
        super.onDestroy()
    }

    // ---------------- 流量统计（sing-box 内核真实计数） ----------------

    private fun startStatusClient() {
        val opts = CommandClientOptions().apply {
            addCommand(Libbox.CommandStatus)
            addCommand(Libbox.CommandLog)
            statusInterval = 500L * 1000 * 1000 // 500 ms，单位纳秒
        }
        val client = CommandClient(object : CommandClientHandler {
            override fun connected() {}
            override fun disconnected(message: String?) {
                VpnHub.log("status client disconnected: $message")
                if (!stopping && commandServer != null) {
                    worker.execute { stopCore("核心异常退出${if (!message.isNullOrEmpty()) "：$message" else ""}") }
                }
            }
            override fun writeStatus(message: StatusMessage) {
                if (message.trafficAvailable) VpnHub.traffic(message.downlinkTotal, message.uplinkTotal)
            }
            override fun writeLogs(messageList: LogIterator?) {
                if (messageList == null) return
                while (messageList.hasNext()) VpnHub.log("core: " + messageList.next().message)
            }
            override fun clearLogs() {}
            override fun initializeClashMode(modeList: StringIterator?, currentMode: String?) {}
            override fun setDefaultLogLevel(level: Int) {}
            override fun updateClashMode(newMode: String?) {}
            override fun writeConnectionEvents(events: ConnectionEvents?) {}
            override fun writeGroups(message: OutboundGroupIterator?) {}
            override fun writeOutbounds(message: OutboundGroupItemIterator?) {}
        }, opts)
        client.connect()
        statusClient = client
    }

    // ---------------- 通知 ----------------

    private fun buildNotification(text: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "VPN 状态", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(this, 0, packageManager.getLaunchIntentForPackage(packageName), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, ProxyVpnService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "断开", stop).build())
            .build()
    }

    private fun startForegroundCompat(text: String) {
        val n = buildNotification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFY_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFY_ID, n)
        }
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFY_ID, buildNotification(text))
    }

    // ---------------- 默认网络监控（Wi-Fi / 移动网切换） ----------------

    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var defaultNetwork: Network? = null
    @Volatile private var interfaceListener: InterfaceUpdateListener? = null

    private fun startNetworkMonitor() {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = onNetwork(network)
            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) = onNetwork(network)
            override fun onLost(network: Network) {
                if (network == defaultNetwork) {
                    defaultNetwork = null
                    VpnHub.log("default network lost")
                    interfaceListener?.updateDefaultInterface("", -1, false, false)
                }
            }
        }
        networkCallback = cb
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            connectivity.requestNetwork(request, cb)
        } else {
            connectivity.registerNetworkCallback(request, cb)
        }
    }

    private fun onNetwork(network: Network) {
        defaultNetwork = network
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) setUnderlyingNetworks(arrayOf(network))
        notifyInterface()
    }

    private fun notifyInterface() {
        val l = interfaceListener ?: return
        val n = defaultNetwork ?: return
        val name = connectivity.getLinkProperties(n)?.interfaceName ?: return
        val index = runCatching { java.net.NetworkInterface.getByName(name).index }.getOrDefault(-1)
        val caps = connectivity.getNetworkCapabilities(n)
        val expensive = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
        VpnHub.log("default interface: $name ($index)")
        l.updateDefaultInterface(name, index, expensive, false)
    }

    private fun stopNetworkMonitor() {
        networkCallback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        networkCallback = null
        defaultNetwork = null
    }

    // ---------------- PlatformInterface ----------------

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true
    override fun autoDetectInterfaceControl(fd: Int) {
        if (!protect(fd)) throw IllegalStateException("protect fd failed")
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) throw IllegalStateException("缺少 VPN 授权")
        val builder = Builder().setSession(getString(R.string.app_name)).setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
        val a4 = options.inet4Address
        while (a4.hasNext()) a4.next().let { builder.addAddress(it.address(), it.prefix()) }
        val a6 = options.inet6Address
        while (a6.hasNext()) a6.next().let { builder.addAddress(it.address(), it.prefix()) }
        if (options.autoRoute) {
            val dns = options.dnsServerAddress
            while (dns.hasNext()) builder.addDnsServer(dns.next())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                addRoutes(builder, options.inet4RouteAddress, options.inet4Address.hasNext(), "0.0.0.0")
                addRoutes(builder, options.inet6RouteAddress, options.inet6Address.hasNext(), "::")
                val ex4 = options.inet4RouteExcludeAddress
                while (ex4.hasNext()) builder.excludeRoute(ex4.next().toIpPrefix())
                val ex6 = options.inet6RouteExcludeAddress
                while (ex6.hasNext()) builder.excludeRoute(ex6.next().toIpPrefix())
            } else {
                val r4 = options.inet4RouteRange
                while (r4.hasNext()) r4.next().let { builder.addRoute(it.address(), it.prefix()) }
                val r6 = options.inet6RouteRange
                while (r6.hasNext()) r6.next().let { builder.addRoute(it.address(), it.prefix()) }
            }
            val inc = options.includePackage
            while (inc.hasNext()) runCatching { builder.addAllowedApplication(inc.next()) }
            val exc = options.excludePackage
            while (exc.hasNext()) runCatching { builder.addDisallowedApplication(exc.next()) }
        }
        defaultNetwork?.let { if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) builder.setUnderlyingNetworks(arrayOf(it)) }
        val pfd = builder.establish() ?: throw IllegalStateException("无法建立 VPN 接口（应用未授权或已被撤销）")
        tunFd = pfd
        return pfd.fd
    }

    private fun addRoutes(builder: Builder, routes: io.nekohasekai.libbox.RoutePrefixIterator, hasAddress: Boolean, any: String) {
        if (routes.hasNext()) {
            while (routes.hasNext()) builder.addRoute(routes.next().toIpPrefix())
        } else if (hasAddress) {
            builder.addRoute(any, 0)
        }
    }

    private fun RoutePrefix.toIpPrefix(): IpPrefix =
        IpPrefix(java.net.InetAddress.getByName(address()), prefix())

    override fun findConnectionOwner(ipProtocol: Int, sourceAddress: String, sourcePort: Int, destinationAddress: String, destinationPort: Int): ConnectionOwner {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) throw UnsupportedOperationException("需要 Android 10+")
        val uid = connectivity.getConnectionOwnerUid(ipProtocol, InetSocketAddress(sourceAddress, sourcePort), InetSocketAddress(destinationAddress, destinationPort))
        if (uid == Process.INVALID_UID) throw IllegalStateException("connection owner not found")
        val owner = ConnectionOwner()
        owner.userId = uid
        val pkgs = packageManager.getPackagesForUid(uid)
        owner.userName = pkgs?.firstOrNull() ?: ""
        owner.setAndroidPackageNames(StringArray((pkgs?.toList() ?: emptyList()).iterator()))
        return owner
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        interfaceListener = listener
        notifyInterface()
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        interfaceListener = null
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val javaIfs = java.net.NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        val out = mutableListOf<BoxInterface>()
        @Suppress("DEPRECATION")
        for (network in connectivity.allNetworks) {
            val lp = connectivity.getLinkProperties(network) ?: continue
            val caps = connectivity.getNetworkCapabilities(network) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            val ji = javaIfs.find { it.name == lp.interfaceName } ?: continue
            val bi = BoxInterface()
            bi.name = lp.interfaceName
            bi.index = ji.index
            runCatching { bi.mtu = ji.mtu }
            bi.dnsServer = StringArray(lp.dnsServers.mapNotNull { it.hostAddress }.iterator())
            bi.gateway = StringArray(lp.routes.filter { it.destination.prefixLength == 0 }.mapNotNull { it.gateway }.filterNot { it.isAnyLocalAddress }.mapNotNull { it.hostAddress }.iterator())
            bi.type = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                else -> Libbox.InterfaceTypeOther
            }
            bi.addresses = StringArray(ji.interfaceAddresses.map { it.toPrefix() }.iterator())
            var f = 0
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) f = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
            if (ji.isLoopback) f = f or OsConstants.IFF_LOOPBACK
            if (ji.isPointToPoint) f = f or OsConstants.IFF_POINTOPOINT
            if (ji.supportsMulticast()) f = f or OsConstants.IFF_MULTICAST
            bi.flags = f
            bi.metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            out.add(bi)
        }
        val it = out.iterator()
        return object : NetworkInterfaceIterator {
            override fun hasNext() = it.hasNext()
            override fun next() = it.next()
        }
    }

    private fun InterfaceAddress.toPrefix(): String =
        if (address is Inet6Address) "${Inet6Address.getByAddress(address.address).hostAddress}/$networkPrefixLength"
        else "${address.hostAddress}/$networkPrefixLength"

    override fun underNetworkExtension() = false
    override fun includeAllNetworks() = false
    override fun clearDNSCache() {}
    override fun readWIFIState(): WIFIState? = null // 未申请位置权限，不读取 SSID
    override fun localDNSTransport(): LocalDNSTransport? = null // 使用配置中的显式 DNS 服务器
    override fun registerMyInterface(name: String?) {}
    override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {
        VpnHub.log("core notification: ${notification.title}")
    }
    override fun cancelNotification(identifier: String?, typeID: Int) {}
    override fun useProcFS() = false
    override fun usePlatformShell() = false
    override fun checkPlatformShell() = throw UnsupportedOperationException("不支持")
    override fun openShellSession(user: PlatformUser?, command: String?, environ: StringIterator?, term: String?, rows: Int, cols: Int): ShellSession =
        throw UnsupportedOperationException("不支持")
    override fun lookupUser(username: String?): PlatformUser = throw UnsupportedOperationException("不支持")
    override fun readSystemSSHHostKey(): String = throw UnsupportedOperationException("不支持")
    override fun lookupSFTPServer(): String = throw UnsupportedOperationException("不支持")
    override fun tailscaleHostname(): String = "${Build.MANUFACTURER} ${Build.MODEL}"
    override fun usePlatformBridge() = false
    override fun createBridge(options: BridgeOptions?): BridgeSession = throw UnsupportedOperationException("不支持")
    override fun startNeighborMonitor(listener: NeighborUpdateListener?) {}
    override fun closeNeighborMonitor(listener: NeighborUpdateListener?) {}

    // ---------------- CommandServerHandler ----------------

    override fun serviceStop() {
        worker.execute { stopCore(null) }
    }
    override fun serviceReload() {
        VpnHub.log("serviceReload requested (not supported, ignored)")
    }
    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus().apply { available = false; enabled = false }
    override fun setSystemProxyEnabled(enabled: Boolean) {}
    override fun connectSSHAgent(): Int = throw UnsupportedOperationException("不支持")
    override fun triggerNativeCrash() {}
    override fun writeDebugMessage(message: String?) {
        if (message != null) VpnHub.log("debug: $message")
    }

    class StringArray(private val it: Iterator<String>) : StringIterator {
        override fun len() = 0
        override fun hasNext() = it.hasNext()
        override fun next() = it.next()
    }
}

