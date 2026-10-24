// SPDX-License-Identifier: GPL-3.0-or-later
// 检测中心：每项检测真实执行，结果统一保存（状态、耗时、时间戳、方式、错误原因）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state.dart';
import '../../app/theme.dart';
import '../../core/models/models.dart';
import '../../core/networking/probes.dart';
import '../../core/reputation/ip_reputation.dart';
import '../speedtest/speedtest_page.dart';
import 'reputation_panel.dart';

final _reputation = IpReputationService();

class DiagnosticsPage extends ConsumerStatefulWidget {
  const DiagnosticsPage({super.key});
  @override
  ConsumerState<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends ConsumerState<DiagnosticsPage> {
  final Set<String> _running = {};
  ExitIpInfo? _ip;
  String? _ipError;
  ReputationReport? _rep;
  ReputationException? _repError;
  List<ProbeResult> _history = [];
  final _customUrl = TextEditingController(
    text: 'https://www.google.com/generate_204',
  );

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final h = await ref.read(databaseProvider).listProbes();
    if (mounted) setState(() => _history = h);
  }

  Future<void> _run(String key, Future<void> Function() f) async {
    if (_running.contains(key)) return;
    setState(() => _running.add(key));
    try {
      await f();
    } finally {
      if (mounted) setState(() => _running.remove(key));
      await _loadHistory();
    }
  }

  NetworkProbes get _probes => NetworkProbes(
    methodLabel: probeMethodLabel(ref.read(vpnControllerProvider)),
  );

  Future<void> _save(ProbeResult r) => ref.read(databaseProvider).addProbe(r);

  ProbeResult _withConclusion(ProbeResult r, String kind, String conclusion) =>
      ProbeResult(
        kind: kind,
        target: r.target,
        method: r.method,
        status: r.status,
        timestamp: r.timestamp,
        totalMs: r.totalMs,
        errorKind: r.errorKind,
        errorMessage: r.errorMessage,
        httpStatus: r.httpStatus,
        steps: r.steps,
        data: r.data,
        conclusion: conclusion,
      );

  Future<void> _exitIp() => _run('ip', () async {
    final sw = Stopwatch()..start();
    try {
      final ip = await _reputation.fetchExitIp();
      setState(() {
        _ip = ip;
        _ipError = null;
      });
      await _save(
        ProbeResult(
          kind: 'exit_ip',
          target: ip.source,
          method: probeMethodLabel(ref.read(vpnControllerProvider)),
          status: ProbeStatus.success,
          timestamp: DateTime.now(),
          totalMs: sw.elapsedMilliseconds,
          data: ip.toJson(),
          conclusion: '出口 IP ${ip.ip}',
        ),
      );
    } on ReputationException catch (e) {
      setState(() => _ipError = e.message);
      await _save(
        ProbeResult(
          kind: 'exit_ip',
          target: 'api.ip.sb / ipinfo.io',
          method: probeMethodLabel(ref.read(vpnControllerProvider)),
          status: ProbeStatus.failure,
          timestamp: DateTime.now(),
          totalMs: sw.elapsedMilliseconds,
          errorKind: e.kind,
          errorMessage: e.message,
          conclusion: '检测失败',
        ),
      );
    }
  });

  Future<void> _reputationCheck() => _run('rep', () async {
    final key = ref.read(settingsProvider).abuseIpDbKey;
    final ip = _ip?.ip;
    if (ip == null) return;
    final sw = Stopwatch()..start();
    try {
      final r = await _reputation.checkAbuseIpDb(ip, key);
      setState(() {
        _rep = r;
        _repError = null;
      });
      await _save(
        ProbeResult(
          kind: 'reputation',
          target: 'AbuseIPDB',
          method: 'HTTPS API',
          status: ProbeStatus.success,
          timestamp: DateTime.now(),
          totalMs: sw.elapsedMilliseconds,
          data: {
            for (final f in r.fields) f.key: f.value,
            'fromCache': r.fromCache,
          },
        ),
      );
    } on ReputationException catch (e) {
      setState(() {
        _rep = null;
        _repError = e;
      });
      await _save(
        ProbeResult(
          kind: 'reputation',
          target: 'AbuseIPDB',
          method: 'HTTPS API',
          status: ProbeStatus.failure,
          timestamp: DateTime.now(),
          totalMs: sw.elapsedMilliseconds,
          errorKind: e.kind,
          errorMessage: e.message,
          conclusion: '数据不可用',
        ),
      );
    }
  });

  Future<void> _cloudflare() => _run('cf', () async {
    final url = Uri.parse(ref.read(settingsProvider).cloudflareTarget);
    final r = await _probes.fullCheck(url, kind: 'cloudflare');
    await _save(_withConclusion(r, 'cloudflare', cloudflareConclusion(r)));
  });

  Future<void> _claude() => _run('claude', () async {
    final url = Uri.parse(ref.read(settingsProvider).claudeTarget);
    final r = await _probes.fullCheck(url, kind: 'claude');
    await _save(_withConclusion(r, 'claude', claudeConclusion(r)));
  });

  Future<void> _custom() => _run('custom', () async {
    final u = Uri.tryParse(_customUrl.text.trim());
    if (u == null || !u.hasScheme || u.host.isEmpty) {
      showSnack(context, 'URL 无效');
      return;
    }
    final r = await _probes.fullCheck(u, kind: 'https');
    await _save(
      _withConclusion(
        r,
        'https',
        r.ok
            ? 'DNS/TCP/TLS/HTTP 均完成，HTTP ${r.httpStatus}'
            : '失败于：${r.steps.lastWhere((s) => !s.ok, orElse: () => r.steps.last).name}（${r.errorKind.label}）',
      ),
    );
  });

  /// 一键：先查出口 IP，成功且已配置 Key 时继续查信誉。
  Future<void> _ipAndReputation() async {
    await _exitIp();
    if (!mounted || _ip == null) return;
    if (ref.read(settingsProvider).abuseIpDbKey.isEmpty) {
      setState(() {
        _rep = null;
        _repError = ReputationException(
          ProbeErrorKind.apiUnavailable,
          '未配置 AbuseIPDB API Key',
          ReputationFailure.noKey,
        );
      });
      return;
    }
    await _reputationCheck();
  }

  Widget _btn(String key, String label, IconData icon, VoidCallback onTap) =>
      ActionChip(
        avatar: _running.contains(key)
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, size: 18),
        label: Text(label),
        onPressed: _running.contains(key) ? null : onTap,
      );

  @override
  Widget build(BuildContext context) {
    final vpn = ref.watch(vpnControllerProvider);
    final hasKey = ref.watch(settingsProvider.select((s) => s.abuseIpDbKey.isNotEmpty));
    final ipBusy = _running.contains('ip') || _running.contains('rep');
    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: ListView(
        padding: const EdgeInsets.only(bottom: Gaps.xl),
        children: [
          PageHeader(
            '检测中心',
            subtitle: Text('当前检测路径：${probeMethodLabel(vpn)}'),
            trailing: const InfoTip(
              title: '这里的检测分别说明什么',
              message: '• 主动测速：真实传输数据，测延迟、下载、上传速度。\n'
                  '• 出口 IP 与 IP 信誉：别人看到的你的 IP，以及该 IP 在 AbuseIPDB 中被举报的情况。它与速度、节点延迟无关。\n'
                  '• 节点延迟：在“节点”页，衡量连到各节点有多快。\n'
                  '• 连通性检测：某个网站（如 Cloudflare、Claude）在网络层面能否到达。\n'
                  '这些结果都不能单独判断“隐私是否安全”：隐私还取决于 DNS 设置、应用自身行为、节点运营方等。',
            ),
          ),
          AppCard(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SpeedTestPage()),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: kAccent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: const Icon(Icons.speed_rounded, color: kAccent),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('主动测速', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                      SizedBox(height: 2),
                      Text(
                        '自动选择测试服务器，测量延迟、抖动、下载与上传',
                        style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
              ],
            ),
          ),
          const SectionTitle(
            '出口 IP 与 IP 信誉',
            info: '出口 IP：网站和服务看到的你的 IP 地址（VPN 开启时通常是节点的 IP）。数据来自 api.ip.sb（失败时 ipinfo.io），归属地由服务商估算，可能不精确。\n\n'
                'IP 信誉：用 AbuseIPDB 查询这个出口 IP 过去 90 天被其他网站管理员举报的情况。它只反映“举报记录”，不是节点质量、速度或隐私安全性的评分。\n\n'
                '隐私提示：查询会把你的出口 IP 发送给上述服务。',
          ),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gaps.card, 14, 8, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '出口 IP',
                              style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
                            ),
                            const SizedBox(height: 2),
                            SwapSwitcher(
                              identity: _ip?.ip ?? _ipError,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                _ip?.ip ?? (_ipError != null ? '查询失败' : '尚未查询'),
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: _ip == null && _ipError != null ? kBad : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: ipBusy ? null : _ipAndReputation,
                        icon: ipBusy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(_ip == null ? '查询' : '重新查询'),
                      ),
                    ],
                  ),
                ),
                if (_ipError != null && _ip == null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gaps.card, 0, Gaps.card, 12),
                    child: Text(_ipError!, style: const TextStyle(color: kBad, fontSize: 13)),
                  ),
                if (_ip != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gaps.card, 0, Gaps.card, 10),
                    child: Column(
                      children: [
                        KvRow('网络 / ASN', [_ip!.org, _ip!.asn].whereType<String>().where((e) => e.isNotEmpty).join(' · ').ifEmpty('（服务未返回）')),
                        KvRow(
                          '归属地',
                          [_ip!.country, _ip!.region, _ip!.city]
                              .whereType<String>()
                              .where((e) => e.isNotEmpty)
                              .join(' / ')
                              .ifEmpty('（服务未返回）'),
                          info: '由 IP 库估算，可能与节点实际所在地不同。',
                        ),
                        KvRow(
                          '数据来源',
                          '${_ip!.source} · ${_ip!.fetchedAt.toLocal().toString().substring(11, 19)}',
                        ),
                      ],
                    ),
                  ),
                const Divider(),
                ReputationPanel(
                  ip: _ip?.ip,
                  report: _rep,
                  error: _repError,
                  hasKey: hasKey,
                  loading: _running.contains('rep'),
                  onRetry: _ip == null || _running.contains('rep') ? null : _reputationCheck,
                ),
              ],
            ),
          ),
          const SectionTitle(
            '连通性检测',
            info: '逐步执行 DNS / TCP / TLS / HTTP，判断目标在网络层面能否到达。只证明网络可达，不代表账户可用或网页一定能正常打开。',
          ),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _btn('cf', 'Cloudflare', Icons.cloud_outlined, _cloudflare),
                    _btn('claude', 'Claude', Icons.smart_toy_outlined, _claude),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _customUrl,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: '自定义 HTTPS 目标',
                          prefixIcon: Icon(Icons.link_rounded, size: 18),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _btn('custom', '检测', Icons.play_arrow_rounded, _custom),
                  ],
                ),
              ],
            ),
          ),
          SectionTitle(
            '检测历史',
            trailing: TextButton(
              onPressed: _history.isEmpty
                  ? null
                  : () async {
                      await ref.read(databaseProvider).clearProbes();
                      await _loadHistory();
                    },
              child: const Text('清空'),
            ),
          ),
          if (_history.isEmpty)
            const EmptyState(
              icon: Icons.history_rounded,
              title: '暂无记录',
              message: '执行的每项检测都会保存在这里（含耗时、方式与错误原因）。',
            ),
          for (final r in _history) _historyTile(r),
        ],
      ),
    );
  }

  Widget _historyTile(ProbeResult r) {
    final color = switch (r.status) {
      ProbeStatus.success => kGood,
      ProbeStatus.partial => kWarn,
      ProbeStatus.failure => kBad,
      ProbeStatus.skipped => Colors.white38,
    };
    const names = {
      'cloudflare': 'Cloudflare',
      'claude': 'Claude',
      'exit_ip': '出口 IP',
      'reputation': 'IP 信誉',
      'https': 'HTTPS',
      'speedtest': '主动测速',
    };
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        leading: Icon(r.ok ? Icons.check_circle : Icons.error, color: color),
        title: Text(
          '${names[r.kind] ?? r.kind} · ${r.totalMs} ms${r.httpStatus != null ? ' · HTTP ${r.httpStatus}' : ''}',
        ),
        subtitle: Text(
          '${r.timestamp.toLocal().toString().substring(5, 19)} · ${r.errorKind == ProbeErrorKind.none ? '成功' : r.errorKind.label}',
          style: const TextStyle(fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('目标：${r.target}', style: const TextStyle(fontSize: 12)),
          Text('方式：${r.method}', style: const TextStyle(fontSize: 12)),
          for (final s in r.steps)
            Text(
              '${s.ok ? '✓' : '✗'} ${s.name}${s.durationMs != null ? ' ${s.durationMs} ms' : ''}${s.detail != null ? ' — ${s.detail}' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
          if (r.errorMessage != null)
            Text(
              '错误：${r.errorMessage}',
              style: const TextStyle(fontSize: 12, color: kBad),
            ),
          if (r.conclusion != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '结论：${r.conclusion}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
