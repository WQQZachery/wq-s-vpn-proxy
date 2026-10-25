// R1 分组/排序、R3 二维码内容归类、阶段 3 连接生命周期（超时/重复点击/各类失败）、R4 动效。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypilot_mobile/app/state.dart';
import 'package:proxypilot_mobile/app/theme.dart';
import 'package:proxypilot_mobile/app/vpn_tint.dart';
import 'package:proxypilot_mobile/core/engine/vpn_engine.dart';
import 'package:proxypilot_mobile/core/models/models.dart';
import 'package:proxypilot_mobile/core/networking/share_link_serializer.dart';
import 'package:proxypilot_mobile/core/storage/app_database.dart';
import 'package:proxypilot_mobile/features/dashboard/connect_orb.dart';
import 'package:proxypilot_mobile/features/profiles/node_grouping.dart';
import 'package:proxypilot_mobile/features/profiles/qr_import.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ProxyNode _n(
  String id,
  ProxyProtocol p, {
  String? sub,
  String name = '',
}) => ProxyNode(
  id: id,
  name: name.isEmpty ? id : name,
  protocol: p,
  server: '$id.example.com',
  port: 443,
  secret: const {'password': 'x'},
  tls: const TlsOptions(enabled: true),
  subscriptionId: sub,
);

class FakeEngine extends VpnEngine {
  FakeEngine({
    this.prepareOk = true,
    this.checkError,
    this.autoStarted = false,
    this.startThrows = false,
  });
  bool prepareOk;
  String? checkError;
  bool autoStarted;
  bool startThrows;
  VpnState nativeState = VpnState.stopped;
  int starts = 0, stops = 0;
  final _ev = StreamController<EngineEvent>.broadcast();

  void emit(VpnState s, [String? m]) => _ev.add(EngineEvent.state(s, m));

  @override
  Stream<EngineEvent> events() => _ev.stream;
  @override
  Future<(VpnState, String?)> currentState() async => (nativeState, null);
  @override
  Future<bool> prepare() async => prepareOk;
  @override
  Future<String?> checkConfig(String config) async => checkError;
  @override
  Future<void> start({required String config, required String profileName}) async {
    starts++;
    if (startThrows) throw StateError('boom');
    scheduleMicrotask(() {
      emit(VpnState.starting);
      if (autoStarted) emit(VpnState.started);
    });
  }

  @override
  Future<void> stop() async {
    stops++;
    scheduleMicrotask(() => emit(VpnState.stopped));
  }
}

void main() {
  group('R1 分组与排序', () {
    final subs = [
      Subscription(id: 's1', name: '机场 A', url: 'https://a.example/sub'),
      Subscription(id: 's2', name: '机场 B', url: 'https://b.example/sub'),
    ];
    final nodes = [
      _n('b1', ProxyProtocol.vless, sub: 's2', name: 'zeta'),
      _n('m1', ProxyProtocol.trojan, name: 'Alpha'),
      _n('a1', ProxyProtocol.trojan, sub: 's1', name: 'beta'),
      _n('x1', ProxyProtocol.vless, sub: 'gone', name: 'gamma'),
      _n('a2', ProxyProtocol.hysteria2, sub: 's1', name: 'delta'),
    ];

    test('不分组：一组，保持原顺序', () {
      final g = groupNodes(nodes, mode: NodeGroupMode.none);
      expect(g, hasLength(1));
      expect(g.single.nodes.map((n) => n.id), ['b1', 'm1', 'a1', 'x1', 'a2']);
    });
    test('按来源：手动在前、订阅按订阅顺序、已删除订阅在最后，数量正确', () {
      final g = groupNodes(nodes, mode: NodeGroupMode.source, subscriptions: subs);
      expect(g.map((e) => e.title), ['手动 / 分享链接', '机场 A', '机场 B', '已删除的订阅']);
      expect(g.map((e) => e.nodes.length), [1, 2, 1, 1]);
    });
    test('按协议：按协议枚举顺序，空组不出现', () {
      final g = groupNodes(nodes, mode: NodeGroupMode.protocol);
      expect(g.map((e) => e.key).toSet(), {
        'proto:vless',
        'proto:trojan',
        'proto:hysteria2',
      });
      expect(g.fold<int>(0, (a, e) => a + e.nodes.length), nodes.length);
    });
    test('按延迟：有结果的升序在前，无结果的保持原顺序在后', () {
      final ms = {'a1': 300, 'm1': 80, 'a2': 150};
      final g = groupNodes(
        nodes,
        mode: NodeGroupMode.none,
        sort: NodeSortMode.latency,
        latencyOf: (n) => ms[n.id],
      );
      expect(g.single.nodes.map((n) => n.id), ['m1', 'a2', 'a1', 'b1', 'x1']);
    });
    test('按名称：不区分大小写', () {
      final g = groupNodes(nodes, mode: NodeGroupMode.none, sort: NodeSortMode.name);
      expect(g.single.nodes.map((n) => n.name), ['Alpha', 'beta', 'delta', 'gamma', 'zeta']);
    });
    test('分组不修改节点本身（导出结果不变）', () {
      final before = nodes.map(ShareLinkSerializer.toLink).toList();
      groupNodes(nodes, mode: NodeGroupMode.source, subscriptions: subs, sort: NodeSortMode.name);
      expect(nodes.map(ShareLinkSerializer.toLink).toList(), before);
    });
    test('偏好持久化格式往返，损坏数据回退默认', () {
      const p = NodeGroupPrefs(
        mode: NodeGroupMode.protocol,
        sort: NodeSortMode.latency,
        collapsed: {'proto:vless', 'manual'},
      );
      final d = NodeGroupPrefs.decode(p.encode());
      expect(d.mode, p.mode);
      expect(d.sort, p.sort);
      expect(d.collapsed, p.collapsed);
      for (final bad in [null, '', '{', '[]', '{"mode":"nope","collapsed":[1,"a"]}']) {
        final x = NodeGroupPrefs.decode(bad);
        expect(x.mode, NodeGroupMode.source);
      }
      expect(NodeGroupPrefs.decode('{"collapsed":[1,"a"]}').collapsed, {'a'});
    });
  });

  group('R3 二维码内容归类', () {
    const uuid = 'b831381d-6324-4d53-ad4f-8cda48b30811';
    test('节点链接 → nodes', () {
      final p = classifyQrPayload(['  vless://$uuid@a.example.com:443#A  ']);
      expect(p.kind, QrPayloadKind.nodes);
      expect(p.text, 'vless://$uuid@a.example.com:443#A');
    });
    test('多个二维码合并去重', () {
      final p = classifyQrPayload([
        'trojan://pw@a.example.com:443#A',
        'trojan://pw@a.example.com:443#A',
        'ss://YWVzLTI1Ni1nY206cHc@b.example.com:8388#B',
        null,
        '',
      ]);
      expect(p.kind, QrPayloadKind.nodes);
      expect(p.count, 2);
      expect(p.text.split('\n'), hasLength(2));
    });
    test('单个 https 地址 → 订阅 URL', () {
      final p = classifyQrPayload(['https://sub.example.com/api?token=abc']);
      expect(p.kind, QrPayloadKind.subscriptionUrl);
    });
    test('sing-box JSON 与 Base64 订阅内容 → nodes', () {
      expect(classifyQrPayload(['{"outbounds":[]}']).kind, QrPayloadKind.nodes);
      expect(
        classifyQrPayload(['dHJvamFuOi8vcHdAYS5leGFtcGxlLmNvbTo0NDMjQQ==']).kind,
        QrPayloadKind.nodes,
      );
    });
    test('无关内容 / 空 → unknown（不进入导入流程）', () {
      for (final v in [
        <String?>[],
        <String?>[null, ' '],
        <String?>['hello world'],
        <String?>['WIFI:S:home;T:WPA;P:secret;;'],
        <String?>['http://a.example.com', 'http://b.example.com'],
      ]) {
        expect(classifyQrPayload(v).kind, QrPayloadKind.unknown, reason: '$v');
      }
    });
  });

  group('阶段 3 连接生命周期', () {
    late AppDatabase db;
    late ProviderContainer c;
    late FakeEngine engine;

    Future<void> setup(FakeEngine e, {AppDatabase? reuse}) async {
      engine = e;
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('pplife');
      db = reuse ??
          await AppDatabase.open(
            MemorySecretStore(),
            factory: databaseFactoryFfi,
            path: '${dir.path}/t.db',
          );
      await db.upsertNode(_n('node0', ProxyProtocol.trojan, name: '测试'));
      c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          vpnEngineProvider.overrideWithValue(engine),
        ],
      );
      c.read(vpnControllerProvider);
      c.read(settingsProvider);
      final n = c.read(nodesProvider.notifier);
      for (var i = 0; i < 100 && c.read(nodesProvider).loading; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await n.select('node0');
    }

    tearDown(() async {
      // 等设置等异步加载结束再关库，避免测试结束后的“database_closed”噪声
      await Future<void>.delayed(const Duration(milliseconds: 150));
      c.dispose();
      await db.close();
      VpnController.startTimeout = const Duration(seconds: 30);
    });

    Future<void> settle([int ms = 50]) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    test('内核未就绪 → 超时后主动停止，最终显示“连接超时”而非已断开', () async {
      VpnController.startTimeout = const Duration(milliseconds: 200);
      await setup(FakeEngine());
      expect(await c.read(vpnControllerProvider.notifier).connect(), isNull);
      await settle();
      expect(c.read(vpnControllerProvider).state, VpnState.starting);
      await settle(400);
      expect(engine.stops, 1);
      final st = c.read(vpnControllerProvider);
      expect(st.state, VpnState.error);
      expect(st.message, contains('连接超时'));
    });

    test('及时上报 started → 不触发超时', () async {
      VpnController.startTimeout = const Duration(milliseconds: 200);
      await setup(FakeEngine(autoStarted: true));
      await c.read(vpnControllerProvider.notifier).connect();
      await settle(400);
      expect(engine.stops, 0);
      expect(c.read(vpnControllerProvider).state, VpnState.started);
    });

    test('界面进程重建后恢复运行中会话：节点仍可经内核检测', () async {
      await setup(FakeEngine(autoStarted: true));
      await c.read(vpnControllerProvider.notifier).connect();
      await settle();
      final tags = c.read(vpnControllerProvider).nodeTags;
      expect(tags, contains('node0'));
      // 模拟界面进程被回收重建：新的容器、原生侧仍在运行
      await Future<void>.delayed(const Duration(milliseconds: 150));
      c.dispose();
      final e2 = FakeEngine()..nativeState = VpnState.started;
      await setup(e2, reuse: db);
      await settle(150);
      final st = c.read(vpnControllerProvider);
      expect(st.state, VpnState.started);
      expect(st.clash, isNotNull);
      expect(st.nodeTags, tags);
      expect(st.nodeName, '测试');
    });

    test('进入节点页自动检测默认关闭，可在设置中开启并持久化', () async {
      await setup(FakeEngine());
      await settle(100);
      expect(c.read(settingsProvider).autoTestNodes, isFalse);
      await c.read(settingsProvider.notifier).setAutoTestNodes(true);
      expect(await db.getKv('autoTestNodes'), '1');
    });

    test('快速连续点击只启动一次', () async {
      await setup(FakeEngine());
      final ctl = c.read(vpnControllerProvider.notifier);
      await Future.wait([ctl.connect(), ctl.connect(), ctl.connect()]);
      await settle();
      expect(engine.starts, 1);
    });

    test('配置校验失败 / 授权拒绝 / 启动异常 各自给出不同结果，且都不显示已连接', () async {
      await setup(FakeEngine(checkError: 'initialize outbound[1]: bad'));
      var r = await c.read(vpnControllerProvider.notifier).connect();
      expect(r, startsWith('配置校验失败'));
      expect(r, contains('节点「测试」'));
      expect(engine.starts, 0);

      engine
        ..checkError = null
        ..prepareOk = false;
      r = await c.read(vpnControllerProvider.notifier).connect();
      expect(r, '未获得 VPN 授权');
      expect(engine.starts, 0);

      engine
        ..prepareOk = true
        ..startThrows = true;
      r = await c.read(vpnControllerProvider.notifier).connect();
      expect(r, startsWith('启动失败'));
      expect(c.read(vpnControllerProvider).state, VpnState.error);
    });
  });

  group('全屏状态色水波', () {
    testWidgets('状态色改变时从原点扩散铺满后停止；减少动态效果时无波前层', (t) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      Future<void> pump({bool reduce = false}) => t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduce),
              child: const VpnTintScope(child: SizedBox.expand()),
            ),
          ),
        ),
      );
      await pump();
      c.read(vpnTintProvider.notifier).set(kGood, origin: const Offset(200, 300));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(t.binding.hasScheduledFrame, isTrue);
      await t.pumpAndSettle();
      expect(t.binding.hasScheduledFrame, isFalse);
      // 同色不重复触发
      c.read(vpnTintProvider.notifier).set(kGood);
      await t.pump();
      expect(t.binding.hasScheduledFrame, isFalse);
      await pump(reduce: true);
      c.read(vpnTintProvider.notifier).set(kBad);
      await t.pumpAndSettle();
      expect(c.read(vpnTintProvider).color, kBad);
    });
  });

  group('R4 连接动效', () {
    Future<void> pumpOrb(WidgetTester t, OrbPhase p, {bool reduce = false}) =>
        t.pumpWidget(
          MaterialApp(
            theme: buildDarkTheme(),
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduce),
              child: Center(child: ConnectOrb(phase: p, onTap: () {})),
            ),
          ),
        );

    testWidgets('连接中持续动画（旋转+等待波纹），已连接后进入呼吸，断开后静止', (t) async {
      await pumpOrb(t, OrbPhase.connecting);
      await t.pump(const Duration(milliseconds: 300));
      expect(t.binding.hasScheduledFrame, isTrue);
      await pumpOrb(t, OrbPhase.connected);
      await t.pump(const Duration(milliseconds: 300));
      expect(t.binding.hasScheduledFrame, isTrue);
      await pumpOrb(t, OrbPhase.idle);
      await t.pumpAndSettle();
      expect(t.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('减少动态效果：连接中/已连接都没有持续动画', (t) async {
      await pumpOrb(t, OrbPhase.connecting, reduce: true);
      await t.pumpAndSettle();
      expect(t.binding.hasScheduledFrame, isFalse);
      await pumpOrb(t, OrbPhase.connected, reduce: true);
      await t.pumpAndSettle();
      expect(t.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('移除组件后控制器全部释放（无残留 Ticker）', (t) async {
      await pumpOrb(t, OrbPhase.connecting);
      await t.pump(const Duration(milliseconds: 100));
      await t.pumpWidget(const SizedBox());
      await t.pump();
      expect(t.binding.hasScheduledFrame, isFalse);
    });
  });
}
