// SPDX-License-Identifier: GPL-3.0-or-later
// Flutter ↔ Kotlin 通信。状态完全以原生层（真实 sing-box CommandServer 生命周期）上报为准。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/models.dart';

class EngineEvent {
  EngineEvent.state(this.state, this.message) : traffic = null;
  EngineEvent.traffic(this.traffic) : state = null, message = null;
  final VpnState? state;
  final String? message;
  final TrafficSnapshot? traffic;
}

class VpnEngine {
  VpnEngine({MethodChannel? method, EventChannel? events})
    : _m = method ?? const MethodChannel('proxypilot/vpn'),
      _e = events ?? const EventChannel('proxypilot/vpn_events');
  final MethodChannel _m;
  final EventChannel _e;

  static VpnState parseState(String? s) => switch (s) {
    'starting' => VpnState.starting,
    'started' => VpnState.started,
    'stopping' => VpnState.stopping,
    'error' => VpnState.error,
    _ => VpnState.stopped,
  };

  static EngineEvent? parseEvent(Object? raw) {
    if (raw is! Map) return null;
    switch (raw['type']) {
      case 'state':
        return EngineEvent.state(
          parseState(raw['state'] as String?),
          raw['message'] as String?,
        );
      case 'traffic':
        return EngineEvent.traffic(
          TrafficSnapshot(
            timestampMs: (raw['ts'] as num).toInt(),
            rxBytes: (raw['rx'] as num).toInt(),
            txBytes: (raw['tx'] as num).toInt(),
          ),
        );
    }
    return null;
  }

  Stream<EngineEvent> events() => _e
      .receiveBroadcastStream()
      .map(parseEvent)
      .where((e) => e != null)
      .cast<EngineEvent>();

  /// 请求系统 VPN 授权；已授权返回 true，用户拒绝返回 false。
  Future<bool> prepare() async =>
      (await _m.invokeMethod<bool>('prepare')) ?? false;

  /// 用 libbox 校验配置；返回 null 表示通过，否则为错误信息。
  Future<String?> checkConfig(String config) =>
      _m.invokeMethod<String>('checkConfig', {'config': config});

  Future<void> start({required String config, required String profileName}) =>
      _m.invokeMethod('start', {'config': config, 'name': profileName});

  Future<void> stop() => _m.invokeMethod('stop');

  Future<(VpnState, String?)> currentState() async {
    final r = await _m.invokeMapMethod<String, dynamic>('state');
    return (parseState(r?['state'] as String?), r?['message'] as String?);
  }

  Future<String> coreVersion() async =>
      (await _m.invokeMethod<String>('version')) ?? '未知';

  Future<String> exportLogs() async =>
      (await _m.invokeMethod<String>('logs')) ?? '';
}

/// sing-box Clash API 客户端（仅监听 127.0.0.1，带随机 secret），用于经代理的真实延迟测试。
class ClashApiClient {
  ClashApiClient({
    required this.port,
    required this.secret,
    this.timeout = const Duration(seconds: 10),
  });
  final int port;
  final String secret;
  final Duration timeout;

  /// 通过指定出站请求 [testUrl]，返回 sing-box 测得的延迟（ms）。失败抛出异常。
  Future<int> delay(
    String outboundTag, {
    String testUrl = 'https://www.gstatic.com/generate_204',
    int timeoutMs = 5000,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final uri = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: port,
        path: '/proxies/${Uri.encodeComponent(outboundTag)}/delay',
        queryParameters: {'url': testUrl, 'timeout': '$timeoutMs'},
      );
      final req = await client.getUrl(uri).timeout(timeout);
      req.headers.set('Authorization', 'Bearer $secret');
      final resp = await req.close().timeout(timeout);
      final body = await resp.transform(utf8.decoder).join().timeout(timeout);
      final j = jsonDecode(body);
      if (resp.statusCode == 200 && j is Map && j['delay'] is num)
        return (j['delay'] as num).toInt();
      final msg = j is Map ? (j['message'] ?? body) : body;
      throw HttpException('代理测试失败（HTTP ${resp.statusCode}）：$msg');
    } finally {
      client.close(force: true);
    }
  }

  /// 切换 selector 当前节点（不重启核心）。
  Future<void> select(String selectorTag, String outboundTag) async {
    final client = HttpClient();
    try {
      final req = await client
          .putUrl(
            Uri(
              scheme: 'http',
              host: '127.0.0.1',
              port: port,
              path: '/proxies/${Uri.encodeComponent(selectorTag)}',
            ),
          )
          .timeout(timeout);
      req.headers.set('Authorization', 'Bearer $secret');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'name': outboundTag}));
      final resp = await req.close().timeout(timeout);
      await resp.drain<void>();
      if (resp.statusCode != 204 && resp.statusCode != 200)
        throw HttpException('切换节点失败（HTTP ${resp.statusCode}）');
    } finally {
      client.close(force: true);
    }
  }
}

/// 简单并发限制器。
Future<List<R>> runLimited<T, R>(
  List<T> items,
  int concurrency,
  Future<R> Function(T) task,
) async {
  final results = List<R?>.filled(items.length, null);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      results[i] = await task(items[i]);
    }
  }

  await Future.wait(
    List.generate(
      concurrency.clamp(1, items.isEmpty ? 1 : items.length),
      (_) => worker(),
    ),
  );
  return results.cast<R>();
}
