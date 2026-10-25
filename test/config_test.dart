import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypilot_mobile/core/engine/config_builder.dart';
import 'package:proxypilot_mobile/core/models/models.dart';
import 'package:proxypilot_mobile/core/networking/share_link_parser.dart';

/// 由 scripts/build-libbox.sh 同源编译的宿主机 sing-box（同版本 1.14.3、同 build tags），用于真实校验生成的配置。
const singBoxBin = String.fromEnvironment(
  'SING_BOX_BIN',
  defaultValue: '/workspace/tools/bin/sing-box',
);

void main() {
  var i = 0;
  final parser = ShareLinkParser(
    newId: () => '${(i++).toString().padLeft(4, '0')}abcdefgh',
  );
  const uuid = 'b831381d-6324-4d53-ad4f-8cda48b30811';
  final nodes = [
    parser.parseLink(
      'vless://$uuid@r.example.com:443?security=reality&sni=www.apple.com&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=6ba85179e30d4fc2&fp=chrome&flow=xtls-rprx-vision#R',
    ),
    parser.parseLink(
      'trojan://pw@t.example.com:443?sni=t.example.com&type=ws&path=%2Fws&host=cdn.example.com#T',
    ),
    parser.parseLink(
      'hy2://auth@h.example.com:8443?sni=h.example.com&obfs=salamander&obfs-password=ob#H',
    ),
    parser.parseLink(
      'tuic://$uuid:pw@u.example.com:443?congestion_control=bbr&sni=u.example.com#U',
    ),
    parser.parseLink(
      'ss://${base64Url.encode(utf8.encode('2022-blake3-aes-128-gcm:AAAAAAAAAAAAAAAAAAAAAA=='))}@s.example.com:8388#S',
    ),
    parser.parseLink(
      'vmess://${base64.encode(utf8.encode(jsonEncode({'ps': 'V', 'add': 'v.example.com', 'port': '443', 'id': uuid, 'aid': '0', 'net': 'grpc', 'path': 'svc', 'tls': 'tls'})))}',
    ),
    parser.parseLink('socks5://u:p@10.0.0.2:1080#K'),
  ];

  Map<String, dynamic> build(EngineSettings s) => (jsonDecode(
    ConfigBuilder.build(
      nodes: nodes,
      selected: nodes[1],
      settings: s,
      clashSecret: 'test-secret',
    ).json,
  ) as Map).cast<String, dynamic>();

  group('配置生成', () {
    test('selector 默认选中所选节点，含全部有效节点', () {
      final b = ConfigBuilder.build(
        nodes: nodes,
        selected: nodes[1],
        settings: const EngineSettings(),
        clashSecret: 's',
      );
      final j = jsonDecode(b.json) as Map;
      final sel = (j['outbounds'] as List).first as Map;
      expect(sel['type'], 'selector');
      expect(sel['default'], b.selectedTag);
      expect((sel['outbounds'] as List).length, nodes.length);
      expect(b.nodeTags.length, nodes.length);
    });

    test('自动分流规则顺序', () {
      final j = build(
        const EngineSettings(
          routeMode: RouteMode.rule,
          directDomains: ['cn', 'example.org'],
          proxyDomains: ['google.com'],
        ),
      );
      final rules = (j['route'] as Map)['rules'] as List;
      expect(rules[0], {'action': 'sniff'});
      expect(rules[1], {'protocol': 'dns', 'action': 'hijack-dns'});
      expect(rules[2], {'ip_is_private': true, 'outbound': 'direct'});
      expect(rules[3], {
        'domain_suffix': ['cn', 'example.org'],
        'outbound': 'direct',
      });
      expect(rules[4], {
        'domain_suffix': ['google.com'],
        'outbound': 'proxy',
      });
      expect((j['route'] as Map)['final'], 'proxy');
      final dns = j['dns'] as Map;
      expect(dns['final'], 'dns-remote');
      expect((dns['rules'] as List).single['server'], 'dns-direct');
    });

    test('全局模式忽略域名规则，直连模式 final=direct 且无远程 DNS', () {
      final g = build(
        const EngineSettings(
          routeMode: RouteMode.global,
          directDomains: ['cn'],
        ),
      );
      expect(((g['route'] as Map)['rules'] as List).length, 3);
      final d = build(const EngineSettings(routeMode: RouteMode.direct));
      expect((d['route'] as Map)['final'], 'direct');
      expect((d['dns'] as Map)['final'], 'dns-direct');
      expect(((d['dns'] as Map)['servers'] as List).length, 1);
    });

    test('IPv6 开关影响 TUN 地址与 DNS 策略', () {
      final on = build(const EngineSettings(enableIpv6: true));
      final off = build(const EngineSettings(enableIpv6: false));
      expect(((on['inbounds'] as List).first['address'] as List).length, 2);
      expect(((off['inbounds'] as List).first['address'] as List).length, 1);
      expect((off['dns'] as Map)['strategy'], 'ipv4_only');
    });

    test('Clash API 只监听回环地址', () {
      final j = build(const EngineSettings());
      expect(
        ((j['experimental'] as Map)['clash_api'] as Map)['external_controller'],
        startsWith('127.0.0.1:'),
      );
    });

    test('所选节点非法时拒绝生成', () {
      final bad = nodes[1].copyWith(server: 'bad host');
      expect(
        () => ConfigBuilder.build(
          nodes: nodes,
          selected: bad,
          settings: const EngineSettings(),
          clashSecret: 's',
        ),
        throwsA(isA<ConfigBuildException>()),
      );
    });

    test('非法 DNS 被拒绝', () {
      expect(
        () => build(const EngineSettings(directDns: 'not a dns!')),
        throwsA(isA<ConfigBuildException>()),
      );
    });

    final hasBin = File(singBoxBin).existsSync();
    for (final mode in RouteMode.values) {
      for (final v6 in [true, false]) {
        test('sing-box 1.14.3 check 通过：${mode.name} ipv6=$v6', () async {
          final dir = await Directory.systemTemp.createTemp('pp');
          final f = File('${dir.path}/c.json');
          final b = ConfigBuilder.build(
            nodes: nodes,
            selected: nodes[0],
            settings: EngineSettings(
              routeMode: mode,
              enableIpv6: v6,
              directDomains: const ['cn'],
              proxyDomains: const ['google.com'],
              remoteDns: 'https://dns.google/dns-query',
            ),
            clashSecret: 'x',
          );
          await f.writeAsString(b.json);
          final r = await Process.run(singBoxBin, ['check', '-c', f.path]);
          await dir.delete(recursive: true);
          expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
        }, skip: hasBin ? false : '未找到宿主机 sing-box：$singBoxBin');
      }
    }
  });

  group('uTLS 指纹白名单（fp=unsafe 修复回归）', () {
    // 复现用户实际故障：订阅节点带 fp=unsafe → 原样写入 sing-box →
    // "initialize outbound[xx]: unknown uTLS fingerprint: unsafe" →
    // 整份配置校验失败，换任何节点都无法连接。
    ProxyNode dirty({String? fp, String name = 'Dirty'}) => ProxyNode(
      id: 'dirty-${name.hashCode}',
      name: name,
      protocol: ProxyProtocol.vless,
      server: 'd.example.com',
      port: 443,
      secret: const {'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811'},
      tls: TlsOptions(enabled: true, serverName: 'd.example.com', fingerprint: fp),
    );

    /// 按节点 id 找到其对应 outbound（outbounds[0] 是 selector，没有 tls）。
    Map<String, dynamic> outboundOf(
      Map<String, dynamic> j,
      String nodeId,
      Map<String, String> nodeTags,
    ) {
      final tag = nodeTags[nodeId]!;
      final outs = (j['outbounds'] as List).cast<Map<String, dynamic>>();
      return outs.firstWhere((o) => o['tag'] == tag);
    }

    BuiltConfig buildWith(List<ProxyNode> ns, ProxyNode sel) =>
        ConfigBuilder.build(
          nodes: ns,
          selected: sel,
          settings: const EngineSettings(),
          clashSecret: 'x',
        );

    test('库中旧数据 fingerprint=unsafe 被净化：不写入 utls', () {
      final d = dirty(fp: 'unsafe');
      final b = buildWith([...nodes, d], d);
      final j = jsonDecode(b.json) as Map<String, dynamic>;
      final outs = (j['outbounds'] as List).cast<Map<String, dynamic>>();
      for (final o in outs) {
        final utls = (o['tls'] as Map?)?['utls'] as Map?;
        if (utls != null) {
          expect(
            utls['fingerprint'],
            isNot('unsafe'),
            reason: '任何 outbound 都不得携带 sing-box 不认识的指纹',
          );
        }
      }
    });

    test('合法 fingerprint=firefox 原样写入', () {
      final d = dirty(fp: 'firefox');
      final b = buildWith([d], d);
      final j = jsonDecode(b.json) as Map<String, dynamic>;
      final o = outboundOf(j, d.id, b.nodeTags);
      final utls = (o['tls'] as Map)['utls'] as Map;
      expect(utls['fingerprint'], 'firefox');
    });

    test('REALITY + fingerprint=unsafe：utls 回退 chrome（而非 unsafe）', () {
      final d = ProxyNode(
        id: 'dirty-reality',
        name: 'DirtyReality',
        protocol: ProxyProtocol.vless,
        server: 'd.example.com',
        port: 443,
        secret: const {'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811'},
        tls: const TlsOptions(
          enabled: true,
          serverName: 'www.apple.com',
          fingerprint: 'unsafe',
          realityPublicKey: 'Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw',
          realityShortId: '6ba85179e30d4fc2',
        ),
      );
      final b = buildWith([d], d);
      final j = jsonDecode(b.json) as Map<String, dynamic>;
      final o = outboundOf(j, d.id, b.nodeTags);
      final tls = o['tls'] as Map;
      final utls = tls['utls'] as Map;
      expect(utls['fingerprint'], 'chrome');
    });

    test('真实 sing-box check：混合合法/非法指纹的配置全部通过', () async {
      final hasBin = File(singBoxBin).existsSync();
      if (!hasBin) return; // 与上方 check 测试同一跳过条件
      final dirtyVless = dirty(fp: 'unsafe', name: 'DirtyVless');
      final dirtyReality = dirty(fp: 'unsafe', name: 'DirtyReality').copyWith(
        tls: const TlsOptions(
          enabled: true,
          serverName: 'www.apple.com',
          fingerprint: 'unsafe',
          realityPublicKey: 'Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw',
          realityShortId: '6ba85179e30d4fc2',
        ),
      );
      final good = dirty(fp: 'safari', name: 'Good');
      final b = ConfigBuilder.build(
        nodes: [...nodes, dirtyVless, dirtyReality, good],
        selected: nodes[1],
        settings: const EngineSettings(),
        clashSecret: 'x',
      );
      final dir = await Directory.systemTemp.createTemp('pp');
      final f = File('${dir.path}/c.json');
      await f.writeAsString(b.json);
      final r = await Process.run(singBoxBin, ['check', '-c', f.path]);
      await dir.delete(recursive: true);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    });
  });

  group('规则命中', () {
    const s = EngineSettings(
      routeMode: RouteMode.rule,
      directDomains: ['cn', 'example.org'],
      proxyDomains: ['google.com'],
    );
    test('私有地址直连', () {
      expect(RouteExplainer.explain('192.168.1.1', s).$1, 'direct');
      expect(RouteExplainer.explain('10.2.3.4', s).$1, 'direct');
      expect(RouteExplainer.explain('172.20.0.1', s).$1, 'direct');
      expect(RouteExplainer.explain('172.32.0.1', s).$1, 'proxy');
      expect(RouteExplainer.explain('fd00::1', s).$1, 'direct');
    });
    test('域名后缀', () {
      expect(RouteExplainer.explain('www.baidu.cn', s).$1, 'direct');
      expect(RouteExplainer.explain('example.org', s).$1, 'direct');
      expect(RouteExplainer.explain('notexample.org', s).$1, 'proxy');
      expect(RouteExplainer.explain('mail.google.com', s), (
        'proxy',
        '规则 5：代理域名后缀 google.com',
      ));
      expect(RouteExplainer.explain('github.com', s).$1, 'proxy');
    });
    test('模式', () {
      expect(
        RouteExplainer.explain(
          'www.baidu.cn',
          const EngineSettings(
            routeMode: RouteMode.global,
            directDomains: ['cn'],
          ),
        ).$1,
        'proxy',
      );
      expect(
        RouteExplainer.explain(
          'github.com',
          const EngineSettings(routeMode: RouteMode.direct),
        ).$1,
        'direct',
      );
    });
  });
}
