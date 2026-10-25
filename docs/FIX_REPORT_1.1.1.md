# WQ's Proxy VPN 1.1.1 修复报告

## A. 基线
- main HEAD：c2208fa（= 35dba15 的 1.1.0 源码 + Release 附件工作流），工作区干净
- 远程分支：main、apk、rebrand/wqs-proxy-vpn、ux-upgrade-1.1.0（均已并入 main），无其他未合并修复分支
- 工作分支：fix/utls-fingerprint-1.1.1
- 源码中不存在 sanitizeUtlsFingerprint / healUtlsFingerprint

## B. 根因：unknown uTLS fingerprint: unsafe
- 链路：share_link_parser.dart 把 `fp` 原样存为 `tls.fingerprint`（vless/trojan/vmess/sing-box JSON 都是如此）→ 数据库原样保存 → config_builder.dart 原样写入 `tls.utls.fingerprint`
- sing-box 1.14.3（option/tls.go、common/tls/utls_client.go）只接受 chrome、chrome_psk、chrome_psk_shuffle、chrome_padding_psk_shuffle、chrome_pq、chrome_pq_psk、firefox、edge、safari、360、qq、ios、android、random、randomized；空值 = chrome
- ConfigBuilder 把**所有已启用节点**都写成出站（供 selector / 延迟检测用），所以只要有一个节点是 fp=unsafe，无论选哪个节点，都会在 `initialize outbound[N]` 处启动失败。N 是那个坏节点的下标，不一定是用户选中的节点
- 复现：test/utls_fingerprint_test.dart「复现」用例对宿主机 sing-box 1.14.3 执行 check，得到 `unknown uTLS fingerprint: unsafe`
- 修复：
  - 新增 lib/core/engine/utls_fingerprint.dart。合法值保留；空值 = 未设置；`unsafe`/`none`（Xray 写法，意思是不用 uTLS）→ 不启用 uTLS；其他值丢弃并给出诊断
  - config_builder.nodeOutbound 是最后一道关：普通 TLS 不写 utls；REALITY 必须用 uTLS，用 chrome（即内核默认值）。REALITY 的 public_key、short_id、server_name，以及 UUID、flow、transport 原样保留。insecure 证书校验逻辑不变
  - NodeValidator 对不支持的指纹给出警告；ConfigBuilder.build 为非选中节点生成带节点名的警告并写入日志
  - BuiltConfig.annotateError 把内核报错里的 outbound[N] 标注成具体节点名
  - 历史数据不改写，每次生成配置时都会处理，所以旧数据库和重复导入都绕不过去

## C. R1–R4
- R1 节点分组：未实现。profiles_page.dart 只有搜索和筛选（全部/已启用/可用/失败）
- R2 节点导出：本次部分实现。lib/core/networking/share_link_serializer.dart 支持单节点/批量分享链接、Base64 订阅、复制到剪贴板，复制前有凭据隐私提示；有 16 个往返测试。系统分享和二维码展示未做（需要新增依赖）
- R3 二维码/相册导入：未实现。需要 mobile_scanner 或 ML Kit、相机/相册权限，会增大 APK，本次未做
- R4 连接动效：已完整实现（1.1.0 的 connect_orb.dart，由真实 VpnState 驱动，支持减少动态效果，test/ux_upgrade_test.dart 覆盖）。本次未改动

## D. 测试
- flutter test：131 个，全部通过，0 失败，0 跳过（原有 96 个 + uTLS 19 个 + 导出 16 个）
- flutter analyze：0 error、0 warning、56 info

## E. sing-box 配置校验
- 宿主机 sing-box v1.14.3（与 libbox 同源同 tags）check：
  - 原始 unsafe：被拒绝（复现成功）
  - 修复后含 unsafe、不支持值、历史数据库节点的多节点配置：通过
  - 15 个合法指纹：通过
  - 原有 6 种模式 × IPv6 组合：通过

## F. APK
- deliver/WQs-Proxy-VPN-1.1.1-arm64-v8a.apk，27,945,932 字节
- SHA-256：6417fdc3a2cae7f9764aa0d3ab836b1b75b9aebff9416530c7b1c00ae199a979
- 版本 1.1.1（versionCode 3），包名 dev.proxypilot.proxypilot_mobile，只含 arm64-v8a（libbox.so、libflutter.so、libapp.so、libdartjni.so）
- Manifest：ProxyVpnService exported=false，权限 BIND_VPN_SERVICE
- 签名：Android Debug，证书 SHA-256 8108…5cc6。**与 1.1.0（4300…0597）不同**：构建机家目录被重置，原 debug.keystore 丢失。安装 1.1.1 必须先卸载旧版。已把新 keystore 固定到 /workspace/tools/signing，后续版本会沿用

## G. 真机
- 未执行。构建环境没有设备或模拟器，Redmi K60 上的隧道建立和实际访问**未验证**

## H. 未完成与风险
- R1、R3 未实现，R2 的系统分享和二维码未做
- 阶段 3–5 只做了源码审查，未发现需要立刻修的缺陷：Manifest/服务声明正确；onRevoke 和 onDestroy 会清理资源；启动失败、校验失败、未授权分别有不同提示；日志统一经过 redact。切后台、网络切换、进程回收需要真机验证
- dedupKey 不包含 REALITY 公钥和 short_id，同一地址、端口、UUID 但 REALITY 参数不同的节点会被当成重复（待确认是否要改）
- 仍是 debug 签名

## I. 提交
- 见分支 fix/utls-fingerprint-1.1.1。未动 main，未发布 Release
