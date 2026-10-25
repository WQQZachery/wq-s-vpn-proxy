// SPDX-License-Identifier: GPL-3.0-or-later
// iOS Network Extension：NEPacketTunnelProvider + sing-box(libbox) 生命周期。
// 对应 Android 的 ProxyVpnService.kt（CommandServer 模式 + PlatformInterface 全回调）。
// 部分实现参考 sing-box-for-apple（SFI，GPL-3.0-or-later，© nekohasekai）的 ExtensionProvider.swift。

import Foundation
import NetworkExtension
import Libbox

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var commandServer: LibboxCommandServer?
    private lazy var platformInterface = ExtensionPlatformInterface(self)
    private var statusClient: LibboxCommandClient?
    private var stopping = false
    /// clearDNSCache 重设网络参数时置位（对应 Android 的重assert 语义）
    var reasserting = false

    override init() {
        LibboxPrepareCrashSignalHandlers()
        super.init()
        LibboxReinstallCrashSignalHandlers()
    }

    // ---------------- 生命周期 ----------------

    override func startTunnel(options: [String : NSObject]?) async throws {
        stopping = false
        SharedBridge.writeStatus(state: "starting")

        let config: String
        if let content = options?["configContent"] as? String, !content.isEmpty {
            config = content
        } else if let persisted = SharedBridge.readConfig(), !persisted.isEmpty {
            config = persisted
        } else {
            let message = "缺少启动配置（configContent）"
            SharedBridge.writeStatus(state: "error", message: message)
            throw NSError(
                domain: "PacketTunnelProvider", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        // 持久化配置：系统按需重启扩展时可自愈（始终-on VPN / 网络变化重连）
        SharedBridge.writeConfig(config)

        guard let paths = SharedBridge.libboxPaths() else {
            let message = "App Groups 容器不可用"
            SharedBridge.writeStatus(state: "error", message: message)
            throw NSError(
                domain: "PacketTunnelProvider", code: 2,
                userInfo: [NSLocalizedDescriptionKey: message])
        }

        let setupOptions = LibboxSetupOptions()
        setupOptions.basePath = paths.base
        setupOptions.workingPath = paths.working
        setupOptions.tempPath = paths.temp
        setupOptions.logMaxLines = 3000
        setupOptions.debug = false
        setupOptions.crashReportSource = "NetworkExtension"
        setupOptions.appVersion = "1"
        setupOptions.appMarketingVersion = "1.0.0"
        setupOptions.oomKillerEnabled = true

        var setupError: NSError?
        LibboxSetup(setupOptions, &setupError)
        if let setupError {
            let message = "setup service: \(setupError.localizedDescription)"
            SharedBridge.writeStatus(state: "error", message: message)
            throw NSError(
                domain: "PacketTunnelProvider", code: 3,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        LibboxPromoteOOMDraft()
        LibboxDiscardPowerReportDraft()

        var serverError: NSError?
        let server = LibboxNewCommandServer(platformInterface, platformInterface, &serverError)
        if let serverError {
            let message = "create command server error: \(serverError.localizedDescription)"
            SharedBridge.writeStatus(state: "error", message: message)
            throw NSError(
                domain: "PacketTunnelProvider", code: 4,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        commandServer = server

        do {
            try server?.start()
        } catch {
            let message = "start command server error: \(error.localizedDescription)"
            SharedBridge.writeStatus(state: "error", message: message)
            throw NSError(
                domain: "PacketTunnelProvider", code: 5,
                userInfo: [NSLocalizedDescriptionKey: message])
        }

        do {
            // openTun 会在此过程中被 libbox 回调（设置系统隧道参数）
            try server?.startOrReloadService(config, options: LibboxOverrideOptions())
        } catch {
            let message = "start service: \(error.localizedDescription)"
            SharedBridge.writeStatus(state: "error", message: message)
            throw NSError(
                domain: "PacketTunnelProvider", code: 6,
                userInfo: [NSLocalizedDescriptionKey: message])
        }

        startStatusClient()
        SharedBridge.writeStatus(state: "started")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        SharedBridge.appendLog("(packet-tunnel) stopping, reason: \(reason.rawValue)")
        stopping = true
        platformInterface.reset()

        if let statusClient {
            try? statusClient.disconnect()
            self.statusClient = nil
        }
        if let server = commandServer {
            try? server.closeService()
            server.close()
            commandServer = nil
        }
        // 明确错误状态下保留 error 状态供 App 读取；否则落 stopped
        if SharedBridge.readStatus()?.state != "error" {
            SharedBridge.writeStatus(state: "stopped")
        }
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }

    // ---------------- 状态/流量客户端（对应 Android startStatusClient） ----------------

    private func startStatusClient() {
        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandStatus)
        options.addCommand(LibboxCommandLog)
        options.statusInterval = 500 * 1000 * 1000 // 500 ms，单位纳秒
        // gomobile：Go 侧 *CommandClient 指针返回 → ObjC _Nullable → Swift 可选（参考 SFI/Hiddify 用法）
        guard let client = LibboxNewCommandClient(StatusClientHandler(self), options) else {
            SharedBridge.appendLog("create status client failed")
            return
        }
        do {
            try client.connect()
            statusClient = client
        } catch {
            SharedBridge.appendLog("status client connect failed: \(error.localizedDescription)")
        }
    }

    func reportCoreExit(_ message: String?) {
        guard !stopping else { return }
        stopping = true
        let detail = message.map { "：\($0)" } ?? ""
        SharedBridge.appendLog("(packet-tunnel) core exited unexpectedly\(detail)")
        SharedBridge.writeStatus(state: "error", message: "核心异常退出\(detail)")
    }

    func isStopping() -> Bool { stopping }
}

// ---------------- CommandClientHandler（状态/流量/日志） ----------------

private final class StatusClientHandler: NSObject, LibboxCommandClientHandlerProtocol {
    private weak var tunnel: PacketTunnelProvider?

    init(_ tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
    }

    func connected() {}

    func disconnected(_ message: String?) {
        tunnel?.reportCoreExit(message)
    }

    func writeStatus(_ message: LibboxStatusMessage?) {
        guard let message, message.trafficAvailable else { return }
        SharedBridge.writeTraffic(rx: message.downlinkTotal, tx: message.uplinkTotal)
    }

    func writeLogs(_ messageList: LibboxLogIteratorProtocol?) {
        guard let messageList else { return }
        while messageList.hasNext() {
            guard let entry = messageList.next() else { continue }
            // LogEntry.Message 为 NSString* _Nonnull → Swift String（非可选）
            SharedBridge.appendLog("core: \(entry.message)")
        }
    }

    func clearLogs() {}

    func initializeClashMode(_ modeList: LibboxStringIteratorProtocol?, currentMode: String?) {}

    func setDefaultLogLevel(_ level: Int32) {}

    func updateClashMode(_ newMode: String?) {}

    func writeConnectionEvents(_ events: LibboxConnectionEvents?) {}

    func writeGroups(_ message: LibboxOutboundGroupIteratorProtocol?) {}

    func writeOutbounds(_ message: LibboxOutboundGroupItemIteratorProtocol?) {}
}
