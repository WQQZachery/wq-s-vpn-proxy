# 第三方组件声明

WQ's Proxy VPN（原名 ProxyPilot Mobile）以 **GPL-3.0-or-later** 发布（见 `LICENSE`、`COPYING`）。由于 APK 内静态包含 sing-box（GPL-3.0-or-later），任何分发 APK 的人必须同时提供对应的完整源码（本仓库 + 下列 sing-box 版本源码 + 构建脚本）。

## 内置于 APK

| 组件 | 版本 | 许可证 | 来源 | 用途 |
|---|---|---|---|---|
| sing-box（libbox，gomobile 绑定） | 1.14.3 | GPL-3.0-or-later | https://github.com/SagerNet/sing-box | 代理核心、TUN 栈 |
| sing-box 依赖的 Go 模块（sing、sing-tun、gVisor、quic-go、wireguard-go、uTLS 等） | 见 sing-box v1.14.3 的 `go.mod` | 各自许可证（GPL/MIT/BSD-3/Apache-2.0） | 同上 | 核心内部 |
| Go 运行时 | 1.27.3 | BSD-3-Clause | https://go.dev | libbox 编译 |
| gomobile（SagerNet 分支，含本项目对 ARM64 主机的补丁） | v0.1.13 | BSD-3-Clause | https://github.com/sagernet/gomobile | 生成 AAR |
| Flutter 引擎与框架 | 3.47.8 | BSD-3-Clause | https://flutter.dev | UI |
| flutter_riverpod / riverpod | ^3.4.3 | MIT | pub.dev | 状态管理 |
| sqflite | ^2.4.5 | BSD-2-Clause | pub.dev | SQLite |
| flutter_secure_storage | ^11.2.0 | BSD-3-Clause | pub.dev | 凭据加密存储 |
| fl_chart | ^1.3.0 | MIT | pub.dev | 速度曲线 |
| path、cupertino_icons 及其传递依赖 | 见 `pubspec.lock` | BSD/MIT | pub.dev | — |

Flutter 依赖的完整许可证文本已由 Flutter 工具链打包进 APK（应用内“设置 → 关于 → 许可证”可查看）。

## 参考实现

`android/app/src/main/kotlin/.../vpn/ProxyVpnService.kt` 中 TUN 建立、网络接口枚举、默认网络监控的部分逻辑参考了 **sing-box-for-android（SFA）**（GPL-3.0-or-later，© nekohasekai），源码：https://github.com/SagerNet/sing-box-for-android 。

## 仅开发/测试使用（不进入 APK）

sqflite_common_ffi（BSD-2-Clause）、flutter_test、flutter_lints。

## 运行时访问的第三方服务（非代码依赖）

api.ip.sb、ipinfo.io（出口 IP）、api.abuseipdb.com（IP 信誉，需用户自备 Key）、speed.cloudflare.com（测速）、用户配置的 Cloudflare/Claude 检测目标。均在用户主动触发检测时访问。

## 未包含

Naive（需 cronet）、Tailscale、USB/IP、OpenVPN、OpenConnect 未编入 libbox，界面不提供这些协议。不包含 GeoIP/GeoSite 数据库。

## 1.2.0 新增依赖
- share_plus（BSD-3-Clause）、qr_flutter（BSD-3-Clause）、image_picker（Apache-2.0/BSD-3-Clause）
- mobile_scanner（BSD-3-Clause），内含 Google ML Kit Barcode Scanning（Google ML Kit Terms，专有）与 CameraX（Apache-2.0）。ML Kit 许可与 GPL 分发的兼容性待确认，见 docs/FEATURES_1.2.0.md。
