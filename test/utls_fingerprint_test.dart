// 回归：initialize outbound[N]: unknown uTLS fingerprint: unsafe
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypilot_mobile/core/engine/config_builder.dart';
import 'package:proxypilot_mobile/core/engine/node_validator.dart';
import 'package:proxypilot_mobile/core/engine/utls_fingerprint.dart';
import 'package:proxypilot_mobile/core/models/models.dart';
import 'package:proxypilot_mobile/core/networking/share_link_parser.dart';

const singBoxBin = String.fromEnvironment(
  'SING_BOX_BIN',
  defaultValue: '/workspace/tools/bin/sing-box',
);

void main() {
  var i = 0;
  final parser = ShareLinkParser(
    newId: () => '${(i++).toString().padLeft(4, '0')}fpfpfpfp',
  );
  const uuid = 'b831381d-6324-4d53-ad4f-8cda48b30811';
  const pbk = 'Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw';
  const sid = '6ba85179e30d4fc2';
  String reality(String fp, {String name = 'R'}) =>
      'vless://$uuid@r.example.com:443?security=reality&sni=www.apple.com'
      '&pbk=$pbk&sid=$sid${fp.isEmpty ? '' : '&fp=$fp'}'
      '&flow=xtls-rprx-vision&type=tcp#$name';
  String trojan(String fp) =>
      'trojan://pw@t.example.com:443?sni=t.example.com&type=ws&path=%2Fws'
      '&host=cdn.example.com${fp.isEmpty ? '' : '&fp=$fp'}#T';

  Map<String, dynamic> outboundOf(ProxyNode n) =>
      ConfigBuilder.nodeOutbound(n, 'x');
  Map<String, dynamic>? tlsOf(ProxyNode n) =>
      (outboundOf(n)['tls'] as Map?)?.cast<String, dynamic>();

  ProxyNode dbRoundTrip(ProxyNode n) => ProxyNode.fromDbRow(
    jsonDecode(jsonEncode(n.toDbRow())) as Map<String, Object?>,
    Map.of(n.secret),
  );

  final hasBin = File(singBoxBin).existsSync();
  Future<ProcessResult> check(Map<String, dynamic> cfg) async {
    final dir = await Directory.systemTemp.createTemp('fp');
    final f = File('${dir.path}/c.json');
    await f.writeAsString(jsonEncode(cfg));
    final r = await Process.run(singBoxBin, ['check', '-c', f.path]);
    await dir.delete(recursive: true);
    return r;
  }

  Future<ProcessResult> checkBuilt(List<ProxyNode> nodes, ProxyNode sel) =>
      check(
        jsonDecode(
              ConfigBuilder.build(
                nodes: nodes,
                selected: sel,
                settings: const EngineSettings(),
                clashSecret: 's',
              ).json,
            )
            as Map<String, dynamic>,
      );

  group('resolveUtlsFingerprint', () {
    test('合法值不被改写（大小写/空白规范化）', () {
      for (final v in singBoxUtlsFingerprints) {
        final r = resolveUtlsFingerprint(v);
        expect(r.status, FingerprintStatus.supported);
        expect(r.value, v);
        expect(r.changed, isFalse);
      }
      expect(resolveUtlsFingerprint(' Chrome ').value, 'chrome');
    });
    test('空值/空白 → 未设置', () {
      for (final v in [null, '', '  ']) {
        final r = resolveUtlsFingerprint(v);
        expect(r.status, FingerprintStatus.unset);
        expect(r.value, isNull);
        expect(r.message, isNull);
      }
    });
    test('unsafe → 不启用 uTLS，带诊断', () {
      final r = resolveUtlsFingerprint('unsafe');
      expect(r.status, FingerprintStatus.unsafeOptOut);
      expect(r.value, isNull);
      expect(r.message, contains('unsafe'));
    });
    test('其他不支持的值 → 确定性丢弃并可诊断', () {
      final r = resolveUtlsFingerprint('chrome_999');
      expect(r.status, FingerprintStatus.unsupported);
      expect(r.value, isNull);
      expect(r.message, contains('chrome_999'));
    });
  });

  group('配置生成', () {
    test('REALITY + fp=unsafe：使用 chrome，REALITY 字段完整保留', () {
      final n = parser.parseLink(reality('unsafe'));
      final o = outboundOf(n);
      final tls = tlsOf(n)!;
      expect(tls['utls'], {'enabled': true, 'fingerprint': 'chrome'});
      expect(tls['server_name'], 'www.apple.com');
      expect(tls['reality'], {
        'enabled': true,
        'public_key': pbk,
        'short_id': sid,
      });
      expect(o['uuid'], uuid);
      expect(o['flow'], 'xtls-rprx-vision');
      expect(jsonEncode(o), isNot(contains('unsafe')));
    });
    test('REALITY + 合法 fp 原样保留', () {
      expect(tlsOf(parser.parseLink(reality('firefox')))!['utls'], {
        'enabled': true,
        'fingerprint': 'firefox',
      });
    });
    test('REALITY + 空 fp：使用内核默认 chrome', () {
      expect(tlsOf(parser.parseLink(reality('')))!['utls'], {
        'enabled': true,
        'fingerprint': 'chrome',
      });
    });
    test('普通 TLS + fp=unsafe：不写 utls，证书校验不受影响', () {
      final tls = tlsOf(parser.parseLink(trojan('unsafe')))!;
      expect(tls.containsKey('utls'), isFalse);
      expect(tls.containsKey('insecure'), isFalse);
      expect(tls['server_name'], 't.example.com');
    });
    test('普通 TLS + 空 fp：不写 utls', () {
      expect(tlsOf(parser.parseLink(trojan('')))!.containsKey('utls'), isFalse);
    });
    test('非所选节点的指纹被处理时给出警告（含节点名）', () {
      final bad = parser.parseLink(reality('unsafe', name: '坏节点'));
      final good = parser.parseLink(trojan('chrome'));
      final b = ConfigBuilder.build(
        nodes: [good, bad],
        selected: good,
        settings: const EngineSettings(),
        clashSecret: 's',
      );
      expect(b.json, isNot(contains('"unsafe"')));
      expect(b.warnings.any((w) => w.contains('坏节点')), isTrue);
    });
    test('校验器对不支持的指纹给警告而非静默', () {
      final r = NodeValidator.validate(parser.parseLink(trojan('unsafe')));
      expect(r.ok, isTrue);
      expect(r.warnings.any((w) => w.contains('unsafe')), isTrue);
    });
  });

  group('整条链路', () {
    test('历史数据库中的 unsafe 不会绕过处理', () {
      final stored = dbRoundTrip(parser.parseLink(reality('unsafe')));
      expect(stored.tls.fingerprint, 'unsafe'); // 历史数据原样
      expect(jsonEncode(outboundOf(stored)), isNot(contains('unsafe')));
    });
    test('分享链接 → 存储 → 读取 → 配置 结果一致', () {
      for (final fp in ['', 'chrome', 'safari', 'unsafe', 'bogus']) {
        final n = parser.parseLink(reality(fp));
        final back = dbRoundTrip(n);
        expect(back.tls.realityPublicKey, pbk);
        expect(back.tls.realityShortId, sid);
        expect(back.options['flow'], 'xtls-rprx-vision');
        expect(outboundOf(back), outboundOf(n), reason: 'fp=$fp');
      }
    });
    test('sing-box JSON 导入的 unsafe 同样被处理', () {
      final rep = parser.parseBulk(
        jsonEncode({
          'outbounds': [
            {
              'type': 'vless',
              'tag': 'j',
              'server': 'r.example.com',
              'server_port': 443,
              'uuid': uuid,
              'flow': 'xtls-rprx-vision',
              'tls': {
                'enabled': true,
                'server_name': 'www.apple.com',
                'utls': {'enabled': true, 'fingerprint': 'unsafe'},
                'reality': {'enabled': true, 'public_key': pbk, 'short_id': sid},
              },
            },
          ],
        }),
      );
      expect(rep.nodes, hasLength(1));
      final tls = tlsOf(rep.nodes.single)!;
      expect(tls['utls'], {'enabled': true, 'fingerprint': 'chrome'});
      expect((tls['reality'] as Map)['public_key'], pbk);
    });
    test('重复导入不会重新引入非法值', () {
      final a = parser.parseBulk('${reality('unsafe')}\n${reality('unsafe')}');
      for (final n in a.nodes) {
        expect(jsonEncode(outboundOf(n)), isNot(contains('unsafe')));
      }
    });
  });

  test('内核报错 outbound[N] 能定位到具体节点（不假设为所选节点）', () {
    final a = parser.parseLink(trojan('chrome'));
    final b = parser.parseLink(reality('chrome', name: '第二个'));
    final built = ConfigBuilder.build(
      nodes: [a, b],
      selected: a,
      settings: const EngineSettings(),
      clashSecret: 's',
    );
    final outs = (jsonDecode(built.json) as Map)['outbounds'] as List;
    final idx = outs.indexWhere((o) => o['tag'] == built.nodeTags[b.id]);
    expect(
      built.annotateError('initialize outbound[$idx]: boom'),
      'initialize outbound[$idx]（节点「第二个」）: boom',
    );
    expect(built.outboundLabels, hasLength(outs.length));
    expect(built.annotateError('outbound[99]: x'), 'outbound[99]: x');
  });

  group('sing-box 1.14.3 真实校验', () {
    test('复现：原始 fingerprint=unsafe 会被内核拒绝', () async {
      final r = await check({
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'x',
            'server': 'r.example.com',
            'server_port': 443,
            'uuid': uuid,
            'tls': {
              'enabled': true,
              'server_name': 'www.apple.com',
              'utls': {'enabled': true, 'fingerprint': 'unsafe'},
              'reality': {'enabled': true, 'public_key': pbk, 'short_id': sid},
            },
          },
        ],
      });
      expect(r.exitCode, isNot(0));
      expect('${r.stderr}${r.stdout}', contains('unknown uTLS fingerprint: unsafe'));
    }, skip: hasBin ? false : '未找到宿主机 sing-box');

    test('修复后：含 unsafe/不支持指纹的多节点配置通过 check', () async {
      final nodes = [
        parser.parseLink(reality('chrome', name: 'ok')),
        parser.parseLink(reality('unsafe', name: 'u')),
        parser.parseLink(reality('bogus', name: 'b')),
        parser.parseLink(trojan('unsafe')),
        dbRoundTrip(parser.parseLink(reality('unsafe', name: 'db'))),
      ];
      final r = await checkBuilt(nodes, nodes.first);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    }, skip: hasBin ? false : '未找到宿主机 sing-box');

    test('所有合法指纹都通过 check', () async {
      final nodes = [
        for (final fp in singBoxUtlsFingerprints)
          parser.parseLink(reality(fp, name: fp)),
      ];
      final r = await checkBuilt(nodes, nodes.first);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    }, skip: hasBin ? false : '未找到宿主机 sing-box');
  });
}
