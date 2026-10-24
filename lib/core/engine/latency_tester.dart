// SPDX-License-Identifier: GPL-3.0-or-later
// 节点延迟检测调度器（纯 Dart，可单测）。
//
// 检测分层（结果中明确标注，绝不把低层成功说成节点可用）：
//   tcp   —— 仅 TCP 端口可达（VPN 未开启时）。只说明服务器端口在监听。
//   tls   —— TCP 可达且 TLS 握手成功、证书校验通过（非 REALITY 的 TLS 节点）。仍不代表代理认证可用。
//   proxy —— 经 sing-box 内核用该节点实际发起 HTTP 请求（VPN 开启时，Clash API /delay）。这才代表节点可用。
//
// 调度：并发上限 + 启动错峰；同一节点同一时刻只会有一个检测；重复触发会复用正在进行的任务；
// 自动检测带冷却时间；支持取消（排队中的任务立即取消，进行中的任务有超时上限，结果仍按真实返回记录）。

import 'dart:async';
import 'dart:collection';

enum LatencyLayer { tcp, tls, proxy }

extension LatencyLayerX on LatencyLayer {
  String get label => switch (this) {
    LatencyLayer.tcp => '仅 TCP',
    LatencyLayer.tls => 'TLS 握手',
    LatencyLayer.proxy => '代理请求',
  };

  String get explain => switch (this) {
    LatencyLayer.tcp => '只验证了服务器端口可连通，不代表代理协议或账号可用',
    LatencyLayer.tls => '端口可连通且 TLS 证书校验通过，但未验证代理认证',
    LatencyLayer.proxy => '经 sing-box 内核用该节点实际完成了一次 HTTP 请求',
  };

  static LatencyLayer? parse(String? s) => switch (s) {
    'tcp' => LatencyLayer.tcp,
    'tls' => LatencyLayer.tls,
    'proxy' => LatencyLayer.proxy,
    _ => null,
  };
}

enum LatencyStatus {
  queued,
  testing,
  ok,
  timeout,
  failed,
  unsupported,
  cancelled,
}

/// 单次探测结果（由探测函数返回）。
class ProbeOutcome {
  const ProbeOutcome.ok(this.ms, this.layer)
    : status = LatencyStatus.ok,
      error = null;
  const ProbeOutcome.timeout(this.layer, [this.error])
    : status = LatencyStatus.timeout,
      ms = null;
  const ProbeOutcome.failed(this.layer, this.error)
    : status = LatencyStatus.failed,
      ms = null;
  const ProbeOutcome.unsupported(this.error)
    : status = LatencyStatus.unsupported,
      ms = null,
      layer = null;
  final LatencyStatus status;
  final int? ms;
  final LatencyLayer? layer;
  final String? error;
}

/// 本次会话内某节点的检测状态。
class LatencyEntry {
  const LatencyEntry({
    required this.status,
    this.ms,
    this.layer,
    this.error,
    this.at,
  });
  final LatencyStatus status;
  final int? ms;
  final LatencyLayer? layer;
  final String? error;
  final DateTime? at;

  bool get busy =>
      status == LatencyStatus.queued || status == LatencyStatus.testing;
  bool get done =>
      status == LatencyStatus.ok ||
      status == LatencyStatus.timeout ||
      status == LatencyStatus.failed ||
      status == LatencyStatus.unsupported;

  factory LatencyEntry.from(ProbeOutcome o, DateTime at) => LatencyEntry(
    status: o.status,
    ms: o.ms,
    layer: o.layer,
    error: o.error,
    at: at,
  );
}

typedef LatencyProbe = Future<ProbeOutcome> Function(String nodeId);

class LatencyScheduler {
  LatencyScheduler({
    required this.probe,
    required this.onChange,
    this.concurrency = 4,
    this.stagger = const Duration(milliseconds: 60),
    this.autoCooldown = const Duration(seconds: 30),
    this.freshFor = const Duration(minutes: 2),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final LatencyProbe probe;
  final void Function(Map<String, LatencyEntry> entries) onChange;
  final int concurrency;
  final Duration stagger;
  final Duration autoCooldown;

  /// 本次会话内检测结果的“新鲜”期：自动检测会跳过仍新鲜的节点。
  final Duration freshFor;
  final DateTime Function() _now;

  final Map<String, LatencyEntry> _entries = {};
  final Queue<String> _queue = Queue();
  final Set<String> _inFlight = {};
  int _workers = 0;
  DateTime? _lastAuto;
  Completer<void>? _idle;

  Map<String, LatencyEntry> get entries => Map.unmodifiable(_entries);
  bool get running => _queue.isNotEmpty || _inFlight.isNotEmpty;
  int get pending => _queue.length + _inFlight.length;

  /// 进入节点页时调用。冷却期内重复进入不会重复发起；仍新鲜的结果直接复用。
  /// 返回实际加入队列的节点数。
  int autoRun(List<String> ids) {
    final now = _now();
    if (_lastAuto != null && now.difference(_lastAuto!) < autoCooldown) {
      return 0;
    }
    _lastAuto = now;
    final stale = ids.where((id) {
      final e = _entries[id];
      if (e == null || e.status == LatencyStatus.cancelled) return true;
      if (e.busy) return false;
      return e.at == null || now.difference(e.at!) > freshFor;
    }).toList();
    return enqueue(stale);
  }

  /// 手动（重新）检测：忽略新鲜度，但正在排队/检测的节点不会重复加入。
  int enqueue(List<String> ids) {
    var added = 0;
    for (final id in ids) {
      if (_inFlight.contains(id) || _queue.contains(id)) continue;
      _queue.add(id);
      _entries[id] = LatencyEntry(
        status: LatencyStatus.queued,
        ms: _entries[id]?.ms,
        layer: _entries[id]?.layer,
      );
      added++;
    }
    if (added > 0) {
      _emit();
      _pump();
    }
    return added;
  }

  /// 取消：排队中的立即标记为已取消；进行中的探测有自身超时，完成后仍记录真实结果。
  void cancel() {
    if (_queue.isEmpty) return;
    for (final id in _queue) {
      _entries[id] = const LatencyEntry(status: LatencyStatus.cancelled);
    }
    _queue.clear();
    _lastAuto = null; // 取消后允许再次自动检测
    _emit();
    _checkIdle();
  }

  /// 节点被删除或列表变化时清理无关条目。
  void retain(Set<String> ids) {
    _entries.removeWhere((k, _) => !ids.contains(k));
    _queue.removeWhere((k) => !ids.contains(k));
  }

  /// 网络环境变化（如 VPN 连接/断开）后，旧结果的检测层级已不适用：清空会话结果。
  void invalidate() {
    _entries.removeWhere((_, e) => !e.busy);
    _lastAuto = null;
    _emit();
  }

  /// 等待当前所有任务结束（测试用）。
  Future<void> whenIdle() {
    if (!running) return Future.value();
    return (_idle ??= Completer<void>()).future;
  }

  void _pump() {
    while (_workers < concurrency && _queue.isNotEmpty) {
      final delay = stagger * _workers;
      _workers++;
      unawaited(_worker(delay));
    }
  }

  Future<void> _worker(Duration initialDelay) async {
    if (initialDelay > Duration.zero) await Future<void>.delayed(initialDelay);
    while (_queue.isNotEmpty) {
      final id = _queue.removeFirst();
      _inFlight.add(id);
      _entries[id] = LatencyEntry(
        status: LatencyStatus.testing,
        ms: _entries[id]?.ms,
        layer: _entries[id]?.layer,
      );
      _emit();
      ProbeOutcome o;
      try {
        o = await probe(id);
      } catch (e) {
        o = ProbeOutcome.failed(null, '$e');
      }
      _inFlight.remove(id);
      _entries[id] = LatencyEntry.from(o, _now());
      _emit();
    }
    _workers--;
    _checkIdle();
  }

  void _checkIdle() {
    if (!running && _idle != null) {
      _idle!.complete();
      _idle = null;
    }
  }

  void _emit() => onChange(Map.unmodifiable(_entries));
}

/// 把探测异常的文字归类为“超时”或“失败”的简短中文原因。
ProbeOutcome classifyProbeError(Object e, LatencyLayer layer) {
  final s = '$e';
  final lower = s.toLowerCase();
  if (e is TimeoutException ||
      lower.contains('timeout') ||
      lower.contains('timed out') ||
      s.contains('超时')) {
    return ProbeOutcome.timeout(layer, '超时');
  }
  String reason;
  if (lower.contains('connection refused')) {
    reason = '连接被拒绝（端口未开放）';
  } else if (lower.contains('failed host lookup') ||
      lower.contains('no address associated')) {
    reason = 'DNS 解析失败';
  } else if (lower.contains('network is unreachable')) {
    reason = '网络不可达';
  } else if (lower.contains('certificate') || lower.contains('handshake')) {
    reason = 'TLS 握手或证书校验失败';
  } else if (lower.contains('connection reset')) {
    reason = '连接被重置';
  } else {
    reason = s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }
  return ProbeOutcome.failed(layer, reason);
}
