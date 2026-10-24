// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state.dart';
import '../../app/theme.dart';
import '../../core/engine/traffic_meter.dart';
import '../../core/models/models.dart';
import '../profiles/profiles_page.dart' show transportLabel;
import 'connect_orb.dart';
import 'live_speed_chart.dart';

const _tabular = [FontFeature.tabularFigures()];

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});
  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  bool _busy = false;

  /// 连接前置步骤（配置校验 / 授权）失败的原因。仅用于界面提示，不改变真实 VPN 状态。
  String? _localError;

  Future<void> _toggle() async {
    if (_busy) return; // 防重复点击
    final ctrl = ref.read(vpnControllerProvider.notifier);
    final s = ref.read(vpnControllerProvider).state;
    if (s == VpnState.stopping) return; // 状态锁定
    setState(() {
      _busy = true;
      _localError = null;
    });
    try {
      if (s == VpnState.started || s == VpnState.starting) {
        // 连接中再次轻点 = 取消连接
        await ctrl.disconnect();
      } else {
        final err = await ctrl.connect();
        if (err != null && mounted) setState(() => _localError = err);
      }
    } catch (e) {
      if (mounted) setState(() => _localError = '操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vpn = ref.watch(vpnControllerProvider);
    final nodes = ref.watch(nodesProvider);
    final meter = ref.read(vpnControllerProvider.notifier).meter;
    final sel = nodes.selected;
    var phase = orbPhaseFor(vpn.state, busy: _busy);
    if (phase == OrbPhase.idle && _localError != null) phase = OrbPhase.error;
    final errorText = vpn.state == VpnState.error
        ? (vpn.message ?? '核心报告错误')
        : (phase == OrbPhase.error ? _localError : null);
    final connected = vpn.state == VpnState.started;
    final locked = _busy || vpn.state == VpnState.stopping;
    final latest = connected ? meter.latest : null;

    return ListView(
      padding: const EdgeInsets.only(bottom: Gaps.xl),
      children: [
        PageHeader(
          "WQ's Proxy VPN",
          subtitle: Text(
            connected && vpn.mode != null ? '路由模式：${vpn.mode!.label}' : 'sing-box 内核',
          ),
        ),
        AppCard(
          padding: const EdgeInsets.fromLTRB(Gaps.card, 8, Gaps.card, 20),
          highlight: connected ? kGood : (phase == OrbPhase.error ? kBad : null),
          child: Column(
            children: [
              ConnectOrb(
                phase: phase,
                onTap: locked || (sel == null && !connected) ? null : _toggle,
              ),
              SwapSwitcher(
                identity: phase,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.25),
                      end: Offset.zero,
                    ).animate(a),
                    child: child,
                  ),
                ),
                child: Text(
                  orbLabel(phase),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: orbColor(phase),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              _SessionClock(
                connectedAt: connected ? vpn.connectedAt : null,
                hint: switch (phase) {
                  OrbPhase.connecting => '正在启动 sing-box 内核，轻点可取消',
                  OrbPhase.preparing => '正在校验配置与 VPN 授权',
                  OrbPhase.disconnecting => '正在停止内核',
                  _ => sel == null ? '请先在“节点”页选择节点' : '轻点按钮连接',
                },
              ),
              AnimatedSize(
                duration: Motion.of(context, Motion.medium),
                curve: Curves.easeOutCubic,
                child: errorText == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          errorText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: kBad, fontSize: 13),
                        ),
                      ),
              ),
              const SizedBox(height: 14),
              _NodeStrip(
                name: sel?.name,
                detail: sel == null
                    ? null
                    : '${sel.protocol.label} · ${transportLabel(sel)}${sel.tls.isReality ? ' · REALITY' : (sel.tls.enabled ? ' · TLS' : '')}',
                latency: sel == null ? null : nodes.health[sel.id],
              ),
            ],
          ),
        ),
        const SectionTitle(
          '实时速度',
          info: '数据来自 sing-box 内核对 VPN 隧道流量的真实计数，约每 0.5 秒采样一次。\n'
              '曲线在两次真实采样之间用单调插值连线，并滞后约一个采样间隔滚动，以保证平滑；插值不会产生超出相邻两次实测值的数值，也不预测未来。\n'
              '这是“VPN 当前实际流量”，不是测速结果；没有流量时显示接近 0 是正常的。',
        ),
        AppCard(
          padding: const EdgeInsets.fromLTRB(Gaps.card, 14, Gaps.card, 12),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _Metric(
                      label: '下载',
                      value: formatBps(latest?.downBps),
                      color: kAccent,
                      icon: Icons.south_rounded,
                    ),
                  ),
                  Expanded(
                    child: _Metric(
                      label: '上传',
                      value: formatBps(latest?.upBps),
                      color: kUpload,
                      icon: Icons.north_rounded,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 150,
                child: SwapSwitcher(
                identity: connected && meter.hasData,
                child: connected && meter.hasData
                      ? LiveSpeedChart(
                          meter: meter,
                          active: connected,
                          sampleCount: vpn.tick,
                        )
                      : Center(
                          child: Text(
                            connected ? '等待首个采样…' : '连接 VPN 后显示实时流量',
                            style: const TextStyle(color: AppColors.textMuted),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              const Row(
                children: [
                  _Legend(color: kAccent, label: '下载'),
                  SizedBox(width: 16),
                  _Legend(color: kUpload, label: '上传'),
                  Spacer(),
                  Text(
                    '最近 60 秒',
                    style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SectionTitle('本次会话'),
        AppCard(
          child: LayoutBuilder(
            builder: (context, c) {
              final w = (c.maxWidth - Gaps.md) / 2;
              String v(String Function() f) =>
                  connected && meter.hasData ? f() : '—';
              return Wrap(
                spacing: Gaps.md,
                runSpacing: 14,
                children: [
                  _Stat(w, '累计下载', v(() => formatBytes(meter.sessionRxBytes))),
                  _Stat(w, '累计上传', v(() => formatBytes(meter.sessionTxBytes))),
                  _Stat(w, '下载峰值', v(() => formatBps(meter.peakDownBps))),
                  _Stat(w, '上传峰值', v(() => formatBps(meter.peakUpBps))),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 会话时长：独立的每秒计时器，只重建这一行文字，不重建整页。
class _SessionClock extends StatefulWidget {
  const _SessionClock({required this.connectedAt, required this.hint});
  final DateTime? connectedAt;
  final String hint;
  @override
  State<_SessionClock> createState() => _SessionClockState();
}

class _SessionClockState extends State<_SessionClock> {
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_SessionClock old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.connectedAt != null && _t == null) {
      _t = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (widget.connectedAt == null) {
      _t?.cancel();
      _t = null;
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    widget.connectedAt == null
        ? widget.hint
        : '已连接 ${formatDuration(DateTime.now().difference(widget.connectedAt!))}',
    style: const TextStyle(
      fontSize: 13,
      color: AppColors.textTertiary,
      fontFeatures: _tabular,
    ),
  );
}

class _NodeStrip extends StatelessWidget {
  const _NodeStrip({this.name, this.detail, this.latency});
  final String? name;
  final String? detail;
  final NodeHealth? latency;
  @override
  Widget build(BuildContext context) {
    final h = latency;
    String? lat;
    Color latColor = AppColors.textTertiary;
    if (h?.lastLatencyMs != null && h?.lastError == null) {
      lat = '${h!.lastLatencyMs} ms';
      latColor = h.method == 'proxy' ? kGood : AppColors.textSecondary;
    } else if (h?.lastError != null) {
      lat = '检测失败';
      latColor = kBad;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: [
          const Icon(Icons.dns_rounded, size: 18, color: AppColors.textTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name ?? '未选择节点',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  detail ?? '请到“节点”页添加或选择节点',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          if (lat != null) ...[
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  lat,
                  style: TextStyle(
                    color: latColor,
                    fontWeight: FontWeight.w600,
                    fontFeatures: _tabular,
                  ),
                ),
                Text(
                  h!.method == 'proxy'
                      ? '代理延迟'
                      : (h.method == 'tls' ? 'TLS 握手' : '仅 TCP'),
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });
  final String label;
  final String value;
  final Color color;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
          ),
        ],
      ),
      const SizedBox(height: 2),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          value,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            fontFeatures: _tabular,
          ),
        ),
      ),
    ],
  );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 3,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 6),
      Text(
        label,
        style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
      ),
    ],
  );
}

class _Stat extends StatelessWidget {
  const _Stat(this.width, this.title, this.value);
  final double width;
  final String title;
  final String value;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            fontFeatures: _tabular,
          ),
        ),
      ],
    ),
  );
}
