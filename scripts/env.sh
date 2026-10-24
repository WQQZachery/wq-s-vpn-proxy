export TOOLS_DIR=/workspace/tools
export JAVA_HOME=$TOOLS_DIR/jdk
export ANDROID_HOME=$TOOLS_DIR/android-sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME
export GOROOT=$TOOLS_DIR/go
export GOPATH=$TOOLS_DIR/gopath
export PUB_CACHE=$TOOLS_DIR/pub-cache
export GRADLE_USER_HOME=$TOOLS_DIR/gradle-home
export PATH=$TOOLS_DIR/flutter/bin:$JAVA_HOME/bin:$GOROOT/bin:$GOPATH/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn  # storage.googleapis.com 在本环境返回 403
# Java/Gradle 无法对上游代理做 HTTPS 隧道 Basic 认证 → 走本地转发代理 127.0.0.1:3128
/workspace/tools/bin/start-proxy.sh
export JAVA_TOOL_OPTIONS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=3128 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=3128 -Dhttp.nonProxyHosts=localhost|127.0.0.1 -Djavax.net.ssl.trustStore=/workspace/tools/truststore.jks -Djavax.net.ssl.trustStorePassword=changeit"
