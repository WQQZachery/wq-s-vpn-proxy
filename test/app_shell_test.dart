// SPDX-License-Identifier: GPL-3.0-or-later
// 整个应用外壳的组件测试：小屏 + 大字体下逐页渲染、快速切换标签，不应出现溢出或异常。
// 原生 VPN 通道用 mock 代替（不涉及真实 VPN）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypilot_mobile/app/state.dart';
import 'package:proxypilot_mobile/app/theme.dart';
import 'package:proxypilot_mobile/core/models/models.dart';
import 'package:proxypilot_mobile/core/storage/app_database.dart';
import 'package:proxypilot_mobile/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('proxypilot/vpn'), (c) async {
      switch (c.method) {
        case 'state':
          return {'state': 'stopped'};
        case 'version':
          return '1.14.3';
        case 'logs':
          return '';
      }
      return null;
    });
    m.setMockStreamHandler(
      const EventChannel('proxypilot/vpn_events'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });

  Future<AppDatabase> openDb({bool withNodes = true}) async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('ppshell');
    final db = await AppDatabase.open(
      MemorySecretStore(),
      factory: databaseFactoryFfi,
      path: '${dir.path}/t.db',
    );
    if (withNodes) {
      for (var i = 0; i < 6; i++) {
        await db.upsertNode(
          ProxyNode(
            id: 'node$i',
            name: '一个名字非常非常长的测试节点 $i（香港 · 专线 · IPLC）',
            protocol: ProxyProtocol.trojan,
            server: 'n$i.example.com',
            port: 443,
            secret: const {'password': 'x'},
            tls: const TlsOptions(enabled: true),
            enabled: false, // 禁用：避免组件测试中自动检测发起真实网络请求
          ),
        );
      }
      await db.recordHealth('node1', latencyMs: 123, method: 'tcp');
      await db.recordHealth('node2', error: '超时', method: 'proxy');
    }
    return db;
  }

  Future<void> pumpShell(WidgetTester t, AppDatabase db, {double scale = 1.3}) async {
    t.view.physicalSize = const Size(720, 1280); // 360×640 dp
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          theme: buildDarkTheme(),
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const HomeShell(),
        ),
      ),
    );
    // 让数据库读取完成
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump(const Duration(milliseconds: 500));
  }

  testWidgets('小屏 + 1.3 倍字体：四个页面均可渲染且无溢出', (t) async {
    final db = await t.runAsync(openDb);
    final orig = FlutterError.onError;
    FlutterError.onError = (d) {
      debugPrint('DETAIL>> ${d.toString(minLevel: DiagnosticLevel.debug)}');
      orig?.call(d);
    };
    addTearDown(() => FlutterError.onError = orig);
    await pumpShell(t, db!);
    expect(find.text('未连接'), findsOneWidget);
    for (final tab in ['节点', '检测', '设置', '首页']) {
      await t.tap(find.text(tab).last);
      await t.pump(const Duration(milliseconds: 600));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump(const Duration(milliseconds: 100));
      final e = t.takeException();
      if (e is FlutterError) debugPrint(e.toStringDeep());
      expect(e, isNull, reason: '页面 $tab');
    }
    await t.tap(find.text('节点').last);
    await t.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('6 个节点'), findsOneWidget);
    expect(find.text('仅 TCP / TLS 检测'), findsOneWidget);
    // 历史结果显示为“上次”，与本次实时检测区分
    expect(find.textContaining('上次'), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('无节点：显示空状态与引导', (t) async {
    final db = await t.runAsync(() => openDb(withNodes: false));
    await pumpShell(t, db!, scale: 1.0);
    expect(find.text('请先在“节点”页选择节点'), findsOneWidget);
    await t.tap(find.text('节点').last);
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('还没有节点'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('检测中心：未配置 Key 时说明用途', (t) async {
    final db = await t.runAsync(() => openDb(withNodes: false));
    await pumpShell(t, db!);
    await t.tap(find.text('检测').last);
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('主动测速'), findsOneWidget);
    expect(find.textContaining('需要你自己的 AbuseIPDB API Key'), findsOneWidget);
    expect(t.takeException(), isNull);
    // 打开测速页（不开始测试，不产生网络请求）
    await t.tap(find.text('主动测速'));
    await t.pumpAndSettle();
    expect(find.text('不支持'), findsOneWidget); // 丢包率如实标注
    await t.scrollUntilVisible(find.text('开始测试'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('开始测试'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
