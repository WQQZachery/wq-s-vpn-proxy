// SPDX-License-Identifier: GPL-3.0-or-later
// App 侧 NETunnelProviderManager 封装：对应 Android 的 VpnService.prepare / startService 语义。

import Foundation
import NetworkExtension

public final class VpnManager: NSObject {
    public static let shared = VpnManager()

    public static let providerBundleID = "dev.proxypilot.proxypilot_mobile.PacketTunnelProvider"
    public static let profileName = "WQ's Proxy VPN"

    private var manager: NETunnelProviderManager?
    private var loading = false
    private var loadCompletion: ((Error?) -> Void)?

    /// NEVPNStatus → Dart 侧 wire state（与 VpnEngine.parseState 对齐）。
    public static func wireState(for status: NEVPNStatus) -> String {
        switch status {
        case .connecting: return "starting"
        case .connected: return "started"
        case .disconnecting: return "stopping"
        case .reasserting: return "starting"
        case .invalid: return "error"
        case .disconnected: return "stopped"
        @unknown default: return "stopped"
        }
    }

    private override init() {
        super.init()
    }

    // ---------------- 配置加载/保存 ----------------

    public func load(completion: @escaping (Error?) -> Void) {
        if let manager {
            completion(nil)
            return
        }
        if loading {
            loadCompletion = completion
            return
        }
        loading = true
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else { return }
            self.loading = false
            if let error {
                self.loadCompletion?(error)
                self.loadCompletion = nil
                return
            }
            self.manager = managers?.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == VpnManager.providerBundleID
            } ?? NETunnelProviderManager()
            let pending = self.loadCompletion
            self.loadCompletion = nil
            completion(nil)
            pending?(nil)
        }
    }

    /// 创建/更新 VPN 配置并请求系统授权。首次调用弹出系统 consent 对话框；
    /// 用户拒绝时 completion(false)。
    public func prepare(completion: @escaping (Bool) -> Void) {
        load { [weak self] error in
            guard let self, error == nil, let manager = self.manager else {
                completion(false)
                return
            }
            if manager.protocolConfiguration == nil {
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = VpnManager.providerBundleID
                proto.serverAddress = VpnManager.profileName
                manager.protocolConfiguration = proto
            }
            manager.localizedDescription = VpnManager.profileName
            manager.isEnabled = true
            manager.saveToPreferences { saveError in
                completion(saveError == nil)
            }
        }
    }

    /// 已保存过配置（含授权）时返回 true。
    public func isPrepared() -> Bool {
        manager?.protocolConfiguration != nil
    }

    // ---------------- 启动/停止 ----------------

    public func start(config: String, name: String, completion: @escaping (Bool) -> Void) {
        SharedBridge.writeConfig(config)
        prepare { [weak self] ok in
            guard let self, ok else {
                completion(false)
                return
            }
            // 冗余持久化：随 VPN 配置保存，扩展被系统重启时可自愈
            if let proto = self.manager?.protocolConfiguration as? NETunnelProviderProtocol {
                var cfg = proto.providerConfiguration ?? [:]
                cfg["configContent"] = config
                cfg["name"] = name
                proto.providerConfiguration = cfg
                self.manager?.saveToPreferences { _ in
                    self.launchTunnel(name: name)
                    completion(true)
                }
            } else {
                self.launchTunnel(name: name)
                completion(true)
            }
        }
    }

    private func launchTunnel(name: String) {
        let options: [String: NSObject] = [
            "configContent": (SharedBridge.readConfig() ?? "") as NSString,
            "name": name as NSString,
        ]
        manager?.connection.startVPNTunnel(options: options)
    }

    public func stop() {
        manager?.connection.stopVPNTunnel()
    }

    // ---------------- 状态 ----------------

    public var connectionStatus: NEVPNStatus {
        manager?.connection.status ?? .invalid
    }

    /// 当前权威状态：扩展写入的 status.json 优先，NEVPNStatus 兜底。
    public func currentWireState() -> (String, String?) {
        if manager?.protocolConfiguration == nil {
            // 尚未创建配置：等同 Android 初始 STOPPED
            return ("stopped", nil)
        }
        let status = connectionStatus
        if status == .invalid {
            // 配置存在但连接无效：读扩展上报（可能是 error）
            if let s = SharedBridge.readStatus(), s.state == "error" {
                return ("error", s.message)
            }
            return ("stopped", nil)
        }
        if let s = SharedBridge.readStatus() {
            if s.state == "error" { return ("error", s.message) }
            // 仅在系统层也处于停止类状态时信任扩展的 stopped；
            // NE 正在 connecting/connected 时 status.json 里的 stopped 必为上一次会话的陈旧值
            if s.state == "stopped",
               status == .disconnecting || status == .disconnected || status == .invalid {
                return ("stopped", s.message)
            }
        }
        return (VpnManager.wireState(for: status), nil)
    }
}
