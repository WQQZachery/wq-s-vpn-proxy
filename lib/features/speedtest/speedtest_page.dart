// SPDX-License-Identifier: GPL-3.0-or-later
// 主动测速页（Speedtest 风格）。与首页“实时速度”（VPN 当前实际流量）完全独立：这里主动产生测试流量。
import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state.dart';
import '../../app/theme.dart';
import '../../core/models/models.dart';
import '../../core/networking/speedtest/speedtest_engine.dart';
import '../../core/networking/speedtest/throughput.dart';
import 'speed_gauge.dart';

const _tabular = [FontFeature.tabularFigures()];

class SpeedTestPage extends ConsumerStatefulWidget {
  const SpeedTestPage({super.key, this.sessionFactory});

  /// 测试注入点。
  final SpeedTestSession Function()? sessionFactory;
  @override
  ConsumerState<SpeedTestPage> createState() => _SpeedTestPageState();
}

class _SpeedTestPageState extends ConsumerState<SpeedTestPage> {
  SpeedTestSession? _session;
  StreamSubscription<SpeedProgress>? _sub;
  SpeedProgress _p = const SpeedProgress(phase: SpeedPhase.idle);
  List<ServerCandidate>? _candidates;
  SpeedServer? _manual; // null = 自动选择
  bool _probing = false;
  String? _pathLabel;
  DateTime? _finishedAt;

  bool get _running => switch (_p.phase) {
    SpeedPhase.preparing ||
    SpeedPhase.selecting ||
    SpeedPhase.latency ||
    SpeedPhase.download ||
    SpeedPhase.upload => true,
    _ => false,
  };

  SpeedTestSession _newSession() =>
      widget.sessionFactory?.call() ?? SpeedTestSession();

  @override
  void dispose() {
    _sub?.cancel();
    _session?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_running) return;
    await _sub?.cancel();
    await _session?.dispose();
    final s = _newSession();
    _session = s;
    final vpn = ref.read(vpnControllerProvider);
    _pathLabel = vpn.state == VpnState.started
        ? '经 VPN（节点：${vpn.nodeName ?? '?'}）'
        : '直连（VPN 未开启）';
    _finishedAt = null;
    _sub = s.progress.listen((p) {
      if (mounted) setState(() => _p = p);
    });
    // 已有新近的候选探测结果时复用，避免重复探测
    final r = await s.run(preferred: _manual, knownCandidates: _candidates);
    if (!mounted) return;
    setState(() {
      _p = r;
      if (r.candidates.isNotEmpty) _candidates = r.candidates;
      _finishedAt = DateTime.now();
    });
    await _saveHistory(r);
  }

  Future<void> _saveHistory(SpeedProgress r) async {
    if (r.phase == SpeedPhase.cancelled) return;
    final ok = r.phase == SpeedPhase.done;
    await ref
        .read(databaseProvider)
        .addProbe(
          ProbeResult(
            kind: 'speedtest',
            target: '${r.server?.providerLabel ?? '-'} ${r.server?.host ?? ''}',
            method: _pathLabel ?? '',
            status: ok ? ProbeStatus.success : ProbeStatus.failure,
            timestamp: DateTime.now(),
            totalMs: r.startedAt == null
                ? 0
                : DateTime.now().difference(r.startedAt!).inMilliseconds,
            errorKind: ok ? ProbeErrorKind.none : ProbeErrorKind.unknown,
            errorMessage: ok ? null : r.message,
            data: {
              'server': r.server?.name,
              'location': r.server?.location,
              'latencyMs': r.latency?.medianMs,
              'jitterMs': r.latency?.jitterMs,
              'downloadBps': r.downloadBps,
              'uploadBps': r.uploadBps,
            },
            conclusion: ok
                ? '下载 ${formatMbps(r.downloadBps ?? 0)} Mbps · 上传 ${formatMbps(r.uploadBps ?? 0)} Mbps · 延迟 ${r.latency?.medianMs.toStringAsFixed(0)} ms'
                : '测速失败：${r.message}',
          ),
        );
  }

  void _cancel() => _session?.cancel();

  Future<void> _probe() async {
    if (_probing || _running) return;
    setState(() => _probing = true);
    final s = _newSession();
    try {
      final c = await s.probeCandidates(await s.discover());
      if (mounted) setState(() => _candidates = c);
    } catch (e) {
      if (mounted) showSnack(context, '探测失败：$e');
    } finally {
      await s.dispose();
      if (mounted) setState(() => _probing = false);
    }
  }

  void _pickServer() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (c, setSheet) {
          Future<void> reprobe() async {
            setSheet(() {});
            await _probe();
            setSheet(() {});
          }

          final list = _candidates;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.75,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gaps.page, 0, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '选择测试服务器',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _probing ? null : reprobe,
                          icon: _probing
                              ? const SizedBox.square(
                                  dimension: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.radar_rounded, size: 18),
                          label: Text(_probing ? '探测中' : '重新探测'),
                        ),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(Gaps.page, 0, Gaps.page, 8),
                    child: Text(
                      '延迟为对各服务器的 HTTP 往返实测中位数。自动选择按实测延迟（含抖动、丢失惩罚）排序，不按地理距离。服务器负载数据各平台未公开，因此不显示。',
                      style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        RadioListTile<String>(
                          value: '',
                          groupValue: _manual?.id ?? '',
                          onChanged: (_) {
                            setState(() => _manual = null);
                            Navigator.pop(c);
                          },
                          title: const Text('自动选择'),
                          subtitle: const Text('开始测试时选延迟最低的可达服务器'),
                        ),
                        if (list == null)
                          const Padding(
                            padding: EdgeInsets.all(Gaps.page),
                            child: Text(
                              '尚未探测。点“重新探测”获取候选服务器及其延迟。',
                              style: TextStyle(color: AppColors.textTertiary),
                            ),
                          )
                        else
                          for (final cand in list)
                            RadioListTile<String>(
                              value: cand.server.id,
                              groupValue: _manual?.id ?? '',
                              onChanged: cand.reachable
                                  ? (_) {
                                      setState(() => _manual = cand.server);
                                      Navigator.pop(c);
                                    }
                                  : null,
                              title: Text(cand.server.name),
                              subtitle: Text(
                                '${cand.server.providerLabel} · ${cand.server.location ?? '位置未知'}',
                              ),
                              secondary: Text(
                                cand.reachable
                                    ? '${cand.latency!.medianMs.toStringAsFixed(0)} ms'
                                    : (cand.error ?? '不可达'),
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: cand.reachable ? null : kBad,
                                  fontFeatures: _tabular,
                                ),
                              ),
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final phase = p.phase;
    final (gaugeColor, caption) = switch (phase) {
      SpeedPhase.upload => (kUpload, '上传中 · 实时（平滑显示）'),
      SpeedPhase.download => (kAccent, '下载中 · 实时（平滑显示）'),
      SpeedPhase.latency => (kWarn, '测量延迟'),
      SpeedPhase.selecting => (kWarn, '寻找测试服务器'),
      SpeedPhase.preparing => (kWarn, '准备中'),
      SpeedPhase.done => (kGood, '测试完成'),
      SpeedPhase.failed => (kBad, '测试失败'),
      SpeedPhase.cancelled => (AppColors.idle, '已取消'),
      SpeedPhase.idle => (AppColors.idle, '准备就绪'),
    };
    final showLatencyInCenter =
        phase == SpeedPhase.latency && p.latency != null;
    final server = p.server ?? _manual;

    return Scaffold(
      appBar: AppBar(
        title: const Text('主动测速'),
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _PhaseStepper(phase: phase),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gaps.page + 8),
            child: SpeedGauge(
              targetBps: _running ? p.rawBps : 0,
              color: gaugeColor,
              caption: caption,
              centerOverride: showLatencyInCenter
                  ? p.latency!.medianMs.toStringAsFixed(0)
                  : (!_running ? '—' : null),
              unitOverride: showLatencyInCenter ? 'ms（中位数）' : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gaps.page),
            child: Row(
              children: [
                Expanded(
                  child: _ResultTile(
                    label: '下载',
                    icon: Icons.south_rounded,
                    color: kAccent,
                    value: p.downloadBps != null
                        ? formatMbps(p.downloadBps!)
                        : (phase == SpeedPhase.download ? '测量中' : '—'),
                    unit: p.downloadBps != null ? 'Mbps' : null,
                  ),
                ),
                const SizedBox(width: Gaps.sm),
                Expanded(
                  child: _ResultTile(
                    label: '上传',
                    icon: Icons.north_rounded,
                    color: kUpload,
                    value: p.uploadBps != null
                        ? formatMbps(p.uploadBps!)
                        : (phase == SpeedPhase.upload ? '测量中' : '—'),
                    unit: p.uploadBps != null ? 'Mbps' : null,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Gaps.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gaps.page),
            child: Row(
              children: [
                Expanded(
                  child: _SmallTile(
                    label: '延迟',
                    info: '对测试服务器连续 20 次 HTTP 往返（复用连接，首个含握手的请求不计）的中位数。',
                    value: p.latency == null
                        ? '—'
                        : '${p.latency!.medianMs.toStringAsFixed(0)} ms',
                  ),
                ),
                const SizedBox(width: Gaps.sm),
                Expanded(
                  child: _SmallTile(
                    label: '抖动',
                    info: '相邻两次往返时间差的平均值，反映延迟稳定性。',
                    value: p.latency == null
                        ? '—'
                        : '${p.latency!.jitterMs.toStringAsFixed(1)} ms',
                  ),
                ),
                const SizedBox(width: Gaps.sm),
                const Expanded(
                  child: _SmallTile(
                    label: '丢包',
                    info: '本测速基于 TCP（HTTPS / WebSocket），TCP 会自动重传丢失的数据包，应用层无法测得真实丢包率，因此不显示数值，以免误导。',
                    value: '不支持',
                    muted: true,
                  ),
                ),
              ],
            ),
          ),
          if (p.downloadSamples.isNotEmpty || p.uploadSamples.isNotEmpty) ...[
            const SectionTitle('实测速度曲线（原始采样）'),
            AppCard(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: SizedBox(
                height: 70,
                child: SpeedSparkline(
                  series: [
                    (
                      [for (final s in p.downloadSamples) (s.tMs, s.bps)],
                      kAccent,
                    ),
                    (
                      [for (final s in p.uploadSamples) (s.tMs, s.bps)],
                      kUpload,
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SectionTitle('测试服务器'),
          AppCard(
            onTap: _running ? null : _pickServer,
            child: Row(
              children: [
                const Icon(Icons.dns_rounded, color: AppColors.textTertiary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        server?.name ?? '自动选择',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        server == null
                            ? '开始后在 M-Lab 与 Cloudflare 候选中按实测延迟选择'
                            : '${server.providerLabel} · ${server.location ?? '位置未知'}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  _running ? '' : '更换',
                  style: const TextStyle(color: kAccent),
                ),
              ],
            ),
          ),
          if (phase == SpeedPhase.failed || phase == SpeedPhase.cancelled)
            AppCard(
              highlight: phase == SpeedPhase.failed ? kBad : null,
              child: Row(
                children: [
                  Icon(
                    phase == SpeedPhase.failed
                        ? Icons.error_outline_rounded
                        : Icons.cancel_outlined,
                    color: phase == SpeedPhase.failed ? kBad : AppColors.idle,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(p.message ?? phase.label)),
                ],
              ),
            ),
          if (phase == SpeedPhase.done) _Summary(p: p, path: _pathLabel, at: _finishedAt),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gaps.page, Gaps.lg, Gaps.page, 0),
            child: SizedBox(
              height: 52,
              child: SwapSwitcher(
                identity: _running,
                child: _running
                    ? OutlinedButton.icon(
                        onPressed: _cancel,
                        icon: const Icon(Icons.stop_rounded),
                        label: const Text('取消测试'),
                      )
                    : FilledButton.icon(
                        onPressed: _start,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(phase == SpeedPhase.idle ? '开始测试' : '再测一次'),
                      ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(Gaps.page, Gaps.lg, Gaps.page, 0),
            child: Text(
              '说明：测速会实际传输数十至数百 MB 数据（移动网络请注意流量）。结果受当前网络、代理节点（VPN 开启时）、测试服务器和设备状态共同影响，只代表本次测量。'
              '仪表盘指针为平滑后的显示值，结果以“下载/上传”数值为准（已排除前 2 秒预热）。\n'
              '隐私：使用 M-Lab 服务器时，M-Lab 会按其政策公开发布测量数据（包括你的出口 IP），详见 measurementlab.net/privacy；使用 Cloudflare 时适用 Cloudflare 隐私政策。',
              style: TextStyle(fontSize: 11, color: AppColors.textMuted, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhaseStepper extends StatelessWidget {
  const _PhaseStepper({required this.phase});
  final SpeedPhase phase;
  static const _steps = [
    (SpeedPhase.preparing, '准备'),
    (SpeedPhase.selecting, '选服务器'),
    (SpeedPhase.latency, '延迟'),
    (SpeedPhase.download, '下载'),
    (SpeedPhase.upload, '上传'),
    (SpeedPhase.done, '完成'),
  ];

  @override
  Widget build(BuildContext context) {
    final cur = _steps.indexWhere((s) => s.$1 == phase);
    final failed = phase == SpeedPhase.failed || phase == SpeedPhase.cancelled;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gaps.page, 8, Gaps.page, 4),
      child: Row(
        children: [
          for (var i = 0; i < _steps.length; i++) ...[
            Expanded(
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: Motion.of(context, Motion.medium),
                    curve: Curves.easeOutCubic,
                    height: 4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      color: cur < 0
                          ? AppColors.surfaceHigh
                          : i < cur || phase == SpeedPhase.done
                          ? kGood
                          : i == cur
                          ? (failed ? kBad : kAccent)
                          : AppColors.surfaceHigh,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _steps[i].$2,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: i == cur ? FontWeight.w700 : FontWeight.w500,
                      color: i == cur
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            if (i < _steps.length - 1) const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.label,
    required this.icon,
    required this.color,
    required this.value,
    this.unit,
  });
  final String label;
  final IconData icon;
  final Color color;
  final String value;
  final String? unit;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(Radii.md),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
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
        const SizedBox(height: 4),
        SwapSwitcher(
          identity: value,
          alignment: Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: value,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      fontFeatures: _tabular,
                    ),
                  ),
                  if (unit != null)
                    TextSpan(
                      text: ' $unit',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textTertiary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _SmallTile extends StatelessWidget {
  const _SmallTile({
    required this.label,
    required this.value,
    required this.info,
    this.muted = false,
  });
  final String label;
  final String value;
  final String info;
  final bool muted;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 6, 4, 10),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(Radii.md),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
              ),
            ),
            InfoTip(title: label, message: info),
          ],
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: muted ? AppColors.textMuted : null,
              fontFeatures: _tabular,
            ),
          ),
        ),
      ],
    ),
  );
}

class _Summary extends StatelessWidget {
  const _Summary({required this.p, this.path, this.at});
  final SpeedProgress p;
  final String? path;
  final DateTime? at;
  @override
  Widget build(BuildContext context) {
    final s = p.server;
    String mb(int b) => '${(b / 1e6).toStringAsFixed(1)} MB';
    return AppCard(
      highlight: kGood,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('结果摘要', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          KvRow('测试时间', at == null ? '—' : at!.toLocal().toString().substring(0, 19)),
          KvRow('服务器', s == null ? '—' : '${s.name}（${s.providerLabel}）'),
          KvRow('位置', s?.location ?? '位置未知（服务未提供）'),
          KvRow('网络路径', path ?? '—'),
          KvRow(
            '下载',
            '${formatMbps(p.downloadBps ?? 0)} Mbps · 传输 ${mb(p.downloadBytes)}${p.downloadWarm ? '' : ' · 时长不足，未完全排除预热'}',
          ),
          KvRow(
            '上传',
            '${formatMbps(p.uploadBps ?? 0)} Mbps · 传输 ${mb(p.uploadBytes)}${p.uploadWarm ? '' : ' · 时长不足，未完全排除预热'}',
          ),
          KvRow(
            '延迟 / 抖动',
            p.latency == null
                ? '—'
                : '${p.latency!.medianMs.toStringAsFixed(0)} ms / ${p.latency!.jitterMs.toStringAsFixed(1)} ms（${p.latency!.samples.length}/${p.latency!.attempts} 次成功）',
          ),
        ],
      ),
    );
  }
}
