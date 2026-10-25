// SPDX-License-Identifier: GPL-3.0-or-later
// iOS 平台接口：sing-box(libbox) PlatformInterface + CommandServerHandler。
// 对应 Android ProxyVpnService.kt 的 PlatformInterface/CommandServerHandler 部分。
// openTun 的网络参数构建与 fd 获取方式移植自 sing-box-for-apple（SFI，GPL-3.0-or-later，© nekohasekai）。

import Foundation
import Libbox
import NetworkExtension
import os.log
import UIKit

private let extensionLogger = Logger(subsystem: "dev.proxypilot.vpn", category: "ExtensionPlatformInterface")

final class ExtensionPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private let tunnel: PacketTunnelProvider
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var nwMonitor: NWPathMonitor?
    private var lastNetworkPath: String?

    init(_ tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
    }

    // ---------------- openTun（核心） ----------------

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options else {
            throw NSError(domain: "ExtensionPlatformInterface", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Nil options"])
        }
        guard let ret0_ else {
            throw NSError(domain: "ExtensionPlatformInterface", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Nil return pointer"])
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            // DNS
            var dnsSettings: NEDNSSettings?
            let dnsMode = options.getDNSMode()?.value ?? ""
            if dnsMode != LibboxDNSModeDisabled {
                let dnsServerIterator = try options.getDNSServerAddress()
                var dnsServers: [String] = []
                while dnsServerIterator.hasNext() {
                    // StringIterator.next() → NSString* _Nonnull → Swift String（非可选）
                    dnsServers.append(dnsServerIterator.next())
                }
                if !dnsServers.isEmpty {
                    dnsSettings = NEDNSSettings(servers: dnsServers)
                }
            }

            // IPv4
            var ipv4Address: [String] = []
            var ipv4Mask: [String] = []
            let ipv4AddressIterator = options.getInet4Address()!
            while ipv4AddressIterator.hasNext() {
                let prefix = ipv4AddressIterator.next()!
                // RoutePrefix.address()/mask() 为 NSString* _Nonnull → 非可选
                ipv4Address.append(prefix.address())
                ipv4Mask.append(prefix.mask())
            }
            if !ipv4Address.isEmpty {
                let ipv4Settings = NEIPv4Settings(addresses: ipv4Address, subnetMasks: ipv4Mask)
                var ipv4Routes: [NEIPv4Route] = []
                var ipv4ExcludeRoutes: [NEIPv4Route] = []

                let inet4RouteAddressIterator = options.getInet4RouteAddress()!
                if inet4RouteAddressIterator.hasNext() {
                    while inet4RouteAddressIterator.hasNext() {
                        let prefix = inet4RouteAddressIterator.next()!
                        ipv4Routes.append(
                            NEIPv4Route(destinationAddress: prefix.address(),
                                        subnetMask: prefix.mask()))
                    }
                } else {
                    ipv4Routes.append(NEIPv4Route.default())
                }

                let inet4RouteExcludeIterator = options.getInet4RouteExcludeAddress()!
                while inet4RouteExcludeIterator.hasNext() {
                    let prefix = inet4RouteExcludeIterator.next()!
                    ipv4ExcludeRoutes.append(
                        NEIPv4Route(destinationAddress: prefix.address(),
                                    subnetMask: prefix.mask()))
                }

                ipv4Settings.includedRoutes = ipv4Routes
                ipv4Settings.excludedRoutes = ipv4ExcludeRoutes
                settings.ipv4Settings = ipv4Settings
            }

            // IPv6
            var ipv6Address: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            let ipv6AddressIterator = options.getInet6Address()!
            while ipv6AddressIterator.hasNext() {
                let prefix = ipv6AddressIterator.next()!
                ipv6Address.append(prefix.address())
                ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
            }
            if !ipv6Address.isEmpty {
                let ipv6Settings = NEIPv6Settings(addresses: ipv6Address, networkPrefixLengths: ipv6Prefixes)
                var ipv6Routes: [NEIPv6Route] = []
                var ipv6ExcludeRoutes: [NEIPv6Route] = []

                let inet6RouteAddressIterator = options.getInet6RouteAddress()!
                if inet6RouteAddressIterator.hasNext() {
                    while inet6RouteAddressIterator.hasNext() {
                        let prefix = inet6RouteAddressIterator.next()!
                        ipv6Routes.append(
                            NEIPv6Route(destinationAddress: prefix.address(),
                                        networkPrefixLength: NSNumber(value: prefix.prefix())))
                    }
                } else {
                    ipv6Routes.append(NEIPv6Route.default())
                }

                let inet6RouteExcludeIterator = options.getInet6RouteExcludeAddress()!
                while inet6RouteExcludeIterator.hasNext() {
                    let prefix = inet6RouteExcludeIterator.next()!
                    ipv6ExcludeRoutes.append(
                        NEIPv6Route(destinationAddress: prefix.address(),
                                    networkPrefixLength: NSNumber(value: prefix.prefix())))
                }

                ipv6Settings.includedRoutes = ipv6Routes
                ipv6Settings.excludedRoutes = ipv6ExcludeRoutes
                settings.ipv6Settings = ipv6Settings
            }

            let hasDefaultRoute = ipv4RouteContainsDefault(settings.ipv4Settings?.includedRoutes)
            if !hasDefaultRoute {
                dnsSettings?.matchDomains = [""]
                dnsSettings?.matchDomainsNoSearch = true
            }
            settings.dnsSettings = dnsSettings
        }

        // HTTP 代理（配置开启时）
        if options.isHTTPProxyEnabled() {
            let proxySettings = NEProxySettings()
            // getHTTPProxyServer() → NSString* _Nonnull → 非可选
            let proxyServer = NEProxyServer(address: options.getHTTPProxyServer(),
                                            port: Int(options.getHTTPProxyServerPort()))
            proxySettings.httpServer = proxyServer
            proxySettings.httpsServer = proxyServer
            proxySettings.httpEnabled = true
            proxySettings.httpsEnabled = true
            var bypassDomains: [String] = []
            let bypassDomainIterator = options.getHTTPProxyBypassDomain()!
            while bypassDomainIterator.hasNext() {
                bypassDomains.append(bypassDomainIterator.next())
            }
            if !bypassDomains.isEmpty {
                proxySettings.exceptionList = bypassDomains
            }
            settings.proxySettings = proxySettings
        }

        networkSettings = settings

        // 应用隧道网络参数（同步等待结果）
        var setError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        tunnel.setTunnelNetworkSettings(settings) { error in
            setError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let setError { throw setError }

        // 关键：NEPacketTunnelFlow 的私有 socket.fileDescriptor 即系统分配的 utun fd，
        // sing-tun 直接以该 fd 读写报文（getsockopt UTUN_OPT_IFNAME 可取得 utun 名）。
        if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFd
            return
        }
        // 兜底：libbox 内置扫描（kanged from wireguard-apple）
        let tunFdFromLoop = LibboxGetTunnelFileDescriptor()
        if tunFdFromLoop != -1 {
            ret0_.pointee = tunFdFromLoop
        } else {
            throw NSError(domain: "ExtensionPlatformInterface", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Missing file descriptor"])
        }
    }

    private func ipv4RouteContainsDefault(_ routes: [NEIPv4Route]?) -> Bool {
        guard let routes else { return false }
        return routes.contains { $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0" }
    }

    // ---------------- 接口控制 ----------------

    func usePlatformAutoDetectInterfaceControl() -> Bool { false }

    func autoDetectInterfaceControl(_: Int32) throws {}

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        // iOS 无对应 API（Android 用 ConnectivityManager.getConnectionOwnerUid）
        throw NSError(domain: "ExtensionPlatformInterface", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "Not implemented"])
    }

    // ---------------- 默认接口监控 ----------------

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.onUpdateDefaultInterface(listener, path)
            semaphore.signal()
            monitor.pathUpdateHandler = { [weak self] path in
                self?.onUpdateDefaultInterface(listener, path)
            }
        }
        monitor.start(queue: DispatchQueue.global())
        semaphore.wait()
    }

    private func onUpdateDefaultInterface(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: NWPath) {
        let networkPath = describeNetworkPath(path)
        listener.updateNetworkPath(networkPath)
        if networkPath == lastNetworkPath { return }
        lastNetworkPath = networkPath
        guard path.status != .unsatisfied,
              let defaultInterface = path.availableInterfaces.first
        else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(
            defaultInterface.name, interfaceIndex: Int32(defaultInterface.index),
            isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    private func describeNetworkPath(_ path: NWPath) -> String {
        var components: [String] = []
        switch path.status {
        case .satisfied: components.append("satisfied")
        case .unsatisfied: components.append("unsatisfied(\(path.unsatisfiedReason))")
        case .requiresConnection: components.append("requiresConnection")
        @unknown default: components.append("unknown")
        }
        if !path.availableInterfaces.isEmpty {
            components.append("interfaces=" + path.availableInterfaces.map { "\($0.name)#\($0.index)/\($0.type)" }.joined(separator: ","))
        }
        if !path.gateways.isEmpty {
            components.append("gateways=" + path.gateways.map { "\($0)" }.sorted().joined(separator: ","))
        }
        if path.supportsIPv4 { components.append("ipv4") }
        if path.supportsIPv6 { components.append("ipv6") }
        if path.supportsDNS { components.append("dns") }
        if path.isExpensive { components.append("expensive") }
        if path.isConstrained { components.append("constrained") }
        return components.joined(separator: " ")
    }

    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        nwMonitor?.cancel()
        nwMonitor = nil
        lastNetworkPath = nil
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let nwMonitor else {
            throw NSError(domain: "ExtensionPlatformInterface", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "NWMonitor not started"])
        }
        let path = nwMonitor.currentPath
        if path.status == .unsatisfied {
            return NetworkInterfaceArray([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for it in path.availableInterfaces {
            let interface = LibboxNetworkInterface()
            interface.name = it.name
            interface.index = Int32(it.index)
            switch it.type {
            case .wifi: interface.type = LibboxInterfaceTypeWIFI
            case .cellular: interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet: interface.type = LibboxInterfaceTypeEthernet
            default: interface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(interface)
        }
        return NetworkInterfaceArray(interfaces)
    }

    private final class NetworkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        private var nextValue: LibboxNetworkInterface?

        init(_ array: [LibboxNetworkInterface]) {
            iterator = array.makeIterator()
        }

        func hasNext() -> Bool {
            nextValue = iterator.next()
            return nextValue != nil
        }

        func next() -> LibboxNetworkInterface? { nextValue }
    }

    // ---------------- 杂项 ----------------

    func underNetworkExtension() -> Bool { true }

    func includeAllNetworks() -> Bool { false }

    func useProcFS() -> Bool { false }

    func clearDNSCache() {
        guard let networkSettings else { return }
        tunnel.reasserting = true
        defer { tunnel.reasserting = false }
        let semaphore1 = DispatchSemaphore(value: 0)
        tunnel.setTunnelNetworkSettings(nil) { _ in semaphore1.signal() }
        semaphore1.wait()
        let semaphore2 = DispatchSemaphore(value: 0)
        tunnel.setTunnelNetworkSettings(networkSettings) { _ in semaphore2.signal() }
        semaphore2.wait()
    }

    func readWIFIState() -> LibboxWIFIState? {
        // 与 Android 一致：未申请定位权限，不读取 SSID
        nil
    }

    func registerMyInterface(_ name: String?) {}

    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
    func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}

    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }

    func systemCertificates() -> LibboxStringIteratorProtocol? { nil }

    // ---------------- 通知 ----------------

    func sendNotification(_ notification: LibboxNotification?) throws {
        guard let notification else { return }
        // Notification.title 为 NSString* _Nonnull → Swift String（非可选）
        SharedBridge.appendLog("core notification: \(notification.title)")
    }

    func cancelNotification(_ identifier: String?, typeID _: Int32) throws {}

    // ---------------- Shell / 用户 ----------------

    func usePlatformShell() -> Bool { false }

    func checkPlatformShell() throws {
        throw NSError(domain: "ExtensionPlatformInterface", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "SSH server is not supported"])
    }

    func openShellSession(_ user: LibboxPlatformUser?, command: String?, environ: LibboxStringIteratorProtocol?, term: String?, rows: Int32, cols: Int32) throws -> LibboxShellSessionProtocol {
        throw NSError(domain: "ExtensionPlatformInterface", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "SSH server is not supported"])
    }

    func lookupUser(_ username: String?) throws -> LibboxPlatformUser {
        throw NSError(domain: "ExtensionPlatformInterface", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Not supported"])
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = NSError(domain: "ExtensionPlatformInterface", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "Not supported"])
        return ""
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = NSError(domain: "ExtensionPlatformInterface", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "Not supported"])
        return ""
    }

    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "ExtensionPlatformInterface", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "SSH agent forwarding is not supported"])
    }

    func tailscaleHostname() -> String {
        #if targetEnvironment(simulator)
        return "iPhone Simulator"
        #else
        return UIDevice.current.model
        #endif
    }

    // ---------------- Bridge ----------------

    func usePlatformBridge() -> Bool { false }

    func createBridge(_ options: LibboxBridgeOptions?) throws -> LibboxBridgeSessionProtocol {
        throw NSError(domain: "ExtensionPlatformInterface", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Bridge is not supported"])
    }

    // ---------------- CommandServerHandler ----------------

    func serviceStop() throws {
        // 核心请求停止：整体关闭隧道（对应 Android serviceStop → stopCore）
        SharedBridge.appendLog("core requested service stop")
        tunnel.cancelTunnelWithError(
            NSError(domain: "PacketTunnelProvider", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "核心请求停止"]))
    }

    func serviceReload() throws {
        // 与 Android 一致：不支持的运行时重载，忽略
        SharedBridge.appendLog("serviceReload requested (not supported, ignored)")
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        guard let networkSettings,
              let proxySettings = networkSettings.proxySettings,
              proxySettings.httpServer != nil
        else {
            return status
        }
        status.available = true
        status.enabled = proxySettings.httpEnabled
        return status
    }

    func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        guard let networkSettings,
              var proxySettings = networkSettings.proxySettings,
              proxySettings.httpServer != nil
        else {
            return
        }
        if proxySettings.httpEnabled == isEnabled { return }
        proxySettings.httpEnabled = isEnabled
        proxySettings.httpsEnabled = isEnabled
        networkSettings.proxySettings = proxySettings
        let semaphore = DispatchSemaphore(value: 0)
        var applyError: Error?
        tunnel.setTunnelNetworkSettings(networkSettings) { error in
            applyError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let applyError { throw applyError }
    }

    func triggerNativeCrash() throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
            fatalError("debug native crash")
        }
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        extensionLogger.debug("\(message, privacy: .public)")
    }

    // ---------------- 重置 ----------------

    func reset() {
        networkSettings = nil
        nwMonitor?.cancel()
        nwMonitor = nil
        lastNetworkPath = nil
    }
}
