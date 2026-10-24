#!/usr/bin/env bash
# WQ's Proxy VPN 开发环境安装脚本（Debian 13 aarch64，幂等，可重复运行）
set -euo pipefail
T=${TOOLS_DIR:-/workspace/tools}
mkdir -p "$T"; cd "$T"
echo "== apt 包 =="
sudo apt-get install -y -qq clang lld qemu-user unzip zip xz-utils curl file >/dev/null 2>&1 || echo "apt 安装失败（继续）"
echo "== JDK 21 (Temurin aarch64) =="
if [ ! -x "$T/jdk/bin/java" ]; then
  curl -fsSL -o jdk.tgz "https://api.adoptium.net/v3/binary/latest/21/ga/linux/aarch64/jdk/hotspot/normal/eclipse"
  mkdir -p jdk && tar xzf jdk.tgz -C jdk --strip-components=1 && rm jdk.tgz
fi
"$T/jdk/bin/java" -version
echo "== Go =="
GOV=${GO_VERSION:-go1.26.8}  # 与 sing-box v1.14.3 官方 CI 一致
if [ ! -x "$T/go/bin/go" ]; then
  curl -fsSL -o go.tgz "https://go.dev/dl/${GOV}.linux-arm64.tar.gz" && tar xzf go.tgz && rm go.tgz
fi
"$T/go/bin/go" version
echo "== Flutter stable (git) =="
if [ ! -d "$T/flutter/.git" ]; then
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$T/flutter"
fi
export PATH="$T/flutter/bin:$PATH"
flutter --disable-analytics >/dev/null 2>&1 || true
flutter --version
echo "== Android cmdline-tools =="
export ANDROID_HOME="$T/android-sdk"
if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  URL=commandlinetools-linux-14742923_latest.zip  # 固定：更新版改为 x86_64 原生 android CLI，ARM64 无法运行
  curl -fsSL -o clt.zip "https://dl.google.com/android/repository/$URL"
  unzip -q -o clt.zip -d "$ANDROID_HOME/cmdline-tools" && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" && rm clt.zip
fi
export JAVA_HOME="$T/jdk"
yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --proxy=http --proxy_host=127.0.0.1 --proxy_port=3128 "platforms;android-36" "build-tools;36.0.0" "build-tools;35.0.0" "platform-tools" 2>&1 | tail -3
echo "== 完成 =="
# 本环境 TLS 经自定义 CA（SSL_CERT_FILE）→ 生成 Java truststore
if [ -n "${SSL_CERT_FILE:-}" ] && [ ! -f "$T/truststore.jks" ]; then
  d=$(mktemp -d); (cd "$d" && csplit -s -z -f c "$SSL_CERT_FILE" '/-----BEGIN CERTIFICATE-----/' '{*}')
  i=0; for f in "$d"/c*; do "$T/jdk/bin/keytool" -importcert -noprompt -keystore "$T/truststore.jks" -storepass changeit -alias ca$i -file "$f" >/dev/null 2>&1 && i=$((i+1)); done; rm -rf "$d"
fi
