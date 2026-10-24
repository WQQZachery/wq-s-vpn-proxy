#!/usr/bin/env python3
"""本地无认证 HTTP 代理 → 上游带认证代理（Java/Gradle/sdkmanager 不支持 HTTPS 隧道 Basic 认证）。
凭据仅从环境变量 HTTPS_PROXY 读取，不打印。监听 127.0.0.1:3128。"""
import asyncio, base64, os, urllib.parse
u = urllib.parse.urlsplit(os.environ.get("HTTPS_PROXY") or os.environ["HTTP_PROXY"])
UP_HOST, UP_PORT = u.hostname, u.port or 80
AUTH = b""
if u.username:
    cred = f"{urllib.parse.unquote(u.username)}:{urllib.parse.unquote(u.password or '')}"
    AUTH = b"Proxy-Authorization: Basic " + base64.b64encode(cred.encode()) + b"\r\n"
async def pipe(r, w):
    try:
        while True:
            d = await r.read(65536)
            if not d: break
            w.write(d); await w.drain()
    except Exception: pass
    finally:
        try: w.close()
        except Exception: pass
async def handle(cr, cw):
    try:
        head = await cr.readuntil(b"\r\n\r\n")
    except Exception:
        cw.close(); return
    lines = head.split(b"\r\n")
    lines = [l for l in lines if not l.lower().startswith(b"proxy-authorization:")]
    req = lines[0] + b"\r\n" + AUTH + b"\r\n".join(lines[1:])
    try:
        ur, uw = await asyncio.open_connection(UP_HOST, UP_PORT)
    except Exception:
        cw.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n"); cw.close(); return
    uw.write(req); await uw.drain()
    await asyncio.gather(pipe(cr, uw), pipe(ur, cw))
async def main():
    s = await asyncio.start_server(handle, "127.0.0.1", 3128)
    async with s: await s.serve_forever()
asyncio.run(main())
