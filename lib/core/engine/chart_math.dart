// SPDX-License-Identifier: GPL-3.0-or-later
// 实时曲线的纯数学部分（可单测）。
//
// 原则：插值只用于“画在两次真实采样之间的线”，不产生新的数据点，也不外推未来值。
// 采用 Fritsch–Carlson 单调三次 Hermite 插值：曲线在任意两点之间的取值严格位于这两个真实采样值之间，
// 不会出现普通样条的过冲（例如凭空画出高于峰值或低于 0 的速度）。

import 'dart:math' as math;

/// 计算单调三次 Hermite 插值的各点切线。[xs] 必须严格递增。
List<double> monotoneTangents(List<double> xs, List<double> ys) {
  final n = xs.length;
  if (n < 2) return List.filled(n, 0);
  final d = List<double>.generate(
    n - 1,
    (i) => (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]),
  );
  final m = List<double>.filled(n, 0);
  m[0] = d[0];
  m[n - 1] = d[n - 2];
  for (var i = 1; i < n - 1; i++) {
    m[i] = (d[i - 1] * d[i] <= 0) ? 0 : (d[i - 1] + d[i]) / 2;
  }
  for (var i = 0; i < n - 1; i++) {
    if (d[i] == 0) {
      m[i] = 0;
      m[i + 1] = 0;
      continue;
    }
    final a = m[i] / d[i];
    final b = m[i + 1] / d[i];
    final s = a * a + b * b;
    if (s > 9) {
      final t = 3 / math.sqrt(s);
      m[i] = t * a * d[i];
      m[i + 1] = t * b * d[i];
    }
  }
  return m;
}

/// 在区间 [i, i+1] 内求 x 处的插值。
double hermiteAt(
  List<double> xs,
  List<double> ys,
  List<double> m,
  int i,
  double x,
) {
  final h = xs[i + 1] - xs[i];
  if (h <= 0) return ys[i];
  final t = ((x - xs[i]) / h).clamp(0.0, 1.0);
  final t2 = t * t;
  final t3 = t2 * t;
  final h00 = 2 * t3 - 3 * t2 + 1;
  final h10 = t3 - 2 * t2 + t;
  final h01 = -2 * t3 + 3 * t2;
  final h11 = t3 - t2;
  return h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1];
}

/// 坐标轴上限取“好看”的整数刻度（1/2/2.5/5 × 10^n），并留出约 15% 余量。
double niceCeil(double v, {double minimum = 1}) {
  final x = math.max(v * 1.15, minimum);
  final p = math.pow(10, (math.log(x) / math.ln10).floor()).toDouble();
  for (final k in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (k * p >= x) return k * p;
  }
  return 10 * p;
}

/// 以时间常数 [tauMs] 的指数平滑逼近 [target]（与帧率无关：60Hz/120Hz 结果一致）。
double approach(double current, double target, double dtMs, double tauMs) {
  if (tauMs <= 0) return target;
  final k = 1 - math.exp(-dtMs / tauMs);
  return current + (target - current) * k;
}

/// 估计采样间隔（取最近若干个间隔的中位数），用于决定曲线的渲染延迟。
double estimateIntervalMs(List<int> timestamps, {double fallback = 500}) {
  if (timestamps.length < 2) return fallback;
  final start = math.max(1, timestamps.length - 8);
  final diffs = <int>[
    for (var i = start; i < timestamps.length; i++)
      timestamps[i] - timestamps[i - 1],
  ]..sort();
  final med = diffs[diffs.length ~/ 2].toDouble();
  return med <= 0 ? fallback : med;
}
