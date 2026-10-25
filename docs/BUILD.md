# 构建说明

## 版本

| 组件 | 版本 |
|---|---|
| Flutter / Dart | 3.47.8 / 3.13.7 |
| JDK | Temurin 21.0.13 |
| Android SDK | platform 36（AGP 另会自动装 35），build-tools 36 |
| NDK | 28.2.13676358 |
| Go | 1.27.3 |
| gomobile | sagernet/gomobile v0.1.13（脚本内打补丁） |
| sing-box | 1.14.3 |
| minSdk / ABI | 24 / 仅 arm64-v8a |

## 常规 x86_64 Linux/macOS 主机

```bash
flutter pub get
bash scripts/build-libbox.sh          # 生成 android/app/libs/libbox.aar（约 20 MB）
flutter test
flutter build apk --release --target-platform android-arm64 \
  --dart-define=ABUSEIPDB_DEFAULT_KEY="$(cat /path/to/abuseipdb.key)"   # 可选：内置默认 AbuseIPDB Key，不写入源码
# 输出：build/app/outputs/flutter-apk/app-release.apk
```

x86_64 主机上 `build-libbox.sh` 中针对 ARM64 的 NDK 包装步骤会被跳过（官方 NDK 原生可用）。

## ARM64 Linux 主机（本次实际构建环境：Debian 13 aarch64）

官方 Android 工具链大量组件只有 x86_64 版本，需要先执行：

```bash
source /workspace/tools/env.sh          # 代理、JAVA_HOME、ANDROID_HOME 等
bash scripts/setup-system.sh            # 需 sudo
```

该脚本做的事：
- 安装 qemu-user、clang/lld（llvm-19）、amd64 运行库、cmake、ninja、libsqlite3-dev；
- 用 qemu 包装 Flutter 的 `gen_snapshot`（release AOT）和 build-tools 的 `aapt2`；
- 把 NDK 的 clang/lld/strip 换成 Debian llvm-19 包装；
- 把 SDK cmake/ninja 换成 Debian 版（`jni` 插件需要）。

> 根分区在本环境中会被重置，新会话需重新运行 `setup-system.sh`。

单元测试需要访问本地回环，若设置了 HTTP 代理须同时设置 `NO_PROXY=127.0.0.1,localhost`。`config_test.dart` 会调用宿主机 `sing-box check` 真实校验生成的配置，路径由 `--dart-define=SING_BOX_BIN=...` 指定（默认 `/workspace/tools/bin/sing-box`，未找到则跳过并在报告中显示 skipped）。

## 签名

当前 release 使用 Flutter 模板的 **debug 签名**，只适合自测安装，不适合发布。发布前需自建 keystore 并在 `android/app/build.gradle.kts` 配置 `signingConfigs`。

## libbox 编译选项

`scripts/build-libbox.sh` tags：`with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,badlinkname,tfogo_checklinkname0`。
未编入：Naive、Tailscale、USB/IP、OpenVPN、OpenConnect。修改 tags 时须同步修改应用支持的协议列表与 `THIRD_PARTY_NOTICES.md`。
