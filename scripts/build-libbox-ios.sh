#!/bin/bash
# 从 sing-box 源码用 SagerNet gomobile 编译 Libbox.xcframework（iOS）。
# 依赖 macOS + Xcode（gomobile 的 iOS 后端调用 xcrun）；CI 中由
# .github/workflows/ios.yml 在 macos-latest 上调用，本机有 Mac 也可直接跑。
#
# 参数与 sing-box 官方 cmd/internal/build_libbox -target apple 对齐：
#   - 官方构建不用 -javapkg（gomobile 对非 Android target 会直接报错退出）；
#   - tags 取官方 sharedTags + darwinTags + tailscale ts_omit_* 全集；
#   - -iosversion=15.0 与官方一致。
#
# 用法：
#   SINGBOX_SRC=/path/to/sing-box scripts/build-libbox-ios.sh
# 产物：ios/Libbox.xcframework（pbxproj 中以 ios/ 为相对路径引用）
set -euo pipefail

SRC=${SINGBOX_SRC:-/workspace/tools/sing-box-src}
OUT=${OUT:-$(cd "$(dirname "$0")/.." && pwd)/ios}
TARGET=${TARGET:-ios,iossimulator}
VER=${SINGBOX_VERSION:-$(cd "$SRC" && git describe --tags --abbrev=0 | sed 's/^v//')}
# 与 sing-box v1.14.3 cmd/internal/build_libbox buildApple() 完全一致的标签集
# 实测：该标签集生成的 ObjC 头文件与精简标签集逐字节一致，Swift 侧零改动
TAGS="with_gvisor,with_quic,with_wireguard,with_utls,with_naive_outbound,with_clash_api,with_usbip,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0,with_dhcp,grpcnotrace,with_tailscale,ts_omit_logtail,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird"

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
  -libname=box -iosversion=15.0 -trimpath -buildvcs=false \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=$VER -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid=" \
  -tags "$TAGS" ./experimental/libbox

ls -la "$OUT/Libbox.xcframework"
echo "TAGS=$TAGS TARGET=$TARGET VERSION=$VER"
