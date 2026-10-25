// SPDX-License-Identifier: GPL-3.0-or-later
// Runner 与 PacketTunnelProvider 两个 target 共享的进程间通道（App Groups 容器）。
// 状态/流量/日志由扩展写入、App 读取；配置由 App 写入、扩展读取。

import Foundation

public final class SharedBridge {
    public static let appGroupID = "group.dev.proxypilot.vpn"

    private static let fm = FileManager.default
    private static let logQueue = DispatchQueue(label: "dev.proxypilot.vpn.log")
    private static let maxLogLines = 1000

    /// App Groups 共享容器；entitlement 缺失等异常情况下为 nil，相关功能降级为不可用。
    public static var container: URL? {
        fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static func fileURL(_ name: String) -> URL? {
        container?.appendingPathComponent(name)
    }

    private static func ensureDir(_ url: URL) {
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // ---------------- 运行配置 ----------------

    /// 写入运行配置（含节点凭据）。仅 App 与扩展进程可读，停止后删除。
    public static func writeConfig(_ config: String) {
        guard let url = fileURL("running-config.json") else { return }
        try? config.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func readConfig() -> String? {
        guard let url = fileURL("running-config.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deleteConfig() {
        guard let url = fileURL("running-config.json") else { return }
        try? fm.removeItem(at: url)
    }

    // ---------------- VPN 状态 ----------------

    public struct Status: Decodable {
        public let state: String
        public let message: String?
        public let ts: Int
    }

    /// 由扩展在生命周期切换时写入（权威状态源，与 Android VpnHub 语义一致）。
    public static func writeStatus(state: String, message: String? = nil) {
        guard let url = fileURL("status.json") else { return }
        var dict: [String: Any] = [
            "state": state,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if let message { dict["message"] = message }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func readStatus() -> Status? {
        guard let url = fileURL("status.json"),
              let data = try? Data(contentsOf: url),
              let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        return status
    }

    // ---------------- 流量统计 ----------------

    public struct Traffic: Decodable {
        public let ts: Int
        public let rx: Int64
        public let tx: Int64
    }

    public static func writeTraffic(rx: Int64, tx: Int64) {
        guard let url = fileURL("traffic.json") else { return }
        let dict: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "rx": rx,
            "tx": tx,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func readTraffic() -> Traffic? {
        guard let url = fileURL("traffic.json"),
              let data = try? Data(contentsOf: url),
              let traffic = try? JSONDecoder().decode(Traffic.self, from: data) else { return nil }
        return traffic
    }

    // ---------------- 日志 ----------------

    /// 追加一行日志（带毫秒时间戳，与 Android VpnHub.log 格式一致）。
    public static func appendLog(_ line: String) {
        guard let url = fileURL("vpn.log") else { return }
        logQueue.async {
            ensureDir(url.deletingLastPathComponent())
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let entry = "\(stamp) \(line)\n"
            guard let data = entry.data(using: .utf8) else { return }
            if fm.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
            trimLogIfNeeded(url)
        }
    }

    private static func trimLogIfNeeded(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        // 末尾 split 可能产生空串，真实行数以非空计
        if lines.count > maxLogLines + 1 {
            lines = Array(lines.suffix(maxLogLines))
            let trimmed = lines.joined(separator: "\n")
            try? trimmed.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public static func readLogs() -> String {
        guard let url = fileURL("vpn.log"),
              let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public static func clearLogs() {
        guard let url = fileURL("vpn.log") else { return }
        try? fm.removeItem(at: url)
    }

    // ---------------- 目录（Libbox 路径） ----------------

    /// Libbox basePath/workingPath/tempPath（共享容器内），供扩展与 App 进程初始化使用。
    public static func libboxPaths() -> (base: String, working: String, temp: String)? {
        guard let base = container else { return nil }
        let working = base.appendingPathComponent("Working").path
        let temp = base.appendingPathComponent("Temp").path
        ensureDir(base.appendingPathComponent("Working"))
        ensureDir(base.appendingPathComponent("Temp"))
        return (base.path, working, temp)
    }

    /// App 进程内 Libbox 路径（独立于共享容器，避免与扩展争用工作目录）。
    public static func appLibboxPaths() -> (base: String, working: String, temp: String) {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let working = docs.appendingPathComponent("sing-box").path
        ensureDir(URL(fileURLWithPath: working))
        return (docs.path, working, NSTemporaryDirectory())
    }
}
