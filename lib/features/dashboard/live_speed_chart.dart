// SPDX-License-Identifier: GPL-3.0-or-later
// 首页实时网速曲线。
//
// 设计要点：
// * 数据：只使用 TrafficMeter 中由 sing-box 内核真实计数换算得到的采样点（约每 500 ms 一个）。
// * 绘制与采样解耦：Ticker 按屏幕刷新率（60/90/120 Hz）重绘，但只重绘本 CustomPaint（RepaintBoundary 隔离），
//   不 rebuild 页面。
// * 平滑滚动：画面时间轴比“现在”滞后约一个采样间隔，这样最新的真实采样点会从右边缘连续地“长”出来，
//   而不是整段跳动；线头位置在两次真实采样之间用单调插值求得——只在已测得的两点之间插值，绝不外推。
//   数据迟到时线头停在最后一个真实采样点，不会伪造后续数据。
// * 纵轴上限平滑过渡，流量突增时曲线不闪烁。
// * 系统“减少动态效果”开启时：不运行 Ticker，仅在新采样到达时重绘、无滞后。

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/engine/chart_math.dart';
import '../../core/engine/traffic_meter.dart';

class LiveSpeedChart extends StatefulWidget {
  const LiveSpeedChart({
    super.key,
    required this.meter,
    required this.active,
    required this.sampleCount,
    this.window = const Duration(seconds: 60),
  });

  final TrafficMeter meter;

  /// VPN 已连接且有数据时为 true；否则停止动画。
  final bool active;

  /// 父组件每收到新采样就会变化，用于“减少动态效果”模式下触发重绘。
  final int sampleCount;
  final Duration window;

  @override
  State<LiveSpeedChart> createState() => _LiveSpeedChartState();
}

class _ChartModel extends ChangeNotifier {
  double renderT = 0; // 当前画面对应的时间（ms，epoch）
  double yMax = 1e6; // 当前纵轴上限（bps），平滑变化
  void bump() => notifyListeners();
}

class _LiveSpeedChartState extends State<LiveSpeedChart>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  final _model = _ChartModel();
  Duration _last = Duration.zero;
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = Motion.reduced(context);
    _sync();
  }

  @override
  void didUpdateWidget(LiveSpeedChart old) {
    super.didUpdateWidget(old);
    _sync();
    if (_reduced && widget.sampleCount != old.sampleCount) _stepStatic();
  }

  void _sync() {
    final run = widget.active && !_reduced;
    if (run && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
    if (!run) _stepStatic();
  }

  double _lagMs(List<SpeedSample> s) {
    final iv = estimateIntervalMs([
      for (var i = math.max(0, s.length - 9); i < s.length; i++)
        s[i].timestampMs,
    ]);
    return (iv * 1.15).clamp(250.0, 1500.0);
  }

  double _targetMax(double renderT) {
    final s = widget.meter.samples;
    final from = renderT - widget.window.inMilliseconds;
    var m = 0.0;
    for (final x in s) {
      if (x.timestampMs < from) continue;
      m = math.max(m, math.max(x.downBps, x.upBps));
    }
    return niceCeil(m, minimum: 100e3); // 至少 100 Kbps 的量程，避免空闲时噪声被放大
  }

  void _stepStatic() {
    final s = widget.meter.samples;
    if (s.isEmpty) return;
    _model.renderT = s.last.timestampMs.toDouble();
    _model.yMax = _targetMax(_model.renderT);
    _model.bump();
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 16.0
        : (elapsed - _last).inMicroseconds / 1000.0;
    _last = elapsed;
    final s = widget.meter.samples;
    if (s.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch.toDouble();
    // 画面时间不超过最后一个真实采样（不外推），也不倒退。
    final target = math.min(now - _lagMs(s), s.last.timestampMs.toDouble());
    final prev = _model.renderT;
    // 数据迟到后恢复时以至多 1.6 倍速追赶，避免画面突然跳一段；也不倒退。
    final t = (prev == 0 || target - prev > 10000)
        ? target
        : math.max(prev, math.min(target, prev + dt * 1.6));
    _model.renderT = t;
    _model.yMax = approach(_model.yMax, _targetMax(t), dt, 380);
    _model.bump();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _ChartPainter(
          model: _model,
          samples: widget.meter.samples,
          windowMs: widget.window.inMilliseconds.toDouble(),
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.model,
    required this.samples,
    required this.windowMs,
  }) : super(repaint: model);

  final _ChartModel model;
  final List<SpeedSample> samples;
  final double windowMs;

  static final _gridPaint = Paint()
    ..color = AppColors.border
    ..strokeWidth = 1;

  @override
  void paint(Canvas canvas, Size size) {
    final yMax = model.yMax <= 0 ? 1.0 : model.yMax;
    const top = 6.0;
    final bottom = size.height - 2;
    final h = bottom - top;

    // 网格与刻度（3 条）
    for (var i = 0; i <= 2; i++) {
      final y = top + h * i / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), _gridPaint);
      if (i < 2) {
        final tp = TextPainter(
          text: TextSpan(
            text: formatBps(yMax * (1 - i / 2)),
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.textMuted,
              fontFeatures: [ui.FontFeature.tabularFigures()],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(2, y + 2));
      }
    }
    if (samples.isEmpty || model.renderT == 0) return;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    _series(canvas, size, top, h, yMax, (s) => s.downBps, kAccent, fill: true);
    _series(canvas, size, top, h, yMax, (s) => s.upBps, kUpload, fill: false);
    canvas.restore();
  }

  void _series(
    Canvas canvas,
    Size size,
    double top,
    double h,
    double yMax,
    double Function(SpeedSample) f,
    Color color, {
    required bool fill,
  }) {
    final renderT = model.renderT;
    final from = renderT - windowMs;
    // 取窗口内的点，并各多带一个窗口外的点保证边缘连续。
    var start = 0;
    while (start < samples.length - 1 &&
        samples[start + 1].timestampMs < from) {
      start++;
    }
    final xs = <double>[];
    final ys = <double>[];
    for (var i = start; i < samples.length; i++) {
      final t = samples[i].timestampMs.toDouble();
      if (xs.isNotEmpty && t <= xs.last) continue;
      xs.add(t);
      ys.add(f(samples[i]));
      if (t > renderT) break; // 只需要线头所在区间的右端点
    }
    if (xs.isEmpty) return;
    double px(double t) => size.width * (1 - (renderT - t) / windowMs);
    double py(double v) => top + h * (1 - (v / yMax).clamp(0.0, 1.05));

    final path = Path()..moveTo(px(xs[0]), py(ys[0]));
    var headX = px(xs[0]);
    var headY = py(ys[0]);
    if (xs.length >= 2) {
      final m = monotoneTangents(xs, ys);
      for (var i = 0; i < xs.length - 1; i++) {
        if (xs[i] >= renderT) break;
        final x0 = xs[i], x1 = xs[i + 1];
        final hh = x1 - x0;
        // Hermite → 三次贝塞尔（精确转换）
        final p0 = Offset(px(x0), py(ys[i]));
        var p1 = Offset(px(x0 + hh / 3), py(ys[i] + m[i] * hh / 3));
        var p2 = Offset(px(x1 - hh / 3), py(ys[i + 1] - m[i + 1] * hh / 3));
        var p3 = Offset(px(x1), py(ys[i + 1]));
        if (x1 > renderT) {
          // 线头落在本区间：用 de Casteljau 截取 [0, u] 段，u 为画面时间在区间中的位置
          final u = ((renderT - x0) / hh).clamp(0.0, 1.0);
          final a = Offset.lerp(p0, p1, u)!;
          final b = Offset.lerp(p1, p2, u)!;
          final c = Offset.lerp(p2, p3, u)!;
          final d = Offset.lerp(a, b, u)!;
          final e = Offset.lerp(b, c, u)!;
          final g = Offset.lerp(d, e, u)!;
          p1 = a;
          p2 = d;
          p3 = g;
        }
        path.cubicTo(p1.dx, p1.dy, p2.dx, p2.dy, p3.dx, p3.dy);
        headX = p3.dx;
        headY = p3.dy;
      }
    }

    if (fill) {
      final area = Path.from(path)
        ..lineTo(headX, top + h)
        ..lineTo(px(xs[0]), top + h)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(0, top),
            Offset(0, top + h),
            [color.withValues(alpha: 0.28), color.withValues(alpha: 0.0)],
          ),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(
      Offset(headX, headY),
      5,
      Paint()..color = color.withValues(alpha: 0.22),
    );
    canvas.drawCircle(Offset(headX, headY), 2.6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.samples != samples || old.windowMs != windowMs || old.model != model;
}
