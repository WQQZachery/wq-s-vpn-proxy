// SPDX-License-Identifier: GPL-3.0-or-later
// Speedtest 风格仪表盘。指针显示的是对真实瞬时速度做时间平滑后的“显示值”，只用于动画；
// 最终结果始终取引擎计算的实测值（见 SpeedProgress.downloadBps / uploadBps）。

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app/theme.dart';
import '../../core/engine/chart_math.dart';
import '../../core/networking/speedtest/throughput.dart';

class SpeedGauge extends StatefulWidget {
  const SpeedGauge({
    super.key,
    required this.targetBps,
    required this.color,
    required this.caption,
    this.centerOverride,
    this.unitOverride,
  });

  /// 目标值：真实测得的瞬时速度（bps）。
  final double targetBps;
  final Color color;
  final String caption;

  /// 不显示速度时（如测延迟阶段）中央显示的文字。
  final String? centerOverride;
  final String? unitOverride;

  @override
  State<SpeedGauge> createState() => _SpeedGaugeState();
}

class _GaugeModel extends ChangeNotifier {
  double pos = 0; // 0..1 指针位置（平滑）
  double bps = 0; // 平滑后的显示值
  void bump() => notifyListeners();
}

class _SpeedGaugeState extends State<SpeedGauge>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _m = _GaugeModel();
  Duration _last = Duration.zero;

  @override
  void didUpdateWidget(SpeedGauge old) {
    super.didUpdateWidget(old);
    _ensure();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensure();
  }

  void _ensure() {
    if (Motion.reduced(context)) {
      _ticker.stop();
      _m.bps = widget.targetBps;
      _m.pos = gaugePosition(mbpsOf(widget.targetBps));
      _m.bump();
      return;
    }
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration e) {
    final dt = _last == Duration.zero ? 16.0 : (e - _last).inMicroseconds / 1000;
    _last = e;
    final target = widget.targetBps;
    // 显示值：约 0.35 秒时间常数的指数平滑（与刷新率无关）；指针在刻度空间再平滑一次，避免抖动
    _m.bps = approach(_m.bps, target, dt, 350);
    _m.pos = approach(_m.pos, gaugePosition(mbpsOf(_m.bps)), dt, 120);
    _m.bump();
    final settled = (_m.bps - target).abs() < math.max(1000, target * 0.002) &&
        (_m.pos - gaugePosition(mbpsOf(target))).abs() < 0.001;
    if (settled) {
      _m.bps = target;
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _m.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.25,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _m,
          builder: (context, _) => CustomPaint(
            painter: _GaugePainter(pos: _m.pos, color: widget.color),
            child: Align(
              alignment: const Alignment(0, 0.18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.centerOverride ?? formatMbps(_m.bps),
                    style: const TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w700,
                      height: 1.0,
                      letterSpacing: -1,
                      fontFeatures: [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.unitOverride ?? 'Mbps',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.caption,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: widget.color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.pos, required this.color});
  final double pos;
  final Color color;

  static const _start = math.pi * 5 / 6; // 150°
  static const _sweep = math.pi * 4 / 3; // 240°

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width / 2, size.height / 1.62) - 14;
    final c = Offset(size.width / 2, r + 16);
    final rect = Rect.fromCircle(center: c, radius: r);

    // 轨道
    canvas.drawArc(
      rect,
      _start,
      _sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round
        ..color = AppColors.surfaceHigh,
    );
    // 进度弧（渐变）
    final p = clampPos(pos);
    if (p > 0.002) {
      canvas.drawArc(
        rect,
        _start,
        _sweep * p,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 12
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(
            startAngle: _start,
            endAngle: _start + _sweep,
            colors: [color.withValues(alpha: 0.35), color],
            transform: const GradientRotation(0),
          ).createShader(rect),
      );
    }
    // 刻度与标签
    final n = gaugeTicksMbps.length;
    for (var i = 0; i < n; i++) {
      final a = _start + _sweep * i / (n - 1);
      final dir = Offset(math.cos(a), math.sin(a));
      final active = i / (n - 1) <= p + 1e-6;
      canvas.drawLine(
        c + dir * (r - 18),
        c + dir * (r - 12),
        Paint()
          ..strokeWidth = 1.5
          ..color = active ? color.withValues(alpha: 0.8) : AppColors.borderStrong,
      );
      final v = gaugeTicksMbps[i];
      final tp = TextPainter(
        text: TextSpan(
          text: v >= 1000 ? '1G' : v.toStringAsFixed(0),
          style: TextStyle(
            fontSize: 10,
            color: active ? AppColors.textSecondary : AppColors.textMuted,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lp = c + dir * (r - 32);
      tp.paint(canvas, lp - Offset(tp.width / 2, tp.height / 2));
    }
    // 指针
    final a = _start + _sweep * p;
    final dir = Offset(math.cos(a), math.sin(a));
    final tip = c + dir * (r - 22);
    final base = c + dir * (r * 0.52);
    canvas.drawLine(
      base,
      tip,
      Paint()
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
    canvas.drawCircle(tip, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter o) =>
      o.pos != pos || o.color != color;
}

/// 测速过程中的原始速度折线（真实采样，直接连线，不平滑）。
class SpeedSparkline extends StatelessWidget {
  const SpeedSparkline({super.key, required this.series});
  final List<(List<(int, double)>, Color)> series;
  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(painter: _SparkPainter(series), size: Size.infinite),
  );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.series);
  final List<(List<(int, double)>, Color)> series;
  @override
  void paint(Canvas canvas, Size size) {
    var maxT = 1;
    var maxV = 1.0;
    for (final (pts, _) in series) {
      for (final (t, v) in pts) {
        maxT = math.max(maxT, t);
        maxV = math.max(maxV, v);
      }
    }
    maxT = math.max(maxT, 10000);
    for (final (pts, color) in series) {
      if (pts.length < 2) continue;
      final path = Path();
      for (var i = 0; i < pts.length; i++) {
        final x = size.width * pts[i].$1 / maxT;
        final y = size.height * (1 - pts[i].$2 / (maxV * 1.1));
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeJoin = StrokeJoin.round
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SparkPainter o) => o.series != series;
}
