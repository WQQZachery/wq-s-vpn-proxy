#!/bin/sh
# ARM64 主机：通过 qemu-user 运行官方 x86_64 aapt2（需 libc6:amd64、libstdc++6:amd64）
exec /usr/bin/qemu-x86_64 -L / /workspace/tools/android-sdk/build-tools/36.0.0/aapt2 "$@"
