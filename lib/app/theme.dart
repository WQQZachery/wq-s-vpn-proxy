// SPDX-License-Identifier: GPL-3.0-or-later
// 全局视觉系统：颜色、间距、圆角、字体层级与通用组件。所有页面只从这里取样式，避免各页各写一套。
import 'package:flutter/material.dart';

// ---------------- 颜色 ----------------
const kAccent = Color(0xFF5B8CFF); // 主色 / 下载
const kUpload = Color(0xFF3DDC97); // 上传
const kGood = Color(0xFF3DDC97);
const kWarn = Color(0xFFFFB547);
const kBad = Color(0xFFFF5C6C);

class AppColors {
  static const bg = Color(0xFF0A0C11); // 页面背景
  static const surface = Color(0xFF12151C); // 卡片 / 分组背景
  static const surfaceHigh = Color(0xFF181C25); // 卡片内的强调块
  static const border = Color(0x14FFFFFF); // 8% 白，细边框
  static const borderStrong = Color(0x24FFFFFF);
  static const textPrimary = Color(0xFFF2F4F8);
  static const textSecondary = Color(0xB3E6EAF2); // ~70%
  static const textTertiary = Color(0x80E6EAF2); // ~50%
  static const textMuted = Color(0x59E6EAF2); // ~35%
  static const idle = Color(0xFF7D8596);
}

// ---------------- 尺寸 ----------------
class Gaps {
  static const page = 20.0; // 页面左右边距
  static const card = 16.0; // 卡片内边距
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
}

class Radii {
  static const sm = 10.0;
  static const md = 14.0;
  static const lg = 20.0;
  static const pill = 999.0;
}

/// 动画时长（统一）；系统开启“减少动态效果”时用 [motion] 缩成近乎瞬时。
class Motion {
  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 260);
  static const slow = Duration(milliseconds: 420);
  static const emphasized = Curves.easeOutCubic;

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static Duration of(BuildContext context, Duration d) =>
      reduced(context) ? Duration.zero : d;
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kAccent,
    brightness: Brightness.dark,
    surface: AppColors.surface,
  ).copyWith(primary: kAccent, error: kBad, outlineVariant: AppColors.border);
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final text = base.textTheme.apply(
    bodyColor: AppColors.textPrimary,
    displayColor: AppColors.textPrimary,
  );
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    textTheme: text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        height: 1.25,
        letterSpacing: -0.2,
      ),
      titleMedium: text.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      titleSmall: text.titleSmall?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        height: 1.3,
        color: AppColors.textSecondary,
      ),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 14, height: 1.45),
      bodySmall: text.bodySmall?.copyWith(
        fontSize: 12,
        height: 1.4,
        color: AppColors.textTertiary,
      ),
      labelSmall: text.labelSmall?.copyWith(
        fontSize: 11,
        height: 1.3,
        letterSpacing: 0.2,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: Gaps.page - 4, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: Gaps.card),
      subtitleTextStyle: TextStyle(
        fontSize: 12,
        height: 1.4,
        color: AppColors.textTertiary,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: AppColors.surfaceHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: const BorderSide(color: kAccent, width: 1.2),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: AppColors.surface,
      selectedColor: kAccent.withValues(alpha: 0.18),
      side: const BorderSide(color: AppColors.border),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      labelStyle: const TextStyle(fontSize: 13),
      showCheckmark: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kAccent,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        side: const BorderSide(color: AppColors.borderStrong),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surfaceHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surfaceHigh,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: const TextStyle(color: AppColors.textPrimary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}

// ---------------- 通用组件 ----------------

/// 页面标题区（标题 + 可选副标题 + 右侧操作），所有一级页面统一使用。
class PageHeader extends StatelessWidget {
  const PageHeader(this.title, {super.key, this.subtitle, this.trailing});
  final String title;
  final Widget? subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gaps.page, Gaps.xl, Gaps.page - 8, 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                DefaultTextStyle.merge(
                  style: Theme.of(context).textTheme.bodySmall,
                  child: subtitle!,
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing, this.info});
  final String text;
  final Widget? trailing;

  /// 可选的说明文字，显示为标题旁的 ⓘ，点按弹出解释。
  final String? info;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gaps.page, 18, 12, 6),
    child: Row(
      children: [
        Flexible(
          child: Text(text, style: Theme.of(context).textTheme.titleSmall),
        ),
        if (info != null) InfoTip(title: text, message: info!),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

/// 信息提示图标：点按弹出简短解释。
class InfoTip extends StatelessWidget {
  const InfoTip({super.key, required this.title, required this.message});
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => InkResponse(
    radius: 18,
    onTap: () => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title, style: Theme.of(context).textTheme.titleMedium),
        content: Text(message, style: const TextStyle(height: 1.55)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('知道了'),
          ),
        ],
      ),
    ),
    child: Semantics(
      button: true,
      label: '说明：$title',
      child: const Padding(
        padding: EdgeInsets.all(6),
        child: Icon(
          Icons.info_outline,
          size: 16,
          color: AppColors.textTertiary,
        ),
      ),
    ),
  );
}

/// 统一的卡片容器（与 CardTheme 一致，但可控内边距与强调色描边）。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Gaps.card),
    this.margin = const EdgeInsets.symmetric(horizontal: Gaps.page - 4, vertical: 6),
    this.highlight,
    this.onTap,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? highlight;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(Radii.lg);
    return Padding(
      padding: margin,
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: highlight?.withValues(alpha: 0.55) ?? AppColors.border,
            width: highlight == null ? 1 : 1.2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 小型状态标签（如 “TCP 可达” “代理可用” “缓存”）。
class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, required this.color, this.icon});
  final String label;
  final Color color;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
              height: 1.2,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 空状态 / 错误状态占位。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40, color: AppColors.textMuted),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (message != null) ...[
          const SizedBox(height: 6),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (action != null) ...[const SizedBox(height: 16), action!],
      ],
    ),
  );
}

/// 键值行（左标签、右值），用于结果详情。
class KvRow extends StatelessWidget {
  const KvRow(this.k, this.v, {super.key, this.info, this.valueColor});
  final String k;
  final String v;
  final String? info;
  final Color? valueColor;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Row(
            children: [
              Flexible(
                child: Text(
                  k,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
              if (info != null)
                SizedBox(
                  height: 18,
                  child: InfoTip(title: k, message: info!),
                ),
            ],
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: valueColor,
            ),
          ),
        ),
      ],
    ),
  );
}

void showSnack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// AnimatedSwitcher 的安全封装：每当 [identity] 变化就用一个递增的“代号”作为子组件 key。
/// 这样即使状态快速来回切换（A→B→A），淡出中的旧子组件也不会与新子组件 key 重复。
class SwapSwitcher extends StatefulWidget {
  const SwapSwitcher({
    super.key,
    required this.identity,
    required this.child,
    this.duration = Motion.medium,
    this.transitionBuilder = AnimatedSwitcher.defaultTransitionBuilder,
    this.alignment = Alignment.center,
  });
  final Object? identity;
  final Widget child;
  final Duration duration;
  final AnimatedSwitcherTransitionBuilder transitionBuilder;
  final AlignmentGeometry alignment;
  @override
  State<SwapSwitcher> createState() => _SwapSwitcherState();
}

class _SwapSwitcherState extends State<SwapSwitcher> {
  int _gen = 0;
  @override
  void didUpdateWidget(SwapSwitcher old) {
    super.didUpdateWidget(old);
    if (old.identity != widget.identity) _gen++;
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.of(context, widget.duration),
    transitionBuilder: widget.transitionBuilder,
    layoutBuilder: (cur, prev) => Stack(
      alignment: widget.alignment,
      children: [...prev, ?cur],
    ),
    child: KeyedSubtree(key: ValueKey<int>(_gen), child: widget.child),
  );
}
