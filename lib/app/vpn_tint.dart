// SPDX-License-Identifier: GPL-3.0-or-later
// 全屏 VPN 状态色：
// * 背景色调随 VPN 真实状态变化（未连接：中性；连接中：主色；已连接：绿色；断开中：琥珀；失败：红色）。
// * 每次状态色改变时，新颜色以“水波”形式从连接按钮中心向外蔓延，直到铺满整个屏幕
//   （内容层之下铺底色，内容层之上再画一道半透明波前，让卡片、导航栏上也能看到颜色经过）。
// * 颜色只由首页根据真实状态推导后写入，不会在未收到 started 前出现绿色。
// * 系统“减少动态效果”时不画水波，只做 200ms 颜色淡变。
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme.dart';

class VpnTint {
  const VpnTint(this.color, this.origin, this.serial);

  /// null = 未连接（中性背景）。
  final Color? color;

  /// 水波起点（全局坐标，一般是连接按钮中心）；null 时取屏幕上部 30% 处。
  final Offset? origin;
  final int serial;
}

class VpnTintNotifier extends Notifier<VpnTint> {
  @override
  VpnTint build() => const VpnTint(null, null, 0);

  void set(Color? color, {Offset? origin}) {
    if (color == state.color) return;
    state = VpnTint(color, origin ?? state.origin, state.serial + 1);
  }
}

final vpnTintProvider = NotifierProvider<VpnTintNotifier, VpnTint>(
  VpnTintNotifier.new,
);

/// 背景铺色强度：顶部更浓，向下渐淡。
Color tintTop(Color c) => Color.lerp(AppColors.bg, c, 0.30)!;
Color tintBottom(Color c) => Color.lerp(AppColors.bg, c, 0.08)!;

/// 包住整个应用外壳：[child] 应为透明背景。
class VpnTintScope extends ConsumerStatefulWidget {
  const VpnTintScope({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<VpnTintScope> createState() => _VpnTintScopeState();
}

class _VpnTintScopeState extends ConsumerState<VpnTintScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  final _key = GlobalKey();
  Color? _from;
  Color? _to;
  Offset? _origin;

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  void _onTint(VpnTint? prev, VpnTint next) {
    if (prev != null && prev.color == next.color) return;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    setState(() {
      _from = _to;
      _to = next.color;
      _origin = (next.origin != null && box != null && box.hasSize)
          ? box.globalToLocal(next.origin!)
          : null;
    });
    final reduced = Motion.reduced(context);
    _wave.duration = reduced
        ? const Duration(milliseconds: 200)
        : const Duration(milliseconds: 900);
    _wave.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<VpnTint>(vpnTintProvider, _onTint);
    final reduced = Motion.reduced(context);
    return Stack(
      key: _key,
      fit: StackFit.expand,
      children: [
        // 底色层（内容之下）
        RepaintBoundary(
          child: CustomPaint(
            painter: _TintPainter(
              anim: _wave,
              from: () => _from,
              to: () => _to,
              origin: () => _origin,
              reduced: reduced,
            ),
          ),
        ),
        widget.child,
        // 波前层（内容之上，不拦截点击）
        if (!reduced)
          IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _WaveFrontPainter(
                  anim: _wave,
                  to: () => _to,
                  origin: () => _origin,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

Offset _originOf(Size s, Offset? o) => o ?? Offset(s.width / 2, s.height * 0.3);

double _coverRadius(Size s, Offset o) => [
  o.distance,
  (o - Offset(s.width, 0)).distance,
  (o - Offset(0, s.height)).distance,
  (o - Offset(s.width, s.height)).distance,
].reduce(math.max);

void _paintTint(Canvas canvas, Rect r, Color? c, {Path? clip}) {
  final paint = Paint()
    ..shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: c == null
          ? const [AppColors.bg, AppColors.bg]
          : [tintTop(c), tintBottom(c)],
    ).createShader(r);
  if (clip != null) {
    canvas.drawPath(clip, paint);
  } else {
    canvas.drawRect(r, paint);
  }
}

class _TintPainter extends CustomPainter {
  _TintPainter({
    required this.anim,
    required this.from,
    required this.to,
    required this.origin,
    required this.reduced,
  }) : super(repaint: anim);
  final Animation<double> anim;
  final Color? Function() from;
  final Color? Function() to;
  final Offset? Function() origin;
  final bool reduced;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final t = anim.value;
    if (t >= 1 || !anim.isAnimating && t == 0 && from() == to()) {
      _paintTint(canvas, rect, to());
      return;
    }
    _paintTint(canvas, rect, from());
    if (reduced) {
      canvas.saveLayer(rect, Paint()..color = Color.fromRGBO(0, 0, 0, t));
      _paintTint(canvas, rect, to());
      canvas.restore();
      return;
    }
    final o = _originOf(size, origin());
    final e = Curves.easeOutCubic.transform(t);
    final r = _coverRadius(size, o) * e;
    _paintTint(canvas, rect, to(), clip: Path()..addOval(Rect.fromCircle(center: o, radius: r)));
  }

  @override
  bool shouldRepaint(covariant _TintPainter old) => old.reduced != reduced;
}

class _WaveFrontPainter extends CustomPainter {
  _WaveFrontPainter({required this.anim, required this.to, required this.origin})
    : super(repaint: anim);
  final Animation<double> anim;
  final Color? Function() to;
  final Offset? Function() origin;

  @override
  void paint(Canvas canvas, Size size) {
    final t = anim.value;
    if (t <= 0 || t >= 1) return;
    final c = to() ?? AppColors.idle;
    final o = _originOf(size, origin());
    final e = Curves.easeOutCubic.transform(t);
    final r = _coverRadius(size, o) * e;
    final fade = (1 - t) * (1 - t);
    // 水体：越靠近波前越浓，内部很淡，让颜色“流过”卡片
    canvas.drawCircle(
      o,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            c.withValues(alpha: 0.04 * fade),
            c.withValues(alpha: 0.16 * fade),
            c.withValues(alpha: 0.30 * fade),
          ],
          stops: const [0, 0.82, 1],
        ).createShader(Rect.fromCircle(center: o, radius: math.max(r, 1))),
    );
    // 两道波峰：主波前 + 稍后的次波
    for (final (lag, w) in const [(0.0, 3.0), (0.12, 1.5)]) {
      final rr = _coverRadius(size, o) *
          Curves.easeOutCubic.transform((t - lag).clamp(0.0, 1.0));
      if (rr <= 0) continue;
      canvas.drawCircle(
        o,
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = lerpDouble(w * 2, w, t)!
          ..color = c.withValues(alpha: 0.55 * fade),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveFrontPainter old) => false;
}
