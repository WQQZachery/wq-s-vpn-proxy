// SPDX-License-Identifier: GPL-3.0-or-later
// 开发机冒烟测试：用真实网络跑一次测速引擎（不在 App 中使用）。
// 用法：dart run tool/speedtest_smoke.dart [mlab|cloudflare] [代理 host:port]
import 'dart:io';

import 'package:proxypilot_mobile/core/networking/speedtest/speedtest_engine.dart';
import 'package:proxypilot_mobile/core/networking/speedtest/throughput.dart';

Future<void> main(List<String> args) async {
  final which = args.isNotEmpty ? args[0] : 'auto';
  final proxy = args.length > 1 ? args[1] : null;
  final s = SpeedTestSession(
    config: const SpeedTestConfig(phaseDuration: Duration(seconds: 6)),
    clientFactory: () {
      final c = HttpClient();
      if (proxy != null) c.findProxy = (_) => 'PROXY $proxy';
      return c;
    },
  );
  var lastPhase = SpeedPhase.idle;
  var n = 0;
  s.progress.listen((p) {
    if (args.contains('-v') && (p.phase == SpeedPhase.download || p.phase == SpeedPhase.upload) && n++ % 3 == 0) {
      stdout.writeln('  ${p.phase.name} ${(p.phaseProgress * 100).toStringAsFixed(0)}% raw=${formatMbps(p.rawBps)} Mbps');
    }
    if (p.phase != lastPhase) {
      lastPhase = p.phase;
      stdout.writeln('== ${p.phase.label} ${p.server?.name ?? ''} ${p.server?.location ?? ''}');
    }
  });
  final servers = await s.discover();
  final cands = await s.probeCandidates(servers);
  for (final c in cands) {
    stdout.writeln('候选 ${c.server.name} @ ${c.server.location} : ${c.latency?.medianMs.toStringAsFixed(1) ?? c.error} ms');
  }
  SpeedServer? pick;
  if (which != 'auto') {
    pick = cands.firstWhere((c) => c.server.provider.name == which && c.reachable).server;
  }
  final r = await s.run(preferred: pick, knownCandidates: cands);
  stdout.writeln('结果：${r.phase.label} ${r.message ?? ''}');
  stdout.writeln('服务器 ${r.server?.name} ${r.server?.location}');
  stdout.writeln('延迟 ${r.latency?.medianMs.toStringAsFixed(1)} ms 抖动 ${r.latency?.jitterMs.toStringAsFixed(1)} ms');
  stdout.writeln('下载 ${formatMbps(r.downloadBps ?? 0)} Mbps (${r.downloadBytes} B, warm=${r.downloadWarm})');
  stdout.writeln('上传 ${formatMbps(r.uploadBps ?? 0)} Mbps (${r.uploadBytes} B, warm=${r.uploadWarm})');
  await s.dispose();
  exit(0);
}
