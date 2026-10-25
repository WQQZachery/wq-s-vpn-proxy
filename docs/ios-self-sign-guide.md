# WQs-Proxy-VPN iOS 自签安装使用指南

> 本文面向**不想支付 $99/年 Apple Developer Program** 的用户，如实说明三条可行路径的
> 能力边界、操作步骤与结论。所有结论均附 Apple 官方文档或生产级实证来源。

## 0. 结论速览（TL;DR）

| 路径 | 费用 | 有效期 | 需要 Apple ID | 支持 App 扩展（VPN 核心） | 结论 |
|---|---|---|---|---|---|
| A. 免费 Apple ID 自签（Xcode / AltStore / Sideloadly / 爱思助手） | 免费 | 7 天 | 是 | **否** ❌ | **本项目不可行**（原因见 §2） |
| B. TrollStore（巨魔商店） | 免费 | **永久** | **否** | 是 ✅ | **唯一可用的免费路径**（设备需 iOS ≤ 17.0） |
| C. GitHub Actions 构建未签名 IPA | 免费（公开仓库） | — | 否 | — | **IPA 的产出方式**，与 B 配合使用 |

**一句话**：用路径 C 拿到 `.ipa` 安装包 → 设备在 iOS 14.0–17.0 支持列表内时，用路径 B
（TrollStore）安装，永久有效、无需 Apple ID、VPN 扩展完整可用。

---

## 1. 先理解：为什么这个 App 有一个「扩展」

本项目的 iOS 版与 Android 版结构对齐，由两部分组成：

```
Runner.app（Flutter 界面）
└── PlugIns/PacketTunnelProvider.appex   ← Network Extension 扩展
```

- `Runner.app` 负责界面、配置管理、启停指令；
- `PacketTunnelProvider.appex` 是 `NEPacketTunnelProvider` 扩展，承载 sing-box 核心与
  TUN 隧道——**iOS 上所有 VPN App 都是这个结构**，扩展不是可选装饰，而是系统强制要求；
- 两者通过 **App Groups** 共享配置与状态（`SharedBridge`）。

这个结构决定了安装方式的硬约束：**必须为扩展单独签名并获得包含
Network Extension 能力的配置文件**，否则 VPN 无法工作。

---

## 2. 路径 A：免费 Apple ID 自签 —— 为什么不可行

### 2.1 操作步骤（可以走通，但结论是失败）

1. Apple ID 登录 Xcode（Xcode → Settings → Accounts，免费个人团队 Personal Team）；
2. 打开 `ios/Runner.xcworkspace`，Runner 与 PacketTunnelProvider 两个 Target 的
   Signing & Capabilities 中选择你的个人团队；
3. 连接设备，`flutter build ios` 或直接 Run。

### 2.2 卡点：Network Extensions 能力仅对付费会员开放

Apple 官方《Supported capabilities (iOS)》能力对照表
（<https://developer.apple.com/help/account/reference/supported-capabilities-ios>）明确列出：

| 能力 | ADP（$99/年） | 免费 Apple Developer |
|---|---|---|
| **Network extensions** | ✓ | **— 不支持** |
| **Personal VPN** | ✓ | **— 不支持** |
| App groups | ✓ | ✓（免费可用） |

也就是说：免费账号**能**签 App Groups（IPC 共享没问题），但**不能**为
`PacketTunnelProvider` 扩展创建带 Network Extension 能力的描述文件。实际表现：

- Xcode 报错 *"…does not support the Network Extensions capability"* 或
  无法为扩展 Bundle ID 生成 provisioning profile；
- 即便绕过签名把 App 装上，系统在 设置 → VPN 中也不会出现本 App 的配置项，
  或启动即失败。

AltStore / Sideloadly / ESign / 爱思助手等工具本质都是「免费证书 + 7 天重签」，
**同样受该能力表约束**，且 7 天到期需重签——对本项目是双重不可行。

> 附：免费 Apple ID 自签的其他通用限制（7 天有效期、同时最多 3 个自签应用、
> 证书可被 Apple 吊销），即使对普通 App 也只是「能用但烦」。

### 2.3 结论

**放弃路径 A。** 这不是配置问题，是 Apple 账号等级问题；要让它工作只能付 $99/年
（用户已明确不走此路）。

---

## 3. 路径 B：TrollStore —— 真正可用的免费路径

### 3.1 原理与特点

TrollStore（巨魔商店，<https://github.com/opa334/TrollStore>）利用特定 iOS 版本中的
CoreTrust 漏洞，**永久签名** IPA 并安装到 `/Applications`：

- **永久有效**：不依赖任何证书，没有 7 天重签、不怕 Apple 吊销证书；
- **无需 Apple ID**、无需电脑（安装初始化后）；
- **完整保留 entitlements**：安装的是整个 `.app`（含 `PlugIns/*.appex`），
  CoreTrust 绕过对主程序与扩展同时生效——**Network Extension 扩展可正常工作**。
  社区大量带扩展/插件的 App（如各类系统增强插件）长期以此方式运行。

### 3.2 设备前提（硬性）

TrollStore 依赖的漏洞已在 iOS 16.7 / 17.0.1 被苹果修复，**支持版本为最终清单**：

| 系统版本 | 是否支持 |
|---|---|
| iOS / iPadOS 14.0 beta 2 – 16.6.1 | ✅ |
| iOS 16.7 RC（build 20H18） | ✅ |
| **iOS 17.0（仅此一个 17.x）** | ✅ |
| iOS 17.0.1 及以后（含 18 / 26 等） | ❌ |

> 若设备已升级到不支持版本且无法降级，TrollStore 不可用；免费 Apple ID 又受
> §2 限制——这是当前 iOS 生态的客观现状，不存在绕过方案（除非购买 $99 账号）。

### 3.3 安装步骤

**第一步：安装 TrollStore**（一次性，随设备/系统版本不同方法略异）

1.  Safari 打开 <https://github.com/opa334/TrollStore>，按页面表格找到对应你机型的
    安装链接（常见方式：安装 `GTA Car Tracker` / `TrollInstallerX` 等助手 App）；
2.  若助手 App 是自签安装的：设置 → 通用 → VPN与设备管理 → 信任对应描述文件；
3.  打开助手 App，点击 `Install TrollStore`；部分机型要求先打开一次
    系统自带的「提示（Tips）」或「图书」App 完成刷入；
4.  桌面出现 TrollStore，首次打开会自动加载 `ldid`（关键组件，勿跳过）。

**第二步：安装本 App**

1.  获取 IPA（见 §4，推荐用 GitHub Actions 产物）；
2.  将 IPA 传到设备（Files / 网盘 / AirDrop 均可）；
3.  分享面板选择 **TrollStore** 打开，或 TrollStore 内 `+` 选择 IPA → `Install`；
4.  安装完成后像普通 App 一样打开。

**第三步：首次使用**

1.  设置 → 通用 → 关于 → 证书信任设置 无需操作（TrollStore 安装不受信任限制）；
2.  iOS 16+ 如需开发者模式：设置 → 隐私与安全性 → 开发者模式 → 打开并重启；
3.  打开 App → 导入配置 → 点击连接 → 系统弹出 VPN 授权时点 **允许** 并验证锁屏密码；
4.  状态栏出现 VPN 图标即成功。可在 设置 → VPN 中管理。

### 3.4 注意事项

- **升级系统会失去 TrollStore**（漏洞被后续版本修复），且无法降级。打算长期使用
  请勿轻易 OTA 升级；升级前确认目标版本不在支持列表。
- TrollStore 本身开源可审计，但 IPA 来源请只信任本仓库 CI 产物或你自己构建的包。
- 本 App 的「始终-on VPN / 按需连接」行为与普通 App Store VPN 完全一致
  （`NEAlwaysOnVPN`/`on-demand` 由系统托管）。

---

## 4. 路径 C：GitHub Actions 免费构建未签名 IPA（如何拿到安装包）

本仓库已内置 iOS CI（`.github/workflows/ios.yml`），**公开仓库的 GitHub Actions
（含 macOS 构建机）免费且不限分钟数**，无需本地 Mac 即可产出安装包。

### 4.1 一键构建

1.  在 GitHub 上 Fork 本仓库（或推送到你自己的公开仓库）；
2.  仓库页 → **Actions** → 左侧 `Build iOS IPA` → 右侧 `Run workflow`（手动触发，
    `sign` 参数保留默认 `no` 即可）；
3.  等待约 15–30 分钟，工作流自动完成：
    - 拉取 sing-box v1.14.3 源码；
    - `gomobile bind` 构建 `Libbox.xcframework`；
    - 跑工程与 API 静态校验（pbxproj 完整性 + Swift↔libbox 签名比对）；
    - `flutter build ios --release --no-codesign`；
    - 校验 `.appex` 与 xcframework 正确嵌入；
    - 打包 `WQs-Proxy-VPN-<版本>-unsigned.ipa` 并上传为 **Artifact**；
4.  在当次运行页下载 `WQs-Proxy-VPN-unsigned-ipa` 压缩包，解压得到 IPA。

### 4.2 发布 Release 时自动附带

若推送 `v*` Tag 或发布 Release，工作流会自动把同一个 IPA 上传到该 Release 页面。

### 4.3 这个 IPA 的用途与边界

| 安装方式 | 是否可用 |
|---|---|
| **TrollStore** | ✅ 直接安装（推荐，即 §3 步骤） |
| Xcode / AltStore / Sideloadly / 爱思助手 | ❌ 未签名 IPA 不能直接装；且免费证书同样卡在 Network Extensions 能力 |
| 企业签名 / 超级签名（第三方售卖） | ❌ 同样受 Network Extensions 能力表约束，除非购买 $99 ADP |

> 换言之：**CI 产出的未签名 IPA 就是为 TrollStore 准备的安装包**。这正是
> 「不走 $99 付费」路线下唯一闭环：免费构建 → 免费永久安装 → VPN 完整可用。

---

## 5. 常见问题（FAQ）

**Q1：iOS 17.0.1 / iOS 18 / iOS 26，完全没办法免费装吗？**
A：TrollStore 不支持这些版本，免费 Apple ID 无法签 Network Extension 扩展。
现实选项只有：换一台系统在支持列表内的旧设备、购买 $99 ADP、或等待新漏洞
（TrollStore 官方已表示支持清单为最终版，不建议抱期待）。

**Q2：TrollStore 装的 App 会被系统「撤销」吗？**
A：不会。撤销（revoke）是证书签名体系的概念；TrollStore 不经过证书体系。

**Q3：为什么 App 里连不上 / 设置里没有 VPN 配置？**
A：按顺序排查：① 是否用 TrollStore（而非自签）安装；② iOS 16+ 是否开启
开发者模式并重启；③ 首次连接时是否在系统弹窗点了「允许」；④ 查看 App 内
「日志」页（日志经 App Groups 从扩展实时读取，可定位 sing-box 启动错误）。

**Q4：7 天有效期是怎么回事？**
A：仅存在于路径 A（免费证书签名）。TrollStore 安装无此概念。

**Q5：能把这套流程搬到 Android 吗？**
A：Android 侧无任何签名限制，直接安装 APK 即可，与本指南无关。

---

## 6. 参考来源

- Apple Developer — Supported capabilities (iOS)（Network extensions / Personal VPN
  仅 ADP/ADEP 可用；App groups 免费可用）：
  <https://developer.apple.com/help/account/reference/supported-capabilities-ios>
- Apple Developer — Adding capabilities to your app：
  <https://developer.apple.com/documentation/xcode/adding-capabilities-to-your-app>
- TrollStore 官方仓库（支持版本、安装方法）：<https://github.com/opa334/TrollStore>
- sing-box for iOS（SFI，GPL-3.0，本 App 扩展实现的参考实现）：
  <https://github.com/SagerNet/sing-box-for-iOS>
- 本仓库 iOS CI 工作流：`.github/workflows/ios.yml`
