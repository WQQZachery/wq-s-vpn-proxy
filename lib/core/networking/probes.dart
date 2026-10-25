// SPDX-License-Identifier: GPL-3.0-or-later
// 本地网络检测：DNS / TCP / TLS / HTTPS，均为真实执行，统一返回 ProbeResult。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/models.dart';

/// 错误分类（纯函数，便于单元测试）。
ProbeErrorKind classifyError(Object e) {
  if (e is TimeoutException) return ProbeErrorKind.timeout;
  if (e is HandshakeException) {
    final m = e.toString();
    if (m.contains('CERTIFICATE') || m.contains('certificate'))
      return ProbeErrorKind.certificateError;
    return ProbeErrorKind.tlsError;
  }
  if (e is TlsException) return ProbeErrorKind.tlsError;
  if (e is SocketException) {
    final code = e.osError?.errorCode;
    final msg = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    if (msg.contains('failed host lookup') ||
        msg.contains('no address associated') ||
        msg.contains('name or service not known')) {
      return ProbeErrorKind.dnsError;
    }
    // Linux/Android errno: 111 ECONNREFUSED, 110 ETIMEDOUT, 101 ENETUNREACH, 113 EHOSTUNREACH
    if (code == 111 || msg.contains('connection refused'))
      return ProbeErrorKind.connectionRefused;
    if (code == 110 || msg.contains('timed out')) return ProbeErrorKind.timeout;
    if (code == 101 || code == 113 || msg.contains('unreachable'))
      return ProbeErrorKind.networkUnreachable;
    return ProbeErrorKind.unknown;
  }
  if (e is HttpException) return ProbeErrorKind.protocolError;
  if (e is FormatException) return ProbeErrorKind.protocolError;
  return ProbeErrorKind.unknown;
}

String describeError(Object e) {
  if (e is SocketException)
    return '${e.message}${e.osError != null ? '（${e.osError!.message}）' : ''}';
  if (e is TimeoutException)
    return '超过 ${e.duration?.inMilliseconds ?? '?'} ms 未完成';
  return e.toString();
}

class HttpTiming {
  HttpTiming({
    required this.status,
    required this.headers,
    required this.body,
    required this.ms,
  });
  final int status;
  final Map<String, String> headers;
  final String body;
  final int ms;
}

class NetworkProbes {
  NetworkProbes({
    this.timeout = const Duration(seconds: 8),
    this.methodLabel = '直连',
  });
  final Duration timeout;

  /// 由调用方根据 VPN 状态填写，例如“直连（VPN 未开启）”或“经 VPN 隧道（节点 xxx）”。
  final String methodLabel;

  Future<ProbeResult> fullCheck(
    Uri url, {
    String kind = 'https',
    Map<String, String>? headers,
  }) async {
    final sw = Stopwatch()..start();
    final steps = <ProbeStep>[];
    final host = url.host;
    final port = url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80);
    ProbeResult fail(Object e, {int? http}) => ProbeResult(
      kind: kind,
      target: '${url.scheme}://$host${url.path}',
      method: methodLabel,
      status: steps.any((s) => s.ok)
          ? ProbeStatus.partial
          : ProbeStatus.failure,
      timestamp: DateTime.now(),
      totalMs: sw.elapsedMilliseconds,
      errorKind: classifyError(e),
      errorMessage: describeError(e),
      httpStatus: http,
      steps: steps,
    );

    // 1. DNS
    List<InternetAddress> addrs;
    final t0 = sw.elapsedMilliseconds;
    try {
      addrs = await InternetAddress.lookup(host).timeout(timeout);
      steps.add(
        ProbeStep(
          name: 'DNS 解析',
          ok: true,
          durationMs: sw.elapsedMilliseconds - t0,
          detail: addrs.map((a) => a.address).take(4).join(', '),
        ),
      );
    } catch (e) {
      steps.add(
        ProbeStep(
          name: 'DNS 解析',
          ok: false,
          durationMs: sw.elapsedMilliseconds - t0,
          detail: describeError(e),
        ),
      );
      return fail(
        e is SocketException ? SocketException('Failed host lookup: $host') : e,
      );
    }

    // 2. TCP
    final t1 = sw.elapsedMilliseconds;
    Socket sock;
    try {
      sock = await Socket.connect(addrs.first, port, timeout: timeout);
      steps.add(
        ProbeStep(
          name: 'TCP 连接',
          ok: true,
          durationMs: sw.elapsedMilliseconds - t1,
          detail: '${addrs.first.address}:$port',
        ),
      );
    } catch (e) {
      steps.add(
        ProbeStep(
          name: 'TCP 连接',
          ok: false,
          durationMs: sw.elapsedMilliseconds - t1,
          detail: describeError(e),
        ),
      );
      return fail(e);
    }

    // 3. TLS（使用系统证书校验，不做任何绕过）
    if (url.scheme == 'https') {
      final t2 = sw.elapsedMilliseconds;
      try {
        final secure = await SecureSocket.secure(
          sock,
          host: host,
        ).timeout(timeout);
        final cert = secure.peerCertificate;
        steps.add(
          ProbeStep(
            name: 'TLS 握手',
            ok: true,
            durationMs: sw.elapsedMilliseconds - t2,
            detail:
                '${secure.selectedProtocol ?? ''} 证书主体：${cert?.subject ?? '?'}',
          ),
        );
        secure.destroy();
      } catch (e) {
        steps.add(
          ProbeStep(
            name: 'TLS 握手',
            ok: false,
            durationMs: sw.elapsedMilliseconds - t2,
            detail: describeError(e),
          ),
        );
        sock.destroy();
        return fail(e);
      }
    } else {
      sock.destroy();
    }

    // 4. HTTP(S) 请求
    final t3 = sw.elapsedMilliseconds;
    try {
      final r = await httpGet(url, headers: headers);
      steps.add(
        ProbeStep(
          name: 'HTTP 请求',
          ok: true,
          durationMs: sw.elapsedMilliseconds - t3,
          detail: 'HTTP ${r.status}',
        ),
      );
      return ProbeResult(
        kind: kind,
        target: '${url.scheme}://$host${url.path}',
        method: methodLabel,
        status: ProbeStatus.success,
        timestamp: DateTime.now(),
        totalMs: sw.elapsedMilliseconds,
        httpStatus: r.status,
        steps: steps,
        data: {
          'headers': _pickHeaders(r.headers),
          'bodySnippet': r.body.length > 600
              ? r.body.substring(0, 600)
              : r.body,
        },
      );
    } catch (e) {
      steps.add(
        ProbeStep(
          name: 'HTTP 请求',
          ok: false,
          durationMs: sw.elapsedMilliseconds - t3,
          detail: describeError(e),
        ),
      );
      return fail(e);
    }
  }

  static Map<String, String> _pickHeaders(Map<String, String> h) {
    const keep = [
      'server',
      'cf-ray',
      'cf-mitigated',
      'content-type',
      'location',
      'x-request-id',
      'retry-after',
    ];
    return {
      for (final k in keep)
        if (h[k] != null) k: h[k]!,
    };
  }

  Future<HttpTiming> httpGet(
    Uri url, {
    Map<String, String>? headers,
    int maxBody = 64 * 1024,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = 'WQsProxyVPN/1.2.0';
    final sw = Stopwatch()..start();
    try {
      final req = await client.getUrl(url).timeout(timeout);
      headers?.forEach(req.headers.set);
      req.followRedirects = false;
      final resp = await req.close().timeout(timeout);
      final buf = <int>[];
      await for (final chunk in resp.timeout(timeout)) {
        if (buf.length < maxBody) buf.addAll(chunk);
      }
      final h = <String, String>{};
      resp.headers.forEach((k, v) => h[k.toLowerCase()] = v.join(', '));
      return HttpTiming(
        status: resp.statusCode,
        headers: h,
        body: utf8.decode(buf, allowMalformed: true),
        ms: sw.elapsedMilliseconds,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 仅测 TCP 端口连通（用于 VPN 未开启时的节点检查；不代表代理协议可用）。
  Future<int> tcpPing(String host, int port) async {
    final sw = Stopwatch()..start();
    final s = await Socket.connect(host, port, timeout: timeout);
    final ms = sw.elapsedMilliseconds;
    s.destroy();
    return ms;
  }

  /// TLS 握手（严格校验证书，不允许跳过）。返回握手耗时 ms。只证明 TLS 端点正常，不代表代理认证可用。
  Future<int> tlsHandshake(String host, int port, {String? serverName}) async {
    final sw = Stopwatch()..start();
    final raw = await Socket.connect(host, port, timeout: timeout);
    try {
      final sni = (serverName == null || serverName.isEmpty) ? host : serverName;
      final s = await SecureSocket.secure(
        raw,
        host: sni,
        onBadCertificate: (_) => false,
      ).timeout(timeout);
      final ms = sw.elapsedMilliseconds;
      s.destroy();
      return ms;
    } catch (_) {
      raw.destroy();
      rethrow;
    }
  }
}

/// Cloudflare 检测结论：区分服务可达 / 目标响应 / 挑战。
String cloudflareConclusion(ProbeResult r) {
  if (r.status == ProbeStatus.failure)
    return '无法到达 Cloudflare 边缘（${r.errorKind.label}）';
  if (r.status == ProbeStatus.partial)
    return '网络部分可达，但请求未完成（${r.errorKind.label}）';
  final headers =
      (r.data['headers'] as Map?)?.cast<String, String>() ?? const {};
  final mitigated = headers['cf-mitigated'];
  final body = (r.data['bodySnippet'] as String?) ?? '';
  if (mitigated == 'challenge' ||
      body.contains('challenge-platform') ||
      body.contains('cf-chl')) {
    return 'Cloudflare 边缘可达，但目标返回网页挑战（HTTP ${r.httpStatus}）；本检测无法证明挑战可通过';
  }
  if (headers['cf-ray'] != null) {
    return 'Cloudflare 边缘可达（cf-ray ${headers['cf-ray']}），目标响应 HTTP ${r.httpStatus}；未检测到挑战标记，但这不代表浏览器访问一定无挑战';
  }
  return '目标响应 HTTP ${r.httpStatus}，未见 Cloudflare 响应头（目标可能未使用 Cloudflare）';
}

/// Claude 检测结论：只证明网络/服务层面，绝不宣称账户可用。
String claudeConclusion(ProbeResult r) {
  if (r.status != ProbeStatus.success)
    return '网络不可达或请求未完成（${r.errorKind.label}）；账户认证与可用性：未检测';
  final code = r.httpStatus ?? 0;
  final headers =
      (r.data['headers'] as Map?)?.cast<String, String>() ?? const {};
  if (headers['cf-mitigated'] == 'challenge')
    return '网络可达，但被 Cloudflare 挑战拦截（HTTP $code）；账户认证与可用性：未检测';
  if (code == 401 || code == 405 || code == 404) {
    return '网络可达，服务有响应（HTTP $code，未携带凭据时的预期返回）；账户认证：未执行；账户实际可用：未检测';
  }
  if (code == 403) return '网络可达，但服务拒绝访问（HTTP 403，可能为地区或出口 IP 限制）；账户认证与可用性：未检测';
  if (code >= 500) return '网络可达，服务端错误（HTTP $code）；账户认证与可用性：未检测';
  return '网络可达，服务响应 HTTP $code；账户认证：未执行；账户实际可用：未检测';
}
