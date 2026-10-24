# WQ's Proxy VPN

> 原名 **ProxyPilot Mobile**，自 1.0.0 起更名为 **WQ's Proxy VPN**。Android 包名 `dev.proxypilot.proxypilot_mobile` 与 Dart 包名 `proxypilot_mobile` 保持不变，以便已安装版本可直接覆盖升级。

基于 [sing-box](https://github.com/SagerNet/sing-box) 1.14.3（libbox）的 Android VPN 客户端：Flutter + Riverpod + SQLite 界面，Kotlin `VpnService` 承载 TUN，简体中文深色主题。

## 功能

- 节点：Shadowsocks（含 2022）、VMess、VLESS（REALITY / Vision）、Trojan、Hysteria2、TUIC、SOCKS5、HTTP；手动编辑、分享链接 / Base64 订阅 / sing-box JSON 导入、去重、批量测试
- 路由：全局 / 自动分流（私有地址 + 自定义域名后缀）/ 直连；远程与直连 DNS、IPv6、严格路由
- 检测中心：出口 IP、AbuseIPDB 信誉（需自备 Key）、Cloudflare、Claude 端点可达性、自定义 HTTPS 分步检测、主动测速、历史记录
- 首页：内核真实流量计数的实时速度与累计流量
- 凭据保存在 Android Keystore 安全存储；日志导出自动脱敏；禁止跳过证书校验

## 状态

**未在真机上验证 VPN 连接。** 单元测试与构建结果见 [docs/TEST_REPORT.md](docs/TEST_REPORT.md)。当前 APK 使用调试签名，仅 arm64-v8a。

## 构建

见 [docs/BUILD.md](docs/BUILD.md)。`android/app/libs/libbox.aar` 不入库，用 `scripts/build-libbox.sh` 从 sing-box v1.14.3 源码生成。

## 许可证

GPL-3.0-or-later（见 [LICENSE](LICENSE)、[COPYING](COPYING)）。内含 sing-box（GPL-3.0-or-later），第三方声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
