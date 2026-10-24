// SPDX-License-Identifier: GPL-3.0-or-later
package dev.proxypilot.proxypilot_mobile.vpn

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import java.io.File

/** VPN 状态与事件的进程内中心。状态只由 [ProxyVpnService] 根据 sing-box 真实生命周期更新。 */
object VpnHub {
    enum class State(val wire: String) { STOPPED("stopped"), STARTING("starting"), STARTED("started"), STOPPING("stopping"), ERROR("error") }

    @Volatile var state: State = State.STOPPED
        private set
    @Volatile var message: String? = null
        private set

    private val main = Handler(Looper.getMainLooper())
    private val listeners = mutableListOf<(Map<String, Any?>) -> Unit>()
    private val logs = ArrayDeque<String>()

    fun addListener(l: (Map<String, Any?>) -> Unit) = synchronized(listeners) { listeners.add(l) }
    fun removeListener(l: (Map<String, Any?>) -> Unit) = synchronized(listeners) { listeners.remove(l) }

    private fun emit(event: Map<String, Any?>) {
        val snapshot = synchronized(listeners) { listeners.toList() }
        main.post { snapshot.forEach { it(event) } }
    }

    fun setState(s: State, msg: String? = null) {
        state = s
        message = msg
        log("state=${s.wire}${if (msg != null) " $msg" else ""}")
        emit(mapOf("type" to "state", "state" to s.wire, "message" to msg))
    }

    /** 上报 sing-box 内核统计的累计流量（字节）。 */
    fun traffic(rx: Long, tx: Long) {
        emit(mapOf("type" to "traffic", "ts" to System.currentTimeMillis(), "rx" to rx, "tx" to tx))
    }

    fun log(line: String) = synchronized(logs) {
        logs.addLast("${System.currentTimeMillis()} $line")
        while (logs.size > 1000) logs.removeFirst()
    }

    fun dumpLogs(): String = synchronized(logs) { logs.joinToString("\n") }

    @Volatile private var setupDone = false

    /** Libbox 全局初始化（只需一次）。 */
    @Synchronized
    fun ensureSetup(ctx: Context) {
        if (setupDone) return
        val app = ctx.applicationContext
        val working = File(app.filesDir, "sing-box").apply { mkdirs() }
        val opts = SetupOptions().apply {
            basePath = app.filesDir.path
            workingPath = working.path
            tempPath = app.cacheDir.path
            // 与官方 SFA 相同：Android 7.x 与 9+ 需要 fixAndroidStack
            fixAndroidStack = Build.VERSION.SDK_INT in Build.VERSION_CODES.N..Build.VERSION_CODES.N_MR1 || Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
            logMaxLines = 3000
            debug = false
            crashReportSource = "WQsProxyVPN"
            appVersion = "1"
            appMarketingVersion = "1.0.0"
        }
        Libbox.setup(opts)
        setupDone = true
    }
}
