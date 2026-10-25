// 自定义分组、风险节点、一键删除失效节点、默认 AbuseIPDB Key。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypilot_mobile/app/state.dart';
import 'package:proxypilot_mobile/core/engine/config_builder.dart';
import 'package:proxypilot_mobile/core/engine/node_risk.dart';
import 'package:proxypilot_mobile/core/models/models.dart';
import 'package:proxypilot_mobile/core/storage/app_database.dart';
import 'package:proxypilot_mobile/features/profiles/node_grouping.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ProxyNode _n(
  String id, {
  ProxyProtocol p = ProxyProtocol.trojan,
  TlsOptions tls = const TlsOptions(enabled: true),
  String? sub,
  String server = '',
}) => ProxyNode(
  id: id,
  name: id,
  protocol: p,
  server: server.isEmpty ? '$id.example.com' : server,
  port: 443,
  secret: const {'password': 'x', 'uuid': '11111111-2222-3333-4444-555555555555'},
  tls: tls,
  subscriptionId: sub,
);

void main() {
  group('风险评估', () {
    test('跳过证书校验 = 高风险；明文 = 风险；正常 TLS = 无', () {
      expect(assessRisk(_n('a', tls: const TlsOptions(enabled: true, insecure: true))).level, RiskLevel.high);
      expect(assessRisk(_n('b', p: ProxyProtocol.vless, tls: const TlsOptions())).level, RiskLevel.caution);
      expect(assessRisk(_n('c', p: ProxyProtocol.socks, tls: const TlsOptions())).level, RiskLevel.caution);
      expect(assessRisk(_n('d')).risky, isFalse);
    });

    test('高风险节点默认不进入配置；所选高风险未确认时拒绝；确认后写入 insecure', () {
      final safe = _n('safe');
      final bad = _n('bad', tls: const TlsOptions(enabled: true, insecure: true));
      final b1 = ConfigBuilder.build(
        nodes: [safe, bad],
        selected: safe,
        settings: const EngineSettings(),
        clashSecret: 's',
      );
      expect(b1.nodeTags.keys, ['safe']);
      expect(() => ConfigBuilder.build(
        nodes: [safe, bad],
        selected: bad,
        settings: const EngineSettings(),
        clashSecret: 's',
      ), throwsA(isA<RiskNotConfirmedException>()));
      final b2 = ConfigBuilder.build(
        nodes: [safe, bad],
        selected: bad,
        settings: const EngineSettings(),
        clashSecret: 's',
        allowRisky: {'bad'},
      );
      final outs = (jsonDecode(b2.json)['outbounds'] as List).cast<Map>();
      final o = outs.firstWhere((x) => x['tag'] == b2.nodeTags['bad']);
      expect(o['tls']['insecure'], isTrue);
      final os = outs.firstWhere((x) => x['tag'] == b2.nodeTags['safe']);
      expect((os['tls'] as Map).containsKey('insecure'), isFalse);
      final b3 = ConfigBuilder.build(
        nodes: [safe, bad],
        selected: safe,
        settings: const EngineSettings(),
        clashSecret: 's',
        allowAllRisky: true,
      );
      expect(b3.nodeTags.keys.toSet(), {'safe', 'bad'});
    });
  });

  group('自定义分组', () {
    test('按 dedupKey 归属：订阅刷新后 id 变化仍在原分组；未分组单列', () {
      final a = _n('a', sub: 's1'), b = _n('b'), c = _n('c');
      final g = [CustomGroup('g1', '常用', {a.dedupKey})];
      final refreshed = a.copyWith(id: 'a-new');
      final out = groupNodes([refreshed, b, c], mode: NodeGroupMode.custom, customGroups: g);
      expect(out.map((x) => x.title), ['常用', '未分组']);
      expect(out.first.nodes.single.id, 'a-new');
      expect(out.last.nodes.map((x) => x.id), ['b', 'c']);
    });

    test('REALITY 公钥 / short_id 不同的节点不再被视为重复', () {
      ProxyNode r(String pk) => _n('r', p: ProxyProtocol.vless, tls: TlsOptions(
        enabled: true, realityPublicKey: pk, realityShortId: 'ab'));
      expect(r('A' * 43).dedupKey == r('B' * 43).dedupKey, isFalse);
    });

    test('编码容错 + 一个节点只属于一个分组', () async {
      expect(decodeCustomGroups('garbage'), isEmpty);
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('cg');
      final db = await AppDatabase.open(MemorySecretStore(), factory: databaseFactoryFfi, path: '${dir.path}/t.db');
      final c = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
      addTearDown(c.dispose);
      c.read(customGroupsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final n = c.read(customGroupsProvider.notifier);
      final g1 = (await n.create('游戏'))!;
      final g2 = (await n.create('备用'))!;
      expect(await n.create('游戏'), isNull);
      final x = _n('x');
      await n.assign([x], g1);
      await n.assign([x], g2);
      final gs = c.read(customGroupsProvider);
      expect(gs.firstWhere((g) => g.id == g1).contains(x), isFalse);
      expect(gs.firstWhere((g) => g.id == g2).contains(x), isTrue);
      expect(decodeCustomGroups(await db.getKv(CustomGroupsNotifier.kvKey)).length, 2);
      await n.remove(g1);
      expect(c.read(customGroupsProvider).length, 1);
    });
  });

  test('一键删除失效节点：批量删除并记录', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('del');
    final db = await AppDatabase.open(MemorySecretStore(), factory: databaseFactoryFfi, path: '${dir.path}/t.db');
    for (final id in ['a', 'b', 'c']) {
      await db.upsertNode(_n(id));
    }
    final c = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(c.dispose);
    c.read(nodesProvider);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.read(nodesProvider).nodes.length, 3);
    expect(await c.read(nodesProvider.notifier).deleteMany(['a', 'b', 'a']), 2);
    expect(c.read(nodesProvider).nodes.map((n) => n.id), ['c']);
  });

  test('AbuseIPDB：自己的 Key 优先，否则用内置默认', () {
    const s = SettingsState(builtinAbuseKey: 'builtin');
    expect(s.effectiveAbuseKey, 'builtin');
    expect(s.usingBuiltinAbuseKey, isTrue);
    final mine = s.copyWith(abuseIpDbKey: 'mine');
    expect(mine.effectiveAbuseKey, 'mine');
    expect(mine.usingBuiltinAbuseKey, isFalse);
    expect(const SettingsState().effectiveAbuseKey, isEmpty);
  });
}
