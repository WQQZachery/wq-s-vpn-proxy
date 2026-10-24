# 测试报告 — WQ's Proxy VPN（原 ProxyPilot Mobile）

日期：2026-10-24（Asia/Shanghai）
环境：Debian 13 aarch64 容器，2 核 / 7.8 GiB；**无 Android 真机、无模拟器**。

## 结论摘要

| 项目 | 结果 |
|---|---|
| `flutter analyze` | 0 error / 0 warning（剩余为 info 级风格提示） |
| 单元测试 `flutter test` | **55 个全部通过**（0 跳过），日志 `logs/test-3.log` |
| 生成配置经真实 sing-box 1.14.3 `check` 校验 | 3 种路由模式 × IPv6 开/关 = 6 组，全部通过 |
| release APK 构建 | 成功，`app-release.apk` 27,945,165 字节，arm64-v8a，日志 `logs/build-app-3.log` |
| APK 内容核对 | 含 `libbox.so`、`libflutter.so`、`libapp.so`；Manifest 含 VpnService（BIND_VPN_SERVICE、specialUse 前台服务）与所需权限 |
| 设备安装 / VPN 授权 / 连接 / 断开 / 网络切换 / 前台服务 | **未执行**（无设备） |
| 实网出口 IP、Cloudflare、Claude、测速检测 | **未在设备上执行**；代码路径仅由单元测试覆盖解析与分类逻辑 |

APK SHA-256：`785a42f55a119f65743862255cc1236895ff581ab374b04efa14f9a36c241f47`
签名：Flutter 模板 debug 签名（仅用于自测安装）。

## 单元测试覆盖

- 分享链接解析：ss（SIP002 / 旧格式 / 插件拒绝）、vmess（ws+tls）、vless（REALITY+Vision，缺 pbk 拒绝）、trojan（gRPC）、hysteria2（salamander，端口跳跃明确报“不支持”）、tuic、socks5、未知协议、端口越界。
- 订阅：Base64 订阅含错误条目统计、sing-box JSON 订阅（跳过 selector/direct，naive 记为不支持）、HTML / Clash YAML / 空内容的明确报错、去重。
- 节点校验：主机名/IPv4/IPv6、拒绝跳过证书校验、SS 加密白名单、Vision 与传输冲突。
- 配置生成：selector 默认值、规则顺序（sniff → hijack-dns → 私有地址 → 直连后缀 → 代理后缀 → final）、全局/直连模式、IPv6 开关、Clash API 仅监听 127.0.0.1、非法节点/DNS 拒绝生成；**6 组配置调用宿主机 sing-box 1.14.3 `check` 实际校验**（该二进制与 libbox 同源码、同 tags 编译）。
- 规则命中：私有地址（含 172.16/12 边界、fd00::/8）、域名后缀精确匹配边界（`notexample.org` 不命中 `example.org`）、模式差异。规则解释器与生成规则同序，但实际转发由核心决定。
- 检测错误分类：超时、DNS、连接拒绝、网络不可达、证书、TLS、协议、未知；Cloudflare 结论（挑战 vs 可达 vs 未见 CF）；Claude 结论绝不声称账户可用。
- API 解析：ip.sb、ipinfo、缺字段报错、AbuseIPDB 原始字段与定义、未配置 Key 时返回“数据不可用”。
- 流量统计：速度/峰值/会话累计、计数器回绕不产生负值、无数据显示“暂无数据”。
- 日志脱敏：订阅 token、分享链接、密码、UUID、Bearer。
- Flutter↔Kotlin 通道：事件解析、MethodChannel 调用顺序与错误传递（**原生端为 Mock，仅验证 Dart 侧协议**）。
- 并发限制：20 个任务、并发上限 4。
- 数据库：sqflite ffi 真实 SQLite 文件；验证节点密码和订阅 token **不出现在数据库文件字节中**（存于安全存储），健康统计、检测历史读写。

## 未完成 / 已知限制

1. 没有在任何 Android 设备上安装运行。Kotlin `ProxyVpnService` 仅通过编译（含 R8），TUN 建立、`protect()`、核心启动/停止、`onRevoke`、Wi-Fi/移动网切换、前台通知均未实际验证。
2. 未在设备上验证 `Libbox.checkConfig` / `startOrReloadService` 运行时行为。
3. 测速端点（speed.cloudflare.com `__down`/`__up`）行为未实测。
4. 无 GeoIP/GeoSite 规则集；自动分流仅支持私有地址 + 用户域名后缀。按应用分流未实现。
5. 仅 arm64-v8a；APK 中另有 `libdartjni.so` 的 armeabi-v7a/x86_64 副本（来自 path_provider_android 依赖，不影响 arm64 设备）。
6. 构建日志中 NDK `llvm-objcopy`（x86_64 二进制）报语法错误，属非致命警告：影响的是调试符号剥离，APK 仍生成。

## 建议的设备测试清单（需真机）

安装 → 首次授予 VPN 权限 → 导入自有节点 → 连接（通知出现、状态“已连接”）→ 浏览器访问 → 检测中心出口 IP 变为节点 IP → 首页速度/流量随下载变化 → 切换 Wi-Fi↔移动网后仍可访问 → 系统设置中断开 VPN（应用显示错误状态“授权被撤销”）→ 重新连接 → 断开后 `running-config.json` 已删除。
