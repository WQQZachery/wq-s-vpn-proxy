// SPDX-License-Identifier: GPL-3.0-or-later
// VPN 连接按钮动效。动画完全由真实 VPN 状态（原生层上报）驱动：
//   未连接  → 灰色静止圆环
//   准备/连接中 → 主色弧线旋转 + 向外扩散的等待波纹（未收到 started 事件前不会出现任何“成功”效果）
//   已连接  → 绿色完整圆环 + 一次性扩散波纹 + 缓慢呼吸光晕
//   断开中  → 弧线反向旋转并逐渐褪色
//   错误    → 红色圆环 + 一次轻微抖动
// 所有 AnimationController 只在 initState 创建一次并在 dispose 释放；“减少动态效果”时仅保留颜色变化。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../core/models/models.dart';

/// 界面显示的连接阶段（由真实状态 + 本地“请求已发出”标志推导）。
enum OrbPhase { idle, preparing, connecting, connected, disconnecting, error }

OrbPhase orbPhaseFor(VpnState s, {required bool busy}) => switch (s) {
  VpnState.started => OrbPhase.connected,
  VpnState.starting => OrbPhase.connecting,
  VpnState.stopping => OrbPhase.disconnecting,
  VpnState.error => busy ? OrbPhase.preparing : OrbPhase.error,
  VpnState.stopped => busy ? OrbPhase.preparing : OrbPhase.idle,
};

Color orbColor(OrbPhase p) => switch (p) {
  OrbPhase.idle => AppColors.idle,
  OrbPhase.preparing || OrbPhase.connecting => kAccent,
  OrbPhase.connected => kGood,
  OrbPhase.disconnecting => kWarn,
  OrbPhase.error => kBad,
};

String orbLabel(OrbPhase p) => switch (p) {
  OrbPhase.idle => '未连接',
  OrbPhase.preparing => '准备中…',
  OrbPhase.connecting => '连接中…',
  OrbPhase.connected => '已连接',
  OrbPhase.disconnecting => '断开中…',
  OrbPhase.error => '连接失败',
};

class ConnectOrb extends StatefulWidget {
  const ConnectOrb({
    super.key,
    required this.phase,
    required this.onTap,
    this.size = 168,
  });
  final OrbPhase phase;

  /// 为 null 时按钮不可点（状态锁定）。
  final VoidCallback? onTap;
  final double size;

  @override
  State<ConnectOrb> createState() => _ConnectOrbState();
}

class _ConnectOrbState extends State<ConnectOrb> with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late final AnimationController _burst = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 220),
  );
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = Motion.reduced(context);
    _apply(null);
  }

  @override
  void didUpdateWidget(ConnectOrb old) {
    super.didUpdateWidget(old);
    if (old.phase != widget.phase) _apply(old.phase);
  }

  void _apply(OrbPhase? from) {
    final p = widget.phase;
    final spinning = p == OrbPhase.preparing ||
        p == OrbPhase.connecting ||
        p == OrbPhase.disconnecting;
    if (spinning && !_reduced) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
    if (p == OrbPhase.connected && !_reduced) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
    if (from == null) return;
    // 一次性反馈只在真实状态跃迁时触发
    if (p == OrbPhase.connected && from != OrbPhase.connected) {
      HapticFeedback.mediumImpact();
      if (!_reduced) _burst.forward(from: 0);
    }
    if (p == OrbPhase.error && from != OrbPhase.error) {
      HapticFeedback.heavyImpact();
      if (!_reduced) _shake.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _pulse.dispose();
    _burst.dispose();
    _shake.dispose();
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.phase;
    final color = orbColor(p);
    final d = Motion.of(context, Motion.slow);
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: p == OrbPhase.connected ? '断开 VPN' : '连接 VPN',
      value: orbLabel(p),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _press.forward() : null,
        onTapCancel: () => _press.reverse(),
        onTapUp: enabled ? (_) => _press.reverse() : null,
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                widget.onTap!();
              }
            : null,
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: color),
          duration: d,
          curve: Curves.easeOutCubic,
          builder: (context, c, _) => AnimatedBuilder(
            animation: Listenable.merge([_spin, _pulse, _burst, _shake, _press]),
            builder: (context, _) {
              final shakeDx = _shake.isAnimating
                  ? math.sin(_shake.value * math.pi * 6) * 6 * (1 - _shake.value)
                  : 0.0;
              final scale = 1 - 0.04 * Curves.easeOut.transform(_press.value);
              return Transform.translate(
                offset: Offset(shakeDx, 0),
                child: Transform.scale(
                  scale: scale,
                  child: SizedBox.square(
                    dimension: widget.size + 56,
                    child: CustomPaint(
                      painter: _OrbPainter(
                        color: c ?? color,
                        phase: p,
                        spin: _spin.value,
                        pulse: Curves.easeInOut.transform(_pulse.value),
                        burst: _burst.isAnimating || _burst.value < 1
                            ? _burst.value
                            : 1,
                        orbRadius: widget.size / 2,
                        reduced: _reduced,
                      ),
                      child: Center(
                        child: SwapSwitcher(
                          identity: p == OrbPhase.error,
                          transitionBuilder: (child, a) => FadeTransition(
                            opacity: a,
                            child: ScaleTransition(
                              scale: Tween(begin: 0.85, end: 1.0).animate(a),
                              child: child,
                            ),
                          ),
                          child: Icon(
                            p == OrbPhase.error
                                ? Icons.priority_high_rounded
                                : Icons.power_settings_new_rounded,
                            size: widget.size * 0.34,
                            color: (c ?? color).withValues(
                              alpha: enabled ? 1 : 0.7,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.color,
    required this.phase,
    required this.spin,
    required this.pulse,
    required this.burst,
    required this.orbRadius,
    this.reduced = false,
  });
  final bool reduced;
  final Color color;
  final OrbPhase phase;
  final double spin;
  final double pulse;
  final double burst;
  final double orbRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = orbRadius;

    // 呼吸光晕（仅已连接）：用径向渐变而非 BoxShadow，避免每帧模糊重绘的开销
    if (phase == OrbPhase.connected) {
      final glowR = r + 14 + 8 * pulse;
      canvas.drawCircle(
        c,
        glowR,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: 0.20 + 0.08 * pulse),
              color.withValues(alpha: 0),
            ],
            stops: [r / glowR, 1],
          ).createShader(Rect.fromCircle(center: c, radius: glowR)),
      );
    }

    // 连接中等待波纹：两道错开半个周期的圆环由内向外扩散。
    // 复用旋转控制器的进度（只在真实的 preparing/connecting 阶段运行），
    // 不额外占用 Ticker；减少动态效果时不绘制。
    if (!reduced &&
        (phase == OrbPhase.preparing || phase == OrbPhase.connecting)) {
      for (final offset in const [0.0, 0.5]) {
        final t = (spin + offset) % 1.0;
        final e = Curves.easeOut.transform(t);
        canvas.drawCircle(
          c,
          r + 4 + 22 * e,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = color.withValues(alpha: 0.28 * (1 - e)),
        );
      }
    }

    // 一次性成功波纹
    if (burst > 0 && burst < 1) {
      final t = Curves.easeOutCubic.transform(burst);
      canvas.drawCircle(
        c,
        r + 26 * t,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 * (1 - t) + 0.5
          ..color = color.withValues(alpha: 0.55 * (1 - t)),
      );
    }

    // 内盘
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.lerp(AppColors.surfaceHigh, color, 0.16)!,
            Color.lerp(AppColors.surface, color, 0.05)!,
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // 底环
    final ringRect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = color.withValues(
          alpha: switch (phase) {
            OrbPhase.connected || OrbPhase.error => 0.9,
            OrbPhase.idle => 0.35,
            _ => 0.18,
          },
        ),
    );

    // 过渡态的旋转弧线（渐变尾迹）
    final spinning = phase == OrbPhase.preparing ||
        phase == OrbPhase.connecting ||
        phase == OrbPhase.disconnecting;
    if (spinning) {
      final dir = phase == OrbPhase.disconnecting ? -1.0 : 1.0;
      final start = dir * spin * 2 * math.pi - math.pi / 2;
      const sweep = math.pi * 0.9;
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(start);
      canvas.translate(-c.dx, -c.dy);
      canvas.drawArc(
        ringRect,
        dir > 0 ? -sweep : 0,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(
            startAngle: dir > 0 ? -sweep : 0,
            endAngle: dir > 0 ? 0 : sweep,
            colors: dir > 0
                ? [color.withValues(alpha: 0), color]
                : [color, color.withValues(alpha: 0)],
            transform: const GradientRotation(0),
          ).createShader(ringRect),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _OrbPainter o) =>
      o.color != color ||
      o.phase != phase ||
      o.spin != spin ||
      o.pulse != pulse ||
      o.burst != burst ||
      o.orbRadius != orbRadius ||
      o.reduced != reduced;
}
