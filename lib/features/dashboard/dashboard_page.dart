// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state.dart';
import '../../app/theme.dart';
import '../../core/engine/traffic_meter.dart';
import '../../core/models/models.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});
  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  Timer? _clock;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(vpnControllerProvider).state == VpnState.started)
        setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    final ctrl = ref.read(vpnControllerProvider.notifier);
    final s = ref.read(vpnControllerProvider).state;
    setState(() => _busy = true);
    try {
      if (s == VpnState.started || s == VpnState.starting) {
        await ctrl.disconnect();
      } else {
        final err = await ctrl.connect();
        if (err != null && mounted) showSnack(context, err);
      }
    } catch (e) {
      if (mounted) showSnack(context, '操作失败：$e');
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
    final health = sel == null ? null : nodes.health[sel.id];
    final (label, color) = switch (vpn.state) {
      VpnState.started => ('已连接', kGood),
      VpnState.starting => ('连接中…', kWarn),
      VpnState.stopping => ('断开中…', kWarn),
      VpnState.error => ('错误', kBad),
      VpnState.stopped => ('未连接', Colors.white54),
    };
    final connected = vpn.state == VpnState.started;
    final latest = connected ? meter.latest : null;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Text(
            "WQ's Proxy VPN",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                GestureDetector(
                  onTap: _busy ? null : _toggle,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color.withValues(alpha: 0.15),
                      border: Border.all(color: color, width: 3),
                    ),
                    child: Center(
                      child:
                          _busy ||
                              vpn.state == VpnState.starting ||
                              vpn.state == VpnState.stopping
                          ? const CircularProgressIndicator()
                          : Icon(
                              Icons.power_settings_new,
                              size: 64,
                              color: color,
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 20,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (vpn.message != null && vpn.state == VpnState.error)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      vpn.message!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: kBad),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  sel == null ? '未选择节点（请到“节点”页添加）' : '当前节点：${sel.name}',
                  style: const TextStyle(color: Colors.white70),
                ),
                if (connected && vpn.mode != null)
                  Text(
                    '路由：${vpn.mode!.label}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
              ],
            ),
          ),
        ),
        const SectionTitle('实时速度（VPN 实际流量）'),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 16, 8),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _metric(
                      '下载',
                      formatBps(latest?.downBps),
                      Icons.arrow_downward,
                      kAccent,
                    ),
                    _metric(
                      '上传',
                      formatBps(latest?.upBps),
                      Icons.arrow_upward,
                      kGood,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 140,
                  child: connected && meter.hasData
                      ? _chart(meter)
                      : const Center(
                          child: Text(
                            '暂无数据',
                            style: TextStyle(color: Colors.white38),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        const SectionTitle('会话统计'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _stat(
                  '会话时长',
                  connected && vpn.connectedAt != null
                      ? formatDuration(
                          DateTime.now().difference(vpn.connectedAt!),
                        )
                      : '—',
                ),
                _stat(
                  '累计下载',
                  connected && meter.hasData
                      ? formatBytes(meter.sessionRxBytes)
                      : '暂无数据',
                ),
                _stat(
                  '累计上传',
                  connected && meter.hasData
                      ? formatBytes(meter.sessionTxBytes)
                      : '暂无数据',
                ),
                _stat(
                  '下载峰值',
                  connected && meter.hasData
                      ? formatBps(meter.peakDownBps)
                      : '暂无数据',
                ),
                _stat(
                  '上传峰值',
                  connected && meter.hasData
                      ? formatBps(meter.peakUpBps)
                      : '暂无数据',
                ),
                _stat(
                  '节点延迟',
                  health?.lastLatencyMs != null
                      ? '${health!.lastLatencyMs} ms（${health.method == 'proxy' ? '代理' : '仅TCP'}）'
                      : (health?.lastError != null ? '测试失败' : '未测试'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _metric(String t, String v, IconData i, Color c) => Column(
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(i, size: 16, color: c),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(color: Colors.white60)),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        v,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
    ],
  );

  Widget _stat(String t, String v) => SizedBox(
    width: 150,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 2),
        Text(
          v,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ],
    ),
  );

  Widget _chart(TrafficMeter m) {
    final s = m.samples;
    final t0 = s.first.timestampMs;
    List<FlSpot> spots(double Function(SpeedSample) f) => [
      for (final x in s) FlSpot((x.timestampMs - t0) / 1000, f(x) / 1e6),
    ];
    return LineChart(
      LineChartData(
        minY: 0,
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          bottomTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(1),
                style: const TextStyle(fontSize: 10, color: Colors.white38),
              ),
            ),
          ),
        ),
        lineTouchData: const LineTouchData(enabled: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots((x) => x.downBps),
            isCurved: true,
            color: kAccent,
            dotData: const FlDotData(show: false),
            barWidth: 2,
          ),
          LineChartBarData(
            spots: spots((x) => x.upBps),
            isCurved: true,
            color: kGood,
            dotData: const FlDotData(show: false),
            barWidth: 2,
          ),
        ],
      ),
      duration: Duration.zero,
    );
  }
}
