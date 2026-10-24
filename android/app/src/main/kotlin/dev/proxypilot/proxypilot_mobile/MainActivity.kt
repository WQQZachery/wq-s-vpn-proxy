// SPDX-License-Identifier: GPL-3.0-or-later
package dev.proxypilot.proxypilot_mobile

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import dev.proxypilot.proxypilot_mobile.vpn.ProxyVpnService
import dev.proxypilot.proxypilot_mobile.vpn.VpnHub
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.nekohasekai.libbox.Libbox
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private var pendingPrepare: MethodChannel.Result? = null
    private var eventListener: ((Map<String, Any?>) -> Unit)? = null

    companion object {
        private const val REQ_VPN = 0x5650
        private const val REQ_NOTIFY = 0x5651
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "proxypilot/vpn").setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> {
                    val intent = VpnService.prepare(this)
                    if (intent == null) {
                        result.success(true)
                    } else {
                        pendingPrepare?.success(false)
                        pendingPrepare = result
                        startActivityForResult(intent, REQ_VPN)
                    }
                }
                "checkConfig" -> {
                    val cfg = call.argument<String>("config") ?: ""
                    io.execute {
                        val err = try {
                            VpnHub.ensureSetup(this)
                            Libbox.checkConfig(cfg)
                            null
                        } catch (e: Throwable) {
                            e.message ?: e.javaClass.simpleName
                        }
                        runOnUiThread { result.success(err) }
                    }
                }
                "start" -> {
                    val cfg = call.argument<String>("config") ?: ""
                    val name = call.argument<String>("name") ?: "WQ's Proxy VPN"
                    requestNotificationPermissionIfNeeded()
                    try {
                        // 配置经文件传递（避免 Intent 大小限制）；仅应用私有目录可读，停止后删除
                        ProxyVpnService.configFile(this).writeText(cfg)
                        val i = Intent(this, ProxyVpnService::class.java).setAction(ProxyVpnService.ACTION_START).putExtra(ProxyVpnService.EXTRA_NAME, name)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i) else startService(i)
                        result.success(null)
                    } catch (e: Throwable) {
                        result.error("start_failed", e.message, null)
                    }
                }
                "stop" -> {
                    if (VpnHub.state == VpnHub.State.STOPPED || VpnHub.state == VpnHub.State.ERROR) {
                        result.success(null)
                    } else {
                        startService(Intent(this, ProxyVpnService::class.java).setAction(ProxyVpnService.ACTION_STOP))
                        result.success(null)
                    }
                }
                "state" -> result.success(mapOf("state" to VpnHub.state.wire, "message" to VpnHub.message))
                "version" -> io.execute {
                    val v = runCatching { Libbox.version() }.getOrElse { "未知" }
                    runOnUiThread { result.success(v) }
                }
                "logs" -> result.success(VpnHub.dumpLogs())
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "proxypilot/vpn_events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val l: (Map<String, Any?>) -> Unit = { events.success(it) }
                eventListener = l
                VpnHub.addListener(l)
                events.success(mapOf("type" to "state", "state" to VpnHub.state.wire, "message" to VpnHub.message))
            }

            override fun onCancel(arguments: Any?) {
                eventListener?.let { VpnHub.removeListener(it) }
                eventListener = null
            }
        })
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_VPN) {
            pendingPrepare?.success(resultCode == RESULT_OK)
            pendingPrepare = null
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        eventListener?.let { VpnHub.removeListener(it) }
        super.onDestroy()
    }
}
