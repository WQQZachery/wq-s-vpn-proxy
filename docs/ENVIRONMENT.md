# 环境检查记录（2026-10-24，实测）

## 主机
- OS：Debian GNU/Linux 13 (trixie)，内核 6.12.110+，**aarch64**
- CPU 2 核，内存 7.8 GiB，无 swap
- 根分区 overlay 6.3G（可用 6.2G，可能非持久）；/workspace 为 JuiceFS 持久卷，空间充足
- 用户 sandbox(uid 1000)，sudo 可用
- 工作目录：/workspace/projects/c3ba56da-1bc1-4531-aee0-89238a5865eb；开始时仅有 work/proxypilot-spec.md，无既有项目文件

## 初始工具
- 仅有 git 2.47.3、python3、curl、unzip；Flutter/Dart/JDK/Gradle/Android SDK/Go/adb 均未安装

## 网络
- 出网经带认证的 HTTP 代理（HTTP(S)_PROXY）
- GitHub、dl.google.com、pub.dev、Maven Central、go.dev、proxy.golang.org 可达
- **storage.googleapis.com 返回 403** → Flutter 资源改用官方镜像 `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`
- Java（sdkmanager/Gradle）默认禁止对 HTTPS 隧道做 Basic 代理认证 → 增加本地转发代理 `scripts/auth-proxy.py`（127.0.0.1:3128，凭据仅从环境读取，不落盘不打印）
- `flutter doctor` 的 Network resources 检查报 github.com TLS 握手错误（Dart 未走认证代理所致），不影响 git/curl

## 已安装（/workspace/tools，见 scripts/setup-env.sh、env.sh）
| 工具 | 版本 | 说明 |
|---|---|---|
| JDK | Temurin 21.0.13 | 另有 apt openjdk-21 21.0.12 |
| Go | 1.27.3 | sing-box 1.14.3 CI 用 1.26.8，脚本已固定 1.26.8 供重装 |
| Flutter | 3.47.8 stable / Dart 3.13.7 | git clone，Dart SDK linux-arm64 |
| Android cmdline-tools | 20.0（14742923） | 最新版改为 x86_64 原生 `android` CLI，ARM64 报 Exec format error，故固定此版 |
| Android NDK | r28 (28.0.13004108) | 仅 linux-x86_64 预编译 |
| apt | clang 19.1.7、lld、cmake 3.31.6、ninja 1.12.1、qemu-user 10.0.13、aapt/aapt2 (Debian 1:14~beta1-3) | |

Flutter 3.47.8 默认 compileSdk 36、targetSdk 36、minSdk 24、NDK 28.2.13676358。

## 已知限制
- 官方 build-tools / NDK / platform-tools 均为 x86_64：aapt2 需覆盖为 ARM64 版或经 qemu-user 运行；gomobile 需要以 Debian clang + NDK sysroot 伪装 NDK 工具链。
- 无真机、无模拟器（ARM64 Linux 无官方模拟器，且无 KVM）：真实设备测试无法在此执行。
