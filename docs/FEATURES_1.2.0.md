# WQ's Proxy VPN 1.2.0：R1–R4 与连接生命周期

基于 `fix/utls-fingerprint-1.1.1`（含 1.1.1 的 uTLS 修复），未合并 main、未发布 Release。

## R1 节点分组（已实现）
- 节点页右上角「分组与排序」：不分组 / 按来源（手动·分享链接、各订阅、已删除的订阅）/ 按协议。
- 排序：默认顺序 / 按延迟（有结果的升序在前，未测/失败的在后）/ 按名称。
- 分组标题显示数量与可用数，可折叠；分组方式、排序和折叠状态保存在数据库 kv（`nodeGroupPrefs`），损坏时回退默认。
- 只影响显示，不修改节点和生成的配置（测试覆盖）。
- 代码：`lib/features/profiles/node_grouping.dart`

## R2 节点导出（补齐）
- 1.1.1 已有：复制分享链接、批量、Base64 订阅、隐私提示。
- 新增：系统分享（share_plus）、二维码展示（qr_flutter，内容超过 2400 字节时禁用并提示）。
- 所有导出动作前都显示凭据隐私提示。

## R3 二维码 / 相册导入（已实现）
- 「添加节点」菜单：扫码导入、从相册图片识别。
- mobile_scanner 7.4.2，使用**内置** ML Kit 模型，不依赖 Google Play 服务（国行 MIUI/HyperOS 可用）。
- 相册使用 image_picker；Android 13+ 走系统照片选择器，不申请存储权限。新增权限仅 CAMERA（运行时请求，拒绝后可改用相册）。
- 识别结果归类（`classifyQrPayload`）：节点链接/JSON/Base64 订阅内容 → 走原有 `importText`（解析 + 校验 + 去重，不绕过安全校验）；单个 http(s) 地址 → 预填到「添加订阅」；其他内容（如 Wi-Fi 二维码）拒绝。
- 代码：`lib/features/profiles/qr_import.dart`

## R4 连接动效（重新审查后补齐）
审查结论：旋转、成功波纹、呼吸光晕、失败抖动+震动、减少动态效果、控制器释放、非当前页 TickerMode 关闭均已存在。真实缺失：
1. **连接中没有波纹**：只有成功后一次性波纹。已补：preparing/connecting 阶段两道错开的扩散波纹，复用旋转控制器，不增加 Ticker；减少动态效果时不绘制。
2. **动画可能无限转圈**：内核卡在 starting 时没有超时，按钮一直显示“连接中”。已补：30 秒未上报 started → 主动停止内核，最终状态为「连接超时」（不是普通“已断开”）。
- 测试：连接中/已连接有持续帧、断开后静止；减少动态效果无持续帧；移除组件后无残留 Ticker。

## 连接生命周期测试（FakeEngine，非真机）
- 超时 → 停止一次并显示连接超时；及时 started → 不触发超时
- 三连击只启动一次
- 配置校验失败（含节点名标注）/ 授权拒绝 / 启动异常 三种结果各不相同，均不显示已连接

## 测试
- `flutter test`：150 通过，0 失败，0 跳过（新增 `test/r1_r4_test.dart` 19 个）
- `flutter analyze`：0 error，0 warning，56 info
- 真机：**未执行**（扫码、相机权限、系统分享、真实连接都需在 Redmi K60 上验证）

## APK
- `deliver/WQs-Proxy-VPN-1.2.0-arm64-v8a.apk`，32,282,455 字节，1.2.0（versionCode 4），仅 arm64-v8a
- SHA-256 `893e8f7b52e411325d2c9446ca04ad754f322eee65144b6c71f85e1aede103ee`
- 签名证书与 1.1.1 相同（`8108…5cc6`），可直接覆盖 1.1.1；从 1.1.0 及以前升级需先卸载
- 体积 +4.3MB：ML Kit 条码模型与 CameraX 原生库

## 风险
- Google ML Kit 条码库为 Google 专有许可（ML Kit Terms），与本项目 GPL-3.0-or-later 分发存在兼容性疑问，正式发布前需确认；可替换为纯 Dart 的 zxing 方案。
- dedupKey 仍不含 REALITY 公钥/short_id（未改）。
