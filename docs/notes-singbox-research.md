# sing-box 调查笔记（2026-10-24，实际查询结果）

- 当前稳定版：v1.14.3（GitHub release，2026-10-09 发布）；预发布 v1.15.0-alpha.12。
- 官方源码已浅克隆到 /workspace/tools/sing-box-src（tag v1.14.3），go.mod 要求 go 1.25.5。
- 官方 Android 集成：`make lib_android` → `go run ./cmd/internal/build_libbox -target android`，
  使用 SagerNet 的 gomobile 分支（`make lib_install` 安装 github.com/sagernet/gomobile v0.1.13 的 gomobile/gobind），
  `-javapkg=io.nekohasekai`，主变体 `-androidapi 24`，legacy 变体 API 21。
  默认 tags 含 with_gvisor,with_quic,with_wireguard,with_utls,with_naive_outbound,with_clash_api,with_tailscale 等；
  with_naive_outbound 依赖 cronet 预编译库，本项目可考虑去掉 naive 与 tailscale 以降低构建难度和体积（需在文档中写明不支持的协议）。
- Release 资产中没有单独的 libbox.aar，只有 SFA APK 和 android CLI tar.gz（sing-box-1.14.3-android-arm64.tar.gz 等）。
- 许可证：LICENSE 为 GPL-3.0-or-later，并附加条款：
  "In addition, no derivative work may use the name or imply association with this application without prior consent."
  GitHub API 因附加条款将其识别为 NOASSERTION。分发含 libbox 的 APK 需整体按 GPL-3.0 提供对应源码，
  且应用名称/宣传不得使用 sing-box 名称或暗示关联（仅在许可证/致谢中如实列出依赖）。
- 已通过 apt 安装（系统级）：openjdk-21-jdk-headless 21.0.12、clang 19、lld、qemu-user 10.0.13、aapt（含 /usr/bin/aapt2，版本 1:14~beta1-3，需验证与 AGP 是否兼容）、cmake、ninja-build、xz-utils、zip、file。
- 环境中 Flutter 首次拉取 Dart SDK（linux-arm64）时下载到 111 字节的错误文件，解压失败，需重试或检查 storage.googleapis.com 可达性（直接请求 releases_linux.json 返回 403）。
