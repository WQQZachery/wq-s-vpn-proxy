// SPDX-License-Identifier: GPL-3.0-or-later
// 1.1.0 体验升级相关的单元测试与组件测试。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypilot_mobile/app/ripple_nav.dart';
import 'package:proxypilot_mobile/app/theme.dart';
import 'package:proxypilot_mobile/core/engine/chart_math.dart';
import 'package:proxypilot_mobile/core/engine/latency_tester.dart';
import 'package:proxypilot_mobile/core/engine/traffic_meter.dart';
import 'package:proxypilot_mobile/core/models/models.dart';
import 'package:proxypilot_mobile/core/networking/speedtest/speedtest_engine.dart';
import 'package:proxypilot_mobile/core/networking/speedtest/throughput.dart';
import 'package:proxypilot_mobile/core/reputation/ip_reputation.dart';
import 'package:proxypilot_mobile/features/dashboard/connect_orb.dart';
import 'package:proxypilot_mobile/features/dashboard/live_speed_chart.dart';
import 'package:proxypilot_mobile/features/diagnostics/reputation_panel.dart';
import 'package:proxypilot_mobile/features/speedtest/speed_gauge.dart';

Widget _wrap(Widget child, {bool reduced = false}) => MaterialApp(
  theme: buildDarkTheme(),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Scaffold(body: child),
  ),
);

void main() {
  group('实时曲线数学', () {
    test('单调插值不会超出相邻两次真实采样的范围（不夸大数据）', () {
      final rnd = math.Random(42);
      for (var trial = 0; trial < 200; trial++) {
        final xs = <double>[];
        final ys = <double>[];
        var t = 0.0;
        for (var i = 0; i < 12; i++) {
          t += 300 + rnd.nextInt(400);
          xs.add(t);
          // 包含 0、突增、平台等情形
          ys.add(rnd.nextBool() ? 0 : rnd.nextDouble() * (rnd.nextBool() ? 1e8 : 1e5));
        }
        final m = monotoneTangents(xs, ys);
        for (var i = 0; i < xs.length - 1; i++) {
          final lo = math.min(ys[i], ys[i + 1]);
          final hi = math.max(ys[i], ys[i + 1]);
          for (var k = 0; k <= 20; k++) {
            final x = xs[i] + (xs[i + 1] - xs[i]) * k / 20;
            final v = hermiteAt(xs, ys, m, i, x);
            expect(v, greaterThanOrEqualTo(lo - 1e-6 * (hi + 1)));
            expect(v, lessThanOrEqualTo(hi + 1e-6 * (hi + 1)));
          }
        }
      }
    });

    test('插值曲线经过每一个真实采样点', () {
      final xs = <double>[0, 500, 1000, 1500];
      final ys = <double>[0, 8e6, 2e6, 2e6];
      final m = monotoneTangents(xs, ys);
      for (var i = 0; i < 3; i++) {
        expect(hermiteAt(xs, ys, m, i, xs[i]), closeTo(ys[i], 1e-6));
        expect(hermiteAt(xs, ys, m, i, xs[i + 1]), closeTo(ys[i + 1], 1e-6));
      }
    });

    test('niceCeil 取整刻度且留余量', () {
      expect(niceCeil(0, minimum: 100e3), 100e3);
      expect(niceCeil(8e6), 10e6);
      expect(niceCeil(1.9e6), 2.5e6);
      expect(niceCeil(40e6), 50e6);
    });

    test('平滑逼近与帧率无关（60Hz 与 120Hz 结果一致）', () {
      var a = 0.0, b = 0.0;
      for (var i = 0; i < 60; i++) {
        a = approach(a, 100, 1000 / 60, 300);
      }
      for (var i = 0; i < 120; i++) {
        b = approach(b, 100, 1000 / 120, 300);
      }
      expect(a, closeTo(b, 1e-9));
    });

    test('采样间隔估计取中位数', () {
      expect(estimateIntervalMs([0, 500, 1000, 1600, 2100]), 500);
      expect(estimateIntervalMs([1000]), 500);
    });
  });

  group('节点延迟调度', () {
    test('并发上限与结果按节点 id 对应', () async {
      var active = 0, peak = 0;
      final rnd = math.Random(1);
      final s = LatencyScheduler(
        concurrency: 4,
        stagger: Duration.zero,
        onChange: (_) {},
        probe: (id) async {
          active++;
          peak = math.max(peak, active);
          await Future<void>.delayed(Duration(milliseconds: rnd.nextInt(15)));
          active--;
          return ProbeOutcome.ok(int.parse(id), LatencyLayer.proxy);
        },
      );
      final ids = [for (var i = 1; i <= 30; i++) '$i'];
      s.enqueue(ids);
      await s.whenIdle();
      expect(peak, lessThanOrEqualTo(4));
      for (final id in ids) {
        expect(s.entries[id]!.status, LatencyStatus.ok);
        expect(s.entries[id]!.ms, int.parse(id)); // 不错位
      }
    });

    test('自动检测有冷却期，重复进入页面不重复发起；新鲜结果复用', () async {
      var now = DateTime(2026, 10, 24, 12);
      var calls = 0;
      final s = LatencyScheduler(
        stagger: Duration.zero,
        clock: () => now,
        onChange: (_) {},
        probe: (id) async {
          calls++;
          return const ProbeOutcome.ok(10, LatencyLayer.tcp);
        },
      );
      expect(s.autoRun(['a', 'b']), 2);
      await s.whenIdle();
      expect(s.autoRun(['a', 'b']), 0); // 冷却中
      now = now.add(const Duration(seconds: 40));
      expect(s.autoRun(['a', 'b']), 0); // 已过冷却，但结果仍新鲜
      now = now.add(const Duration(minutes: 3));
      expect(s.autoRun(['a', 'b']), 2);
      await s.whenIdle();
      expect(calls, 4);
    });

    test('正在检测的节点不会被重复加入；取消只取消排队中的', () async {
      final gate = Completer<void>();
      final s = LatencyScheduler(
        concurrency: 1,
        stagger: Duration.zero,
        onChange: (_) {},
        probe: (id) async {
          await gate.future;
          return const ProbeOutcome.timeout(LatencyLayer.proxy, '超时');
        },
      );
      expect(s.enqueue(['a', 'b', 'c']), 3);
      await Future<void>.delayed(Duration.zero);
      expect(s.enqueue(['a', 'b']), 0);
      s.cancel();
      expect(s.entries['b']!.status, LatencyStatus.cancelled);
      expect(s.entries['c']!.status, LatencyStatus.cancelled);
      gate.complete();
      await s.whenIdle();
      expect(s.entries['a']!.status, LatencyStatus.timeout); // 真实结果仍记录
    });

    test('探测函数抛异常时记为失败，不会卡住队列', () async {
      final s = LatencyScheduler(
        stagger: Duration.zero,
        onChange: (_) {},
        probe: (id) async => id == 'x' ? throw StateError('boom') : const ProbeOutcome.ok(5, LatencyLayer.tcp),
      );
      s.enqueue(['x', 'y']);
      await s.whenIdle();
      expect(s.entries['x']!.status, LatencyStatus.failed);
      expect(s.entries['y']!.status, LatencyStatus.ok);
    });

    test('错误归类', () {
      expect(classifyProbeError(TimeoutException('x'), LatencyLayer.tcp).status, LatencyStatus.timeout);
      expect(classifyProbeError('SocketException: Connection refused', LatencyLayer.tcp).error, contains('拒绝'));
      expect(classifyProbeError('Failed host lookup: a.b', LatencyLayer.tcp).error, contains('DNS'));
      expect(classifyProbeError('HandshakeException: CERTIFICATE_VERIFY_FAILED', LatencyLayer.tls).error, contains('TLS'));
    });

    test('层级标签不会把 TCP 说成可用', () {
      expect(LatencyLayer.tcp.explain, contains('不代表'));
      expect(LatencyLayerX.parse('proxy'), LatencyLayer.proxy);
      expect(LatencyLayerX.parse(null), isNull);
    });
  });

  group('测速统计', () {
    test('最终结果排除预热期', () {
      final m = ThroughputMeter(warmupMs: 2000, windowMs: 1000);
      // 前 2 秒慢启动：1 MB/s；之后 10 MB/s
      for (var t = 100; t <= 6000; t += 100) {
        m.add(t, t <= 2000 ? 100000 : 1000000);
      }
      expect(m.resultBps(), closeTo(80e6, 1e6)); // 10 MB/s = 80 Mbps
      expect(m.warmedUp, isTrue);
      expect(m.instantBps(), closeTo(80e6, 1e6));
    });

    test('测量窗口之后的数据不计入', () {
      final m = ThroughputMeter(warmupMs: 0, limitMs: 1000);
      m.add(500, 1000);
      m.add(1000, 1000);
      m.add(5000, 999999); // 超时到达
      m.record(9000);
      expect(m.totalBytes, 2000);
      expect(m.resultBps(), closeTo(2000 * 8000 / 1000, 1e-6));
    });

    test('无新数据时瞬时速度回落为 0', () {
      final m = ThroughputMeter(windowMs: 1000);
      m.add(100, 5000);
      m.record(1200);
      m.record(2500);
      expect(m.instantBps(), 0);
    });

    test('延迟中位数与抖动', () {
      final s = LatencyStats.of([10, 20, 10, 20, 10], 6)!;
      expect(s.medianMs, 10);
      expect(s.jitterMs, 10);
      expect(s.failures, 1);
      expect(LatencyStats.of([], 3), isNull);
    });

    test('仪表刻度单调且有界', () {
      var prev = -1.0;
      for (var v = 0.0; v <= 1200; v += 3.7) {
        final p = gaugePosition(v);
        expect(p, inInclusiveRange(0, 1));
        expect(p, greaterThanOrEqualTo(prev));
        prev = p;
      }
      expect(gaugePosition(1000), 1);
    });

    test('解析 M-Lab 定位结果（只用真实返回的位置字段）', () {
      const body = '{"results":[{"machine":"ndt-mlab1-pdx01.mlab-oti.measurement-lab.org","location":{"city":"Portland","country":"US"},"urls":{"wss:///ndt/v7/download":"wss://h/d?t=1","wss:///ndt/v7/upload":"wss://h/u?t=1"}},{"machine":"x","urls":{}}]}';
      final s = parseMlabLocate(body);
      expect(s, hasLength(1));
      expect(s.first.location, 'Portland, US');
      expect(s.first.name, 'M-Lab pdx01');
      expect(() => parseMlabLocate('{"results":[]}'), throwsA(isA<SpeedTestException>()));
    });

    test('Server-Timing 只扣除服务端处理耗时', () {
      expect(serverProcessingMs(['cfRequestDuration;dur=12.5']), 12.5);
      expect(serverProcessingMs(['cfL4;desc="?proto=TCP&rtt=6981"']), 0);
      expect(serverProcessingMs(null), 0);
    });

    test('ndt7 上传以服务器确认字节为准', () {
      expect(parseNdtBytesReceived('{"TCPInfo":{"BytesReceived":12345}}'), 12345);
      expect(parseNdtBytesReceived('{"AppInfo":{}}'), isNull);
      expect(parseNdtBytesReceived('not json'), isNull);
    });

    test('服务器选择按实测延迟，不按距离；Cloudflare 有稳定性系数', () {
      LatencyStats l(double ms) => LatencyStats.of([ms, ms, ms], 3)!;
      final cf = ServerCandidate(
        SpeedServer(provider: SpeedProvider.cloudflare, id: 'cf', name: 'cf', host: 'c'),
        latency: l(40),
      );
      final ml = ServerCandidate(
        SpeedServer(provider: SpeedProvider.mlab, id: 'm', name: 'm', host: 'm'),
        latency: l(45),
      );
      expect(selectionScore(ml), lessThan(selectionScore(cf)));
      final dead = ServerCandidate(cf.server, error: 'x');
      expect(selectionScore(dead), double.infinity);
    });

    test('测速失败时报告失败，不产生结果数值', () async {
      final s = SpeedTestSession(
        config: const SpeedTestConfig(connectTimeout: Duration(seconds: 2)),
      );
      final r = await s.run(
        preferred: SpeedServer(
          provider: SpeedProvider.cloudflare,
          id: 'x',
          name: '本地不可达',
          host: '127.0.0.1',
        ),
      );
      expect(r.phase, SpeedPhase.failed);
      expect(r.downloadBps, isNull);
      expect(r.uploadBps, isNull);
      expect(r.message, isNotEmpty);
      await s.dispose();
    });

    test('取消后状态为已取消', () async {
      final s = SpeedTestSession();
      final f = s.run(
        preferred: SpeedServer(provider: SpeedProvider.cloudflare, id: 'x', name: 'x', host: '127.0.0.1'),
      );
      s.cancel();
      final r = await f;
      expect(r.phase, SpeedPhase.cancelled);
      await s.dispose();
    });
  });

  group('AbuseIPDB', () {
    const body = '{"data":{"ipAddress":"1.2.3.4","isPublic":true,"abuseConfidenceScore":0,"countryCode":"JP","usageType":"Data Center/Web Hosting/Transit","isp":"Example","domain":"example.com","isTor":false,"isWhitelisted":null,"totalReports":0,"numDistinctUsers":0,"lastReportedAt":null}}';

    test('类型化字段来自接口原值', () {
      final r = parseAbuseIpDb(body, DateTime(2026));
      expect(r.abuseScore, 0);
      expect(r.totalReports, 0);
      expect(r.isTor, isFalse);
      expect(r.isWhitelisted, isNull);
      expect(r.lastReportedAt, isNull);
      expect(abuseScoreBand(0), contains('没有'));
      expect(abuseScoreBand(90), contains('高'));
    });

    test('缺少 data 报数据错误', () {
      expect(() => parseAbuseIpDb('{}', DateTime(2026)), throwsFormatException);
    });

    testWidgets('未配置 Key：显示用途与配置方法', (t) async {
      await t.pumpWidget(_wrap(const SingleChildScrollView(
        child: ReputationPanel(ip: null, report: null, error: null, hasKey: false, loading: false),
      )));
      expect(find.textContaining('Account → API'), findsOneWidget);
      expect(find.textContaining('信誉分 ≠ 节点质量'), findsOneWidget);
    });

    testWidgets('成功：显示分数、举报情况与查询状态', (t) async {
      final r = parseAbuseIpDb(body, DateTime(2026));
      await t.pumpWidget(_wrap(SingleChildScrollView(
        child: ReputationPanel(ip: '1.2.3.4', report: r, error: null, hasKey: true, loading: false),
      )));
      await t.pumpAndSettle();
      expect(find.text('查询成功'), findsOneWidget);
      expect(find.textContaining('无滥用举报记录'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('额度受限：明确提示', (t) async {
      await t.pumpWidget(_wrap(SingleChildScrollView(
        child: ReputationPanel(
          ip: '1.2.3.4',
          report: null,
          error: ReputationException(ProbeErrorKind.quotaExceeded, 'HTTP 429'),
          hasKey: true,
          loading: false,
        ),
      )));
      expect(find.text('额度受限'), findsOneWidget);
      expect(find.textContaining('额度已用尽'), findsOneWidget);
    });
  });

  group('连接按钮', () {
    test('状态映射：失败/停止永远不会映射为已连接', () {
      expect(orbPhaseFor(VpnState.error, busy: false), OrbPhase.error);
      expect(orbPhaseFor(VpnState.stopped, busy: true), OrbPhase.preparing);
      expect(orbPhaseFor(VpnState.starting, busy: true), OrbPhase.connecting);
      expect(orbPhaseFor(VpnState.started, busy: false), OrbPhase.connected);
      for (final s in [VpnState.stopped, VpnState.error, VpnState.starting, VpnState.stopping]) {
        for (final b in [true, false]) {
          expect(orbPhaseFor(s, busy: b), isNot(OrbPhase.connected));
        }
      }
    });

    testWidgets('连接中 → 失败：显示失败，不出现成功', (t) async {
      var phase = OrbPhase.connecting;
      late StateSetter set;
      await t.pumpWidget(_wrap(StatefulBuilder(builder: (c, s) {
        set = s;
        return Column(children: [
          ConnectOrb(phase: phase, onTap: () {}),
          Text(orbLabel(phase)),
        ]);
      })));
      await t.pump(const Duration(milliseconds: 300));
      set(() => phase = OrbPhase.error);
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('连接失败'), findsOneWidget);
      expect(find.text('已连接'), findsNothing);
      await t.pumpWidget(const SizedBox()); // 释放控制器
    });

    testWidgets('锁定时不可点击', (t) async {
      await t.pumpWidget(_wrap(const ConnectOrb(phase: OrbPhase.disconnecting, onTap: null)));
      await t.tap(find.byType(ConnectOrb));
      await t.pump(const Duration(milliseconds: 100));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('减少动态效果时不运行循环动画', (t) async {
      await t.pumpWidget(_wrap(ConnectOrb(phase: OrbPhase.connecting, onTap: () {}), reduced: true));
      await t.pumpAndSettle(); // 若有无限循环动画会超时失败
    });
  });

  group('实时曲线组件', () {
    testWidgets('有数据时平滑绘制，无异常；减少动态效果时也可绘制', (t) async {
      final meter = TrafficMeter();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < 40; i++) {
        meter.add(TrafficSnapshot(timestampMs: now - 20000 + i * 500, rxBytes: i * i * 1000, txBytes: i * 500));
      }
      await t.pumpWidget(_wrap(SizedBox(height: 150, child: LiveSpeedChart(meter: meter, active: true, sampleCount: 40))));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(_wrap(SizedBox(height: 150, child: LiveSpeedChart(meter: meter, active: true, sampleCount: 41)), reduced: true));
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
    });
  });

  group('底部导航', () {
    testWidgets('快速连续切换不丢失页面状态，返回键回到首页', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: buildDarkTheme(),
        home: RippleNavShell(
          destinations: const [
            NavDestinationSpec(Icons.home_outlined, Icons.home, '首页'),
            NavDestinationSpec(Icons.dns_outlined, Icons.dns, '节点'),
            NavDestinationSpec(Icons.settings_outlined, Icons.settings, '设置'),
          ],
          pageBuilder: (i, active) => _CounterPage(i, active),
        ),
      ));
      // 在首页累加计数
      await t.tap(find.text('+0'));
      await t.tap(find.text('+0'));
      await t.pump();
      // 快速连续点击
      await t.tap(find.text('节点'));
      await t.pump(const Duration(milliseconds: 30));
      await t.tap(find.text('设置'));
      await t.pump(const Duration(milliseconds: 30));
      await t.tap(find.text('首页'));
      await t.pump(const Duration(milliseconds: 30));
      await t.tap(find.text('节点'));
      await t.pumpAndSettle();
      expect(find.text('页面 1 active=true'), findsOneWidget);
      // 回首页，计数仍在
      await t.tap(find.text('首页'));
      await t.pumpAndSettle();
      expect(find.text('页面 0 count=2'), findsOneWidget);
      // 返回键：在其它页时先回首页
      await t.tap(find.text('设置'));
      await t.pumpAndSettle();
      final nav = t.state<NavigatorState>(find.byType(Navigator));
      await nav.maybePop();
      await t.pumpAndSettle();
      expect(find.text('页面 0 count=2'), findsOneWidget);
    });
  });

  group('测速仪表', () {
    testWidgets('仪表平滑过渡并最终稳定', (t) async {
      await t.pumpWidget(_wrap(const SizedBox(width: 320, child: SpeedGauge(targetBps: 50e6, color: kAccent, caption: '下载中'))));
      await t.pump(const Duration(milliseconds: 50));
      await t.pumpAndSettle();
      expect(find.text('50.0'), findsOneWidget);
    });
  });
}

class _CounterPage extends StatefulWidget {
  const _CounterPage(this.i, this.active);
  final int i;
  final bool active;
  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> {
  int count = 0;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('页面 ${widget.i} count=$count'),
      Text('页面 ${widget.i} active=${widget.active}'),
      TextButton(onPressed: () => setState(() => count++), child: Text('+${widget.i}')),
    ],
  );
}
