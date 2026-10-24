// SPDX-License-Identifier: GPL-3.0-or-later
// 吞吐量与延迟统计（纯 Dart，可单测）。
//
// 原始测量值（raw）与仪表盘显示值（display）严格分开：
//   * raw 瞬时速度 = 最近 [windowMs] 内真实收到/发出的字节 ÷ 时间；
//   * 最终结果 = 预热期之后的总字节 ÷ 预热期之后的时长（排除 TCP 慢启动阶段）；
//   * display 只是 UI 层对 raw 做的时间平滑，从不参与最终结果。

import 'dart:math' as math;

class ThroughputMeter {
  ThroughputMeter({this.windowMs = 1000, this.warmupMs = 2000, this.limitMs});
  final int windowMs;
  final int warmupMs;

  /// 测量窗口终点：超过该时间到达的数据不再计入，时间也截止于此（保证结果只反映测量窗口）。
  final int? limitMs;

  final List<(int, int)> _points = []; // (t ms, 累计字节)
  int _total = 0;
  int? _warmupBytes;
  int? _warmupAt;
  int _lastT = 0;

  int get totalBytes => _total;
  int get elapsedMs => _lastT;

  /// 在 t（从测试开始计的毫秒）时新增 [bytes] 字节。
  void add(int tMs, int bytes) {
    if (limitMs != null && tMs > limitMs!) return;
    _total += bytes;
    record(tMs);
  }

  /// 以当前累计字节记录一个时间点（用于无新数据时让瞬时速度回落）。
  void record(int tMs) {
    if (limitMs != null && tMs > limitMs!) tMs = limitMs!;
    if (tMs < _lastT) return;
    _lastT = tMs;
    if (_warmupAt == null && tMs >= warmupMs) {
      _warmupAt = tMs;
      _warmupBytes = _total;
    }
    _points.add((tMs, _total));
    final cutoff = tMs - windowMs * 2;
    while (_points.length > 2 && _points.first.$1 < cutoff) {
      _points.removeAt(0);
    }
  }

  /// 最近一个窗口内的真实平均速度（bps）。
  double instantBps() {
    if (_points.length < 2) return 0;
    final last = _points.last;
    var i = _points.length - 1;
    while (i > 0 && last.$1 - _points[i - 1].$1 <= windowMs) {
      i--;
    }
    final first = _points[i];
    final dt = last.$1 - first.$1;
    if (dt <= 0) return 0;
    return (last.$2 - first.$2) * 8000 / dt;
  }

  /// 最终结果：排除预热期。测试太短（未过预热）时退化为全程平均，并由 [warmedUp] 标明。
  double resultBps() {
    if (_warmupAt != null && _lastT > _warmupAt!) {
      return (_total - _warmupBytes!) * 8000 / (_lastT - _warmupAt!);
    }
    return _lastT <= 0 ? 0 : _total * 8000 / _lastT;
  }

  bool get warmedUp => _warmupAt != null && _lastT - _warmupAt! >= 1000;
}

class LatencyStats {
  const LatencyStats({
    required this.samples,
    required this.medianMs,
    required this.minMs,
    required this.jitterMs,
    required this.attempts,
  });
  final List<double> samples;
  final double medianMs;
  final double minMs;

  /// 抖动：相邻两次 RTT 差值绝对值的平均（与 RFC 3550 思路一致的简化定义）。
  final double jitterMs;
  final int attempts;
  int get failures => attempts - samples.length;

  static LatencyStats? of(List<double> s, int attempts) {
    if (s.isEmpty) return null;
    final sorted = [...s]..sort();
    final med = sorted.length.isOdd
        ? sorted[sorted.length ~/ 2]
        : (sorted[sorted.length ~/ 2 - 1] + sorted[sorted.length ~/ 2]) / 2;
    var j = 0.0;
    for (var i = 1; i < s.length; i++) {
      j += (s[i] - s[i - 1]).abs();
    }
    return LatencyStats(
      samples: s,
      medianMs: med,
      minMs: sorted.first,
      jitterMs: s.length < 2 ? 0 : j / (s.length - 1),
      attempts: attempts,
    );
  }
}

/// 仪表盘刻度：非线性（低速段更细），返回 0..1 的位置。
const gaugeTicksMbps = [0.0, 1, 5, 10, 25, 50, 100, 250, 500, 1000];

double gaugePosition(double mbps) {
  if (mbps <= 0) return 0;
  final t = gaugeTicksMbps;
  if (mbps >= t.last) return 1;
  for (var i = 1; i < t.length; i++) {
    if (mbps <= t[i]) {
      final f = (mbps - t[i - 1]) / (t[i] - t[i - 1]);
      return (i - 1 + f) / (t.length - 1);
    }
  }
  return 1;
}

double mbpsOf(double bps) => bps / 1e6;

String formatMbps(double bps) {
  final m = bps / 1e6;
  if (m >= 100) return m.toStringAsFixed(0);
  if (m >= 10) return m.toStringAsFixed(1);
  return m.toStringAsFixed(2);
}

double clampPos(double v) => math.max(0, math.min(1, v));
