// SPDX-License-Identifier: GPL-3.0-or-later
// 开发用：渲染主要页面截图用于人工视觉检查（不属于常规测试）。
// 运行：flutter test tool/screens/screens_test.dart --update-goldens
// 需要 CJK 字体：/workspace/tools/fonts/wqy-microhei.ttc（开发机路径）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypilot_mobile/app/ripple_nav.dart';
import 'package:proxypilot_mobile/app/state.dart';
import 'package:proxypilot_mobile/app/theme.dart';
import 'package:proxypilot_mobile/core/models/models.dart';
import 'package:proxypilot_mobile/core/reputation/ip_reputation.dart';
import 'package:proxypilot_mobile/core/storage/app_database.dart';
import 'package:proxypilot_mobile/features/diagnostics/reputation_panel.dart';
import 'package:proxypilot_mobile/features/speedtest/speed_gauge.dart';
import 'package:proxypilot_mobile/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _font(String family, String path) async {
  final bytes = await File(path).readAsBytes();
  final l = FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)));
  await l.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  MockStreamHandlerEventSink? sink;
  var nativeState = 'stopped';

  setUpAll(() async {
    await _font('Roboto', '/workspace/tools/fonts/wqy-microhei.ttc');
    await _font('MaterialIcons', '/workspace/tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  });

  setUp(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('proxypilot/vpn'), (c) async {
      switch (c.method) {
        case 'state':
          return {'state': nativeState};
        case 'version':
          return '1.14.3';
      }
      return null;
    });
    m.setMockStreamHandler(
      const EventChannel('proxypilot/vpn_events'),
      MockStreamHandler.inline(onListen: (_, s) {
        sink = s;
      }),
    );
  });

  Future<AppDatabase> openDb() async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('ppshot');
    final db = await AppDatabase.open(MemorySecretStore(), factory: databaseFactoryFfi, path: '${dir.path}/t.db');
    final names = ['香港 HKT 01', '日本 东京 IIJ', '新加坡 SG-03', '美国 洛杉矶 CN2 GIA', '台湾 HiNet', '韩国 首尔'];
    for (var i = 0; i < names.length; i++) {
      await db.upsertNode(ProxyNode(
        id: 'node$i',
        name: names[i],
        protocol: i == 3 ? ProxyProtocol.hysteria2 : (i.isEven ? ProxyProtocol.vless : ProxyProtocol.trojan),
        server: 'n$i.example.com',
        port: 443,
        secret: const {'password': 'x', 'uuid': '11111111-2222-3333-4444-555555555555'},
        tls: TlsOptions(enabled: true, realityPublicKey: i == 0 ? 'A' * 43 : null),
        enabled: i != 5,
      ));
    }
    await db.recordHealth('node1', latencyMs: 86, method: 'tls');
    await db.recordHealth('node2', error: '超时', method: 'tcp');
    await db.recordHealth('node4', latencyMs: 212, method: 'tcp');
    await db.setKv('selectedNode', 'node1');
    return db;
  }

  // 数据库（ffi）每次 await 都需要真实异步，交替推进真实时间与测试时钟
  Future<void> settle(WidgetTester t, [int n = 25]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> shell(WidgetTester t, AppDatabase db) async {
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(theme: buildDarkTheme(), debugShowCheckedModeBanner: false, home: const HomeShell()),
    ));
    await settle(t);
  }

  testWidgets('首页（未连接）与节点、检测、设置', (t) async {
    final db = (await t.runAsync(openDb))!;
    await shell(t, db);
    await expectLater(find.byType(HomeShell), matchesGoldenFile('out/01_home_idle.png'));
    await t.tap(find.text('节点').last);
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 600));
    await expectLater(find.byType(HomeShell), matchesGoldenFile('out/02_nodes.png'));
    await t.tap(find.text('检测').last);
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 700));
    await expectLater(find.byType(HomeShell), matchesGoldenFile('out/03_diag.png'));
    await t.tap(find.text('设置').last);
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 700));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump(const Duration(milliseconds: 100));
    await expectLater(find.byType(HomeShell), matchesGoldenFile('out/04_settings.png'));
    // 水波中间帧
    await t.tap(find.text('首页').last, warnIfMissed: true);
    await t.pump();
    await t.pump(const Duration(milliseconds: 60));
    await t.pump(const Duration(milliseconds: 60));
    await expectLater(find.byType(RippleNavShell), matchesGoldenFile('out/05_ripple_frame.png'));
    await t.pump(const Duration(milliseconds: 800));
    await expectLater(find.byType(RippleNavShell), matchesGoldenFile('out/05b_after.png'));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('首页（已连接，有流量）', (t) async {
    final db = (await t.runAsync(openDb))!;
    await shell(t, db);
    nativeState = 'started';
    sink!.success({'type': 'state', 'state': 'started'});
    await t.pump(const Duration(milliseconds: 50));
    final now = DateTime.now().millisecondsSinceEpoch;
    var rx = 0, tx = 0;
    for (var i = 0; i < 80; i++) {
      final f = i < 30 ? 0.2 : (i < 55 ? 6.0 : 1.5);
      rx += (f * 1e6 / 8 * 0.5 * (0.8 + (i % 5) * 0.1)).round();
      tx += (f * 0.15e6 / 8 * 0.5).round();
      sink!.success({'type': 'traffic', 'ts': now - (80 - i) * 500 + 600, 'rx': rx, 'tx': tx});
    }
    await settle(t, 5);
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    await expectLater(find.byType(HomeShell), matchesGoldenFile('out/06_home_connected.png'));
    nativeState = 'stopped';
    sink!.success({'type': 'state', 'state': 'stopped'});
    await t.pump(const Duration(milliseconds: 600));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('组件：IP 信誉结果与测速仪表', (t) async {
    t.view.physicalSize = const Size(1080, 3000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    const body = '{"data":{"ipAddress":"203.0.113.7","isPublic":true,"abuseConfidenceScore":34,"countryCode":"JP","usageType":"Data Center/Web Hosting/Transit","isp":"Example Hosting","domain":"example.net","isTor":false,"isWhitelisted":false,"totalReports":12,"numDistinctUsers":5,"lastReportedAt":"2026-10-20T08:12:00+00:00"}}';
    final r = parseAbuseIpDb(body, DateTime(2026, 10, 24, 18));
    await t.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: ListView(children: [
          AppCard(padding: EdgeInsets.zero, child: ReputationPanel(ip: r.ip, report: r, error: null, hasKey: true, loading: false)),
          const Padding(
            padding: EdgeInsets.all(28),
            child: SpeedGauge(targetBps: 187e6, color: kAccent, caption: '下载中 · 实时（平滑显示）'),
          ),
        ]),
      ),
    ));
    await t.pumpAndSettle();
    await expectLater(find.byType(Scaffold), matchesGoldenFile('out/07_components.png'));
  });
}
