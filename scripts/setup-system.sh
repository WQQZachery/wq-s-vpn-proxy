#!/bin/bash
# 根分区非持久：每次新会话需重跑（安装 ARM64 主机运行 x86_64 Android 工具所需的系统包）
set -e
sudo dpkg --add-architecture amd64
sudo apt-get update -qq
sudo apt-get install -y -qq clang lld cmake ninja-build qemu-user file zip xz-utils libc6:amd64 libstdc++6:amd64 zlib1g:amd64
# Flutter 只提供 linux-x64 的 Android gen_snapshot；为 linux-arm64 主机建 qemu 包装
for v in android-arm64-release android-arm64-profile android-arm-release android-arm-profile android-x64-release android-x64-profile; do
  d=/workspace/tools/flutter/bin/cache/artifacts/engine/$v
  [ -f "$d/linux-x64/gen_snapshot" ] || continue
  mkdir -p "$d/linux-arm64"
  printf '#!/bin/sh\nexec qemu-x86_64 -L / %s/linux-x64/gen_snapshot "$@"\n' "$d" > "$d/linux-arm64/gen_snapshot"
  chmod +x "$d/linux-arm64/gen_snapshot"
done
qemu-x86_64 -L / /workspace/tools/android-sdk/build-tools/36.0.0/aapt2 version
# NDK llvm-strip（x86_64）替换为 Debian llvm-19 包装，否则 .so 不会被裁剪
for n in /workspace/tools/android-sdk/ndk/*/toolchains/llvm/prebuilt/linux-x86_64/bin; do
  if [ -L "$n/llvm-strip" ]; then rm "$n/llvm-strip"; printf '#!/bin/sh\nexec /usr/lib/llvm-19/bin/llvm-strip "$@"\n' > "$n/llvm-strip"; chmod +x "$n/llvm-strip"; fi
done
# NDK clang/lld（x86_64）→ Debian llvm-19 包装（NDK r28 同为 clang 19），资源目录与 sysroot 仍用 NDK 自带
for N in /workspace/tools/android-sdk/ndk/*/toolchains/llvm/prebuilt/linux-x86_64; do
  B=$N/bin
  if ! grep -q llvm-19 "$B/clang-19" 2>/dev/null; then
    mv "$B/clang-19" "$B/clang-19.x86_64"
    cat > "$B/clang-19" <<W
#!/bin/sh
case "\$(basename "\$0")" in *++) M=--driver-mode=g++;; *) M=;; esac
exec /usr/lib/llvm-19/bin/clang \$M -resource-dir $N/lib/clang/19 --sysroot=$N/sysroot -fuse-ld=$B/ld.lld --rtlib=compiler-rt --unwindlib=libunwind -Qunused-arguments "\$@"
W
    chmod +x "$B/clang-19"
  fi
  if [ ! -e "$B/lld.x86_64" ]; then
    mv "$B/lld" "$B/lld.x86_64"
    printf '#!/bin/sh\nexec /usr/lib/llvm-19/bin/ld.lld "$@"\n' > "$B/lld"; chmod +x "$B/lld"
  fi
done

# Android SDK 自带的 cmake/ninja 只有 x86_64 版本；ARM64 主机改用 Debian 的 cmake/ninja（jni 插件的 CMake 构建需要）
${SUDO:-sudo} apt-get install -y cmake ninja-build >/dev/null
for d in /workspace/tools/android-sdk/cmake/*/bin; do
  [ -d "$d" ] || continue
  for t in cmake ninja; do
    [ -e "$d/$t.x86_64" ] || mv "$d/$t" "$d/$t.x86_64" 2>/dev/null || true
    ln -sf "$(command -v $t)" "$d/$t"
  done
done
${SUDO:-sudo} apt-get install -y libsqlite3-dev >/dev/null  # 单元测试用 sqflite_common_ffi（pubspec hooks: sqlite3 source=system）
