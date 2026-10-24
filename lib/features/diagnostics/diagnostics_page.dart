// SPDX-License-Identifier: GPL-3.0-or-later
// 检测中心：每项检测真实执行，结果统一保存（状态、耗时、时间戳、方式、错误原因）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state.dart';
import '../../app/theme.dart';
import '../../core/engine/traffic_meter.dart';
import '../../core/models/models.dart';
import '../../core/networking/probes.dart';
import '../../core/networking/speed_test.dart';
import '../../core/reputation/ip_reputation.dart';

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
  String? _repError;
  List<ProbeResult> _history = [];
  List<SpeedTestResult> _speed = [];
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
    if (ip == null) {
      setState(() => _repError = '请先查询出口 IP');
      return;
    }
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
      setState(() => _repError = '${e.kind.label}：${e.message}');
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

  Future<void> _speedTest() => _run('speed', () async {
    final t = SpeedTester();
    final d = await t.download();
    final u = await t.upload();
    setState(() => _speed = [d, u]);
  });

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
    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Text(
              '检测中心',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              '当前检测方式：${probeMethodLabel(vpn)}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _btn('ip', '出口 IP', Icons.public, _exitIp),
                _btn(
                  'rep',
                  'IP 信誉',
                  Icons.verified_user_outlined,
                  _reputationCheck,
                ),
                _btn('cf', 'Cloudflare', Icons.cloud_outlined, _cloudflare),
                _btn('claude', 'Claude', Icons.smart_toy_outlined, _claude),
                _btn('speed', '主动测速', Icons.speed, _speedTest),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              '隐私提示：出口 IP 查询会把你的出口 IP 发送给 api.ip.sb（失败时 ipinfo.io）；IP 信誉会发送给 AbuseIPDB；测速连接 speed.cloudflare.com。',
              style: TextStyle(fontSize: 11, color: Colors.white38),
            ),
          ),
          const SectionTitle('出口 IP'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _ip == null
                  ? Text(
                      _ipError ?? '尚未检测',
                      style: TextStyle(
                        color: _ipError != null ? kBad : Colors.white54,
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _ip!.ip,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _kv('ASN', _ip!.asn),
                        _kv('网络', _ip!.org),
                        _kv('ISP', _ip!.isp),
                        _kv(
                          '地区',
                          [_ip!.country, _ip!.region, _ip!.city]
                              .whereType<String>()
                              .where((e) => e.isNotEmpty)
                              .join(' / '),
                        ),
                        _kv('数据来源', '${_ip!.source}（服务商提供，可能不精确）'),
                        _kv(
                          '更新时间',
                          _ip!.fetchedAt.toLocal().toString().substring(0, 19),
                        ),
                      ],
                    ),
            ),
          ),
          const SectionTitle('IP 信誉（AbuseIPDB）'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _rep == null
                  ? Text(
                      _repError ??
                          (ref.watch(settingsProvider).abuseIpDbKey.isEmpty
                              ? '未配置 API Key（设置 → API 配置）'
                              : '尚未检测'),
                      style: TextStyle(
                        color: _repError != null ? kBad : Colors.white54,
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '来源：${_rep!.provider} · ${_rep!.fetchedAt.toLocal().toString().substring(0, 19)}${_rep!.fromCache ? '（缓存）' : ''}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        for (final f in _rep!.fields)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${f.key}：${f.value}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  f.definition,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.white38,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          const SectionTitle('自定义 HTTPS 检测（DNS / TCP / TLS / HTTP）'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _customUrl,
                      decoration: const InputDecoration(labelText: '目标 URL'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _btn('custom', '检测', Icons.play_arrow, _custom),
                ],
              ),
            ),
          ),
          if (_speed.isNotEmpty) ...[
            const SectionTitle('主动测速结果（非 VPN 实时流量）'),
            Card(
              child: Column(
                children: [
                  for (final s in _speed)
                    ListTile(
                      title: Text(
                        '${s.direction}：${s.error == null ? formatBps(s.bps) : '失败'}',
                      ),
                      subtitle: Text(
                        '服务器 ${s.server} · ${formatBytes(s.bytes)} / ${s.ms} ms${s.error != null ? '\n${s.error}' : ''}',
                      ),
                    ),
                ],
              ),
            ),
          ],
          SectionTitle(
            '检测历史',
            trailing: TextButton(
              onPressed: () async {
                await ref.read(databaseProvider).clearProbes();
                await _loadHistory();
              },
              child: const Text('清空'),
            ),
          ),
          if (_history.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('暂无记录', style: TextStyle(color: Colors.white38)),
            ),
          for (final r in _history) _historyTile(r),
        ],
      ),
    );
  }

  Widget _kv(String k, String? v) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Text(
      '$k：${(v == null || v.isEmpty) ? '（服务未返回）' : v}',
      style: const TextStyle(fontSize: 13),
    ),
  );

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
