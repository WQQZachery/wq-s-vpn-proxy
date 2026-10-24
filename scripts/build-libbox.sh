#!/bin/bash
# 从 sing-box 源码用 SagerNet gomobile 编译 libbox.aar（参照官方 cmd/internal/build_libbox，
# 但直接调用 gomobile：官方工具强制 openjdk 17，本环境为 JDK 21）。
# 裁剪：不含 with_naive_outbound（需 cronet 预编译库）、tailscale/usbip/openvpn/openconnect。
set -euo pipefail
source /workspace/tools/env.sh >/dev/null 2>&1 || true
SRC=${SINGBOX_SRC:-/workspace/tools/sing-box-src}
OUT=${OUT:-$(cd "$(dirname "$0")/.." && pwd)/android/app/libs}
TARGET=${TARGET:-android/arm64}
VER=$(cd "$SRC" && git describe --tags --abbrev=0 | sed 's/^v//')
TAGS="with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,badlinkname,tfogo_checklinkname0"
export ANDROID_NDK_HOME=${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/28.2.13676358}
# gomobile 在 linux/arm64 主机上 archNDK() 直接 panic；拷贝源码打补丁：linux-arm64 也使用 NDK 的 linux-x86_64 目录
# （该目录中的 clang/lld 已由 setup-system.sh 替换为 Debian llvm-19 包装）
go mod download github.com/sagernet/gomobile@v0.1.13
GM=/workspace/tools/gomobile-src; rm -rf "$GM"; cp -r "$(go env GOMODCACHE)/github.com/sagernet/gomobile@v0.1.13" "$GM"; chmod -R u+w "$GM"
sed -i 's/if runtime.GOOS == "darwin" {/if runtime.GOOS == "darwin" || runtime.GOOS == "linux" {/' "$GM/cmd/gomobile/env.go"
(cd "$GM" && go build -o "$(go env GOPATH)/bin/gomobile" ./cmd/gomobile)
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.13
export PATH="$(go env GOPATH)/bin:$PATH"
mkdir -p "$OUT"
cd "$SRC"
gomobile bind -v -o "$OUT/libbox.aar" -target "$TARGET" -androidapi 24 \
  -javapkg=io.nekohasekai -libname=box -trimpath -buildvcs=false \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=$VER -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid=" \
  -tags "$TAGS" ./experimental/libbox
ls -la "$OUT/libbox.aar"
echo "TAGS=$TAGS TARGET=$TARGET VERSION=$VER"
