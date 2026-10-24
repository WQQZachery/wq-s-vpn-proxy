#!/usr/bin/env bash
# 若本地代理未运行则启动
if ! (exec 3<>/dev/tcp/127.0.0.1/3128) 2>/dev/null; then
  nohup python3 /workspace/tools/bin/auth-proxy.py >/tmp/auth-proxy.log 2>&1 &
  sleep 1
fi
