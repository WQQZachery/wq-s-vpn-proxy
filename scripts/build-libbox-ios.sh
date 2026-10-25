#!/bin/bash
# 从 sing-box 源码用 SagerNet gomobile 编译 Libbox.xcframework（iOS）。
# 依赖 macOS + Xcode（gomobile 的 iOS 后端调用 xcrun）；CI 中由
# .github/workflows/ios.yml 在 macos-latest 上调用，本机有 Mac 也可直接跑。
#
# 用法：
#   SINGBOX_SRC=/path/to/sing-box scripts/build-libbox-ios.sh
# 产物：ios/Libbox.xcframework（pbxproj 中以 ios/ 为相对路径引用）
set -euo pipefail

SRC=${SINGBOX_SRC:-/workspace/tools/sing-box-src}
OUT=${OUT:-$(cd "$(dirname "$0")/.." && pwd)/ios}
TARGET=${TARGET:-ios}
VER=${SINGBOX_VERSION:-$(cd "$SRC" && git describe --tags --abbrev=0 | sed 's/^v//')}
# 对齐 sing-box 上游 release/DEFAULT_BUILD_TAGS_OTHERS（v1.14.3）；
# 仅排除 with_naive_outbound（需 cronet 预编译库，上游 OTHERS 默认亦不含）
# 实测：扩展标签不改变 libbox ObjC API 头文件（gobind 输出与最小标签集逐字节一致）
TAGS="with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale,with_ccm,with_ocm,with_cloudflared,with_usbip,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0"

if [ ! -d "$SRC" ]; then
    echo "ERROR: sing-box 源码不存在: $SRC（先 git clone --branch v1.14.3 https://github.com/SagerNet/sing-box.git）" >&2
    exit 1
fi
if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: iOS 构建必须在 macOS 上执行（gomobile iOS 后端需要 xcrun）" >&2
    exit 1
fi

go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.13
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.13
export PATH="$(go env GOPATH)/bin:$PATH"
gomobile init

mkdir -p "$OUT"
cd "$SRC"
gomobile bind -v -o "$OUT/Libbox.xcframework" -target "$TARGET" \
  -javapkg=io.nekohasekai -libname=box -trimpath -buildvcs=false \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=$VER -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid=" \
  -tags "$TAGS" ./experimental/libbox

ls -la "$OUT/Libbox.xcframework"
echo "TAGS=$TAGS TARGET=$TARGET VERSION=$VER"
