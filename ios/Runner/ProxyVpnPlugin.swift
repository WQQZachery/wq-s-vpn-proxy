// SPDX-License-Identifier: GPL-3.0-or-later
// Flutter ↔ Swift 通信：与 Android MainActivity 的 MethodChannel('proxypilot/vpn')
// 七个方法 + EventChannel('proxypilot/vpn_events') 1:1 对齐。
// 状态以扩展进程写入的共享状态文件（权威）结合 NEVPNStatus 为准。

import Flutter
import Foundation
import Libbox
import NetworkExtension

public final class ProxyVpnPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let manager = VpnManager.shared
    private var eventSink: FlutterEventSink?
    private var pollTimer: DispatchSourceTimer?
    private var lastWireState: String?
    private var libboxReady = false
    private var retainedSelf: ProxyVpnPlugin?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "proxypilot/vpn", binaryMessenger: registrar.messenger())
        let instance = ProxyVpnPlugin()
        instance.retainedSelf = instance
        registrar.addMethodCallDelegate(instance, channel: channel)

        let events = FlutterEventChannel(
            name: "proxypilot/vpn_events", binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
    }

    // ---------------- MethodChannel ----------------

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "prepare":
            manager.prepare { ok in result(ok) }

        case "checkConfig":
            let args = call.arguments as? [String: Any]
            let config = args?["config"] as? String ?? ""
            ensureLibboxSetup()
            var error: NSError?
            LibboxCheckConfig(config, &error)
            result(error?.localizedDescription)

        case "start":
            let args = call.arguments as? [String: Any]
            let config = args?["config"] as? String ?? ""
            let name = args?["name"] as? String ?? VpnManager.profileName
            guard !config.isEmpty else {
                result(FlutterError(code: "start_failed", message: "配置为空", details: nil))
                return
            }
            manager.start(config: config, name: name) { ok in
                if ok {
                    result(nil)
                } else {
                    result(
                        FlutterError(
                            code: "start_failed", message: "无法启动 VPN（未授权或配置保存失败）",
                            details: nil))
                }
            }

        case "stop":
            manager.stop()
            result(nil)

        case "state":
            let (state, message) = manager.currentWireState()
            result(["state": state, "message": message ?? NSNull()])

        case "version":
            result(LibboxVersion())

        case "logs":
            result(SharedBridge.readLogs())

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// 在 App 进程初始化 Libbox（checkConfig 需要）。
    private func ensureLibboxSetup() {
        guard !libboxReady else { return }
        libboxReady = true
        let paths = SharedBridge.appLibboxPaths()
        let options = LibboxSetupOptions()
        options.basePath = paths.base
        options.workingPath = paths.working
        options.tempPath = paths.temp
        options.logMaxLines = 3000
        options.debug = false
        options.crashReportSource = "Runner"
        options.appVersion = "1"
        options.appMarketingVersion = "1.0.0"
        options.oomKillerEnabled = false
        var error: NSError?
        LibboxSetup(options, &error)
        if let error {
            libboxReady = false
            SharedBridge.appendLog("LibboxSetup(app) failed: \(error.localizedDescription)")
        }
    }

    // ---------------- EventChannel ----------------

    public func onListen(withArguments arguments: Any?, eventSink: FlutterEventSink) {
        self.eventSink = eventSink
        lastWireState = nil
        // 立即上报一次当前状态（与 Android onListen 行为一致）
        emitStateIfChanged(force: true)
        startPolling()
    }

    public func onCancel(withArguments arguments: Any?) {
        stopPolling()
        eventSink = nil
    }

    private func startPolling() {
        stopPolling()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.emitStateIfChanged(force: false)
            self.emitTrafficIfConnected()
        }
        timer.resume()
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func emitStateIfChanged(force: Bool) {
        guard let sink = eventSink else { return }
        let (state, message) = manager.currentWireState()
        guard force || state != lastWireState else { return }
        lastWireState = state
        var event: [String: Any] = ["type": "state", "state": state]
        if let message { event["message"] = message } else { event["message"] = NSNull() }
        DispatchQueue.main.async { sink(event) }
    }

    private func emitTrafficIfConnected() {
        guard let sink = eventSink, manager.connectionStatus == .connected else { return }
        guard let traffic = SharedBridge.readTraffic() else { return }
        let event: [String: Any] = [
            "type": "traffic",
            "ts": traffic.ts,
            "rx": traffic.rx,
            "tx": traffic.tx,
        ]
        DispatchQueue.main.async { sink(event) }
    }
}
