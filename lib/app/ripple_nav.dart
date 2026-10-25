// SPDX-License-Identifier: GPL-3.0-or-later
// 带“水波扩散”反馈的底部导航与页面切换容器。
//
// * 水波以手指实际按下的位置为圆心，向上扩散到页面区域；边缘使用径向渐变柔化，透明度随扩散衰减。
//   覆盖层 IgnorePointer，完全不拦截触摸；只重绘自身（RepaintBoundary + CustomPainter），不 rebuild 页面。
// * 导航在点击瞬间就切换（不等动画），目标页同时淡入并轻微上移；旧页同步淡出，避免闪屏。
// * 所有页面常驻（保留滚动位置与状态），非当前页 Offstage + TickerMode 关闭，不消耗动画帧。
// * 快速连续点击：每次点击重新开始转场与水波，不会叠加或错位；系统返回键先回到首页。
// * 系统“减少动态效果”开启时不绘制水波，页面直接切换。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

class NavDestinationSpec {
  const NavDestinationSpec(this.icon, this.selectedIcon, this.label);
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class RippleNavShell extends StatefulWidget {
  const RippleNavShell({
    super.key,
    required this.destinations,
    required this.pageBuilder,
    this.onIndexChanged,
  });
  final List<NavDestinationSpec> destinations;

  /// 根据 (index, 是否为当前页) 构建页面。
  final Widget Function(int index, bool active) pageBuilder;
  final ValueChanged<int>? onIndexChanged;

  @override
  State<RippleNavShell> createState() => RippleNavShellState();
}

class RippleNavShellState extends State<RippleNavShell>
    with TickerProviderStateMixin {
  int _index = 0;
  int? _prev;
  Offset? _origin; // 水波圆心（相对本组件）
  Color _rippleColor = kAccent;
  final _stackKey = GlobalKey();

  late final AnimationController _page = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  )..addStatusListener((s) {
      if (s == AnimationStatus.completed && _prev != null) {
        setState(() => _prev = null);
      }
    });
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  int get index => _index;

  @override
  void dispose() {
    _page.dispose();
    _ripple.dispose();
    super.dispose();
  }

  void select(int i, {Offset? globalTap}) {
    final reduced = Motion.reduced(context);
    if (globalTap != null && !reduced) {
      final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        _origin = box.globalToLocal(globalTap);
        _rippleColor = kAccent;
        _ripple.forward(from: 0);
      }
    }
    if (i == _index) return;
    HapticFeedback.selectionClick();
    setState(() {
      _prev = _index;
      _index = i;
    });
    widget.onIndexChanged?.call(i);
    if (reduced) {
      _page.value = 1;
      setState(() => _prev = null);
    } else {
      _page.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.destinations.length;
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _index != 0) select(0);
      },
      child: Scaffold(
        // 透明：底下是随 VPN 状态变化的全屏铺色层（vpn_tint.dart）
        backgroundColor: Colors.transparent,
        body: Stack(
          key: _stackKey,
          children: [
            Column(
              children: [
                Expanded(
                  child: SafeArea(
                    bottom: false,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        for (var i = 0; i < n; i++) _pageLayer(i),
                      ],
                    ),
                  ),
                ),
                _NavBar(
                  destinations: widget.destinations,
                  index: _index,
                  onTap: (i, pos) => select(i, globalTap: pos),
                ),
              ],
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _RipplePainter(
                      animation: _ripple,
                      origin: () => _origin,
                      color: () => _rippleColor,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pageLayer(int i) {
    final isCurrent = i == _index;
    final isPrev = i == _prev;
    final visible = isCurrent || isPrev;
    // 注意：包裹结构必须恒定（始终 Fade > Slide > 页面），否则切换时页面 State 会被重建、丢失滚动位置与结果。
    Animation<double> opacity = const AlwaysStoppedAnimation(1);
    Animation<Offset> offset = const AlwaysStoppedAnimation(Offset.zero);
    // “淡出-淡入”（fade through）：旧页在前 35% 时间内淡出，新页随后淡入并轻微上移。
    // 两页几乎不同时半透明叠加，避免“双重曝光”；背景同色，因此不会闪屏。
    if (isCurrent && _prev != null) {
      final a = CurvedAnimation(
        parent: _page,
        curve: const Interval(0.3, 1, curve: Curves.easeOutCubic),
      );
      opacity = a;
      offset = Tween(begin: const Offset(0, 0.012), end: Offset.zero).animate(a);
    } else if (isPrev) {
      opacity = Tween(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(
          parent: _page,
          curve: const Interval(0, 0.35, curve: Curves.easeIn),
        ),
      );
    }
    final child = FadeTransition(
      opacity: opacity,
      child: SlideTransition(
        position: offset,
        child: widget.pageBuilder(i, isCurrent),
      ),
    );
    return Offstage(
      key: ValueKey('page$i'),
      offstage: !visible,
      child: TickerMode(
        enabled: isCurrent,
        child: IgnorePointer(ignoring: !isCurrent, child: child),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.destinations,
    required this.index,
    required this.onTap,
  });
  final List<NavDestinationSpec> destinations;
  final int index;
  final void Function(int, Offset) onTap;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xE612151C), // surface 90%，让状态色略微透出
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: SizedBox(
          height: 66,
          child: Row(
            children: [
              for (var i = 0; i < destinations.length; i++)
                Expanded(
                  child: _NavItem(
                    spec: destinations[i],
                    selected: i == index,
                    onTap: (pos) => onTap(i, pos),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.spec,
    required this.selected,
    required this.onTap,
  });
  final NavDestinationSpec spec;
  final bool selected;
  final ValueChanged<Offset> onTap;
  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  Offset? _down;
  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    final color = sel ? kAccent : AppColors.textTertiary;
    final d = Motion.of(context, Motion.medium);
    return Semantics(
      button: true,
      selected: sel,
      label: widget.spec.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (e) => _down = e.globalPosition,
        onTap: () {
          final box = context.findRenderObject() as RenderBox?;
          final pos = _down ??
              box?.localToGlobal(box.size.center(Offset.zero)) ??
              Offset.zero;
          widget.onTap(pos);
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: d,
              curve: Curves.easeOutCubic,
              width: sel ? 56 : 40,
              height: 30,
              decoration: BoxDecoration(
                color: sel ? kAccent.withValues(alpha: 0.16) : Colors.transparent,
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: SwapSwitcher(
                identity: sel,
                duration: Motion.medium,
                child: Icon(
                  sel ? widget.spec.selectedIcon : widget.spec.icon,
                  size: 22,
                  color: color,
                ),
              ),
            ),
            const SizedBox(height: 4),
            AnimatedDefaultTextStyle(
              duration: d,
              style: TextStyle(
                fontSize: 11,
                fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
                color: color,
              ),
              child: Text(widget.spec.label, maxLines: 1),
            ),
          ],
        ),
      ),
    );
  }
}

/// 水波绘制：半径按 easeOutCubic 增长到能覆盖页面大部分区域；
/// 主体为柔和的径向渐变（中心淡、边缘稍亮、外缘羽化），整体透明度随进度衰减。
class _RipplePainter extends CustomPainter {
  _RipplePainter({
    required this.animation,
    required this.origin,
    required this.color,
  }) : super(repaint: animation);
  final Animation<double> animation;
  final Offset? Function() origin;
  final Color Function() color;

  @override
  void paint(Canvas canvas, Size size) {
    final o = origin();
    final t = animation.value;
    if (o == null || t <= 0 || t >= 1) return;
    final e = Curves.easeOutCubic.transform(t);
    // 覆盖到屏幕高度约 75%，避免长时间遮盖整个页面
    final maxR = size.height * 0.75;
    final r = 24 + (maxR - 24) * e;
    final fade = (1 - t) * (1 - t);
    final c = color();
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          c.withValues(alpha: 0.07 * fade),
          c.withValues(alpha: 0.12 * fade),
          c.withValues(alpha: 0.24 * fade),
          c.withValues(alpha: 0),
        ],
        stops: const [0, 0.72, 0.92, 1],
      ).createShader(Rect.fromCircle(center: o, radius: r));
    canvas.drawCircle(o, r, paint);
  }

  @override
  bool shouldRepaint(covariant _RipplePainter old) => false;
}
