// SPDX-License-Identifier: GPL-3.0-or-later
// 主动测速（与 VPN 实时流量统计区分）。使用 Cloudflare 公开测速端点 speed.cloudflare.com，
// 限制数据量与时长；结果为真实测量值。

import 'dart:async';
import 'dart:io';
import 'dart:math';

class SpeedTestResult {
  SpeedTestResult({
    required this.server,
    required this.direction,
    required this.bytes,
    required this.ms,
    this.error,
  });
  final String server;
  final String direction; // 下载 / 上传
  final int bytes;
  final int ms;
  final String? error;
  double get bps => ms <= 0 ? 0 : bytes * 8000 / ms;
}

class SpeedTester {
  static const server = 'speed.cloudflare.com';
  static const maxBytes = 25 * 1000 * 1000; // 单次最多 25 MB
  static const maxDuration = Duration(seconds: 10);

  Future<SpeedTestResult> download({int bytes = 10 * 1000 * 1000}) async {
    final n = min(bytes, maxBytes);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final sw = Stopwatch();
    var got = 0;
    try {
      final req = await client.getUrl(
        Uri.https(server, '/__down', {'bytes': '$n'}),
      );
      final resp = await req.close();
      if (resp.statusCode != 200) {
        return SpeedTestResult(
          server: server,
          direction: '下载',
          bytes: 0,
          ms: 0,
          error: 'HTTP ${resp.statusCode}',
        );
      }
      sw.start();
      await for (final chunk in resp.timeout(maxDuration)) {
        got += chunk.length;
        if (sw.elapsed > maxDuration) break;
      }
      return SpeedTestResult(
        server: server,
        direction: '下载',
        bytes: got,
        ms: sw.elapsedMilliseconds,
      );
    } catch (e) {
      return SpeedTestResult(
        server: server,
        direction: '下载',
        bytes: got,
        ms: sw.elapsedMilliseconds,
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<SpeedTestResult> upload({int bytes = 5 * 1000 * 1000}) async {
    final n = min(bytes, maxBytes);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final sw = Stopwatch();
    try {
      final req = await client.postUrl(Uri.https(server, '/__up'));
      req.contentLength = n;
      req.headers.contentType = ContentType.binary;
      final chunk = List<int>.filled(64 * 1024, 0);
      sw.start();
      var sent = 0;
      while (sent < n) {
        final len = min(chunk.length, n - sent);
        req.add(len == chunk.length ? chunk : chunk.sublist(0, len));
        sent += len;
        await req.flush();
        if (sw.elapsed > maxDuration)
          throw TimeoutException('上传超时', maxDuration);
      }
      final resp = await req.close().timeout(maxDuration);
      await resp.drain<void>();
      final ms = sw.elapsedMilliseconds;
      if (resp.statusCode != 200)
        return SpeedTestResult(
          server: server,
          direction: '上传',
          bytes: 0,
          ms: ms,
          error: 'HTTP ${resp.statusCode}',
        );
      return SpeedTestResult(server: server, direction: '上传', bytes: n, ms: ms);
    } catch (e) {
      return SpeedTestResult(
        server: server,
        direction: '上传',
        bytes: 0,
        ms: sw.elapsedMilliseconds,
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }
}
