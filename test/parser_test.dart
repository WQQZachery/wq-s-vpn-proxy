import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypilot_mobile/core/engine/node_validator.dart';
import 'package:proxypilot_mobile/core/models/models.dart';
import 'package:proxypilot_mobile/core/networking/share_link_parser.dart';

void main() {
  var i = 0;
  final parser = ShareLinkParser(newId: () => 'id${i++}xxxxxxxx');
  const uuid = 'b831381d-6324-4d53-ad4f-8cda48b30811';
  const pbk = 'Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw';

  group('分享链接解析', () {
    test('ss SIP002 base64 userinfo', () {
      final cred = base64Url
          .encode(utf8.encode('aes-256-gcm:p@ss:word'))
          .replaceAll('=', '');
      final n = parser.parseLink('ss://$cred@1.2.3.4:8388#%E6%B5%8B%E8%AF%95');
      expect(n.protocol, ProxyProtocol.shadowsocks);
      expect(n.server, '1.2.3.4');
      expect(n.port, 8388);
      expect(n.secret['password'], 'p@ss:word');
      expect(n.options['method'], 'aes-256-gcm');
      expect(n.name, '测试');
    });

    test('ss 旧格式整体 base64', () {
      final body = base64.encode(
        utf8.encode('chacha20-ietf-poly1305:pw@example.com:443'),
      );
      final n = parser.parseLink('ss://$body#old');
      expect(n.server, 'example.com');
      expect(n.port, 443);
      expect(n.secret['password'], 'pw');
    });

    test('ss 不支持的插件被拒绝', () {
      final cred = base64Url.encode(utf8.encode('aes-128-gcm:pw'));
      expect(
        () => parser.parseLink('ss://$cred@h.com:1?plugin=kcptun#x'),
        throwsA(isA<NodeParseException>()),
      );
    });

    test('vmess base64 json + ws + tls', () {
      final j = {
        'v': '2',
        'ps': 'vm',
        'add': 'vm.example.com',
        'port': '443',
        'id': uuid,
        'aid': '0',
        'scy': 'auto',
        'net': 'ws',
        'host': 'cdn.example.com',
        'path': '/ray',
        'tls': 'tls',
        'sni': 'vm.example.com',
      };
      final n = parser.parseLink(
        'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}',
      );
      expect(n.protocol, ProxyProtocol.vmess);
      expect(n.transport.type, 'ws');
      expect(n.transport.path, '/ray');
      expect(n.transport.host, 'cdn.example.com');
      expect(n.tls.enabled, isTrue);
      expect(n.tls.serverName, 'vm.example.com');
    });

    test('vless reality vision', () {
      final n = parser.parseLink(
        'vless://$uuid@r.example.com:443?security=reality&sni=www.apple.com&pbk=$pbk&sid=6ba85179e30d4fc2&fp=chrome&flow=xtls-rprx-vision&type=tcp#R',
      );
      expect(n.tls.isReality, isTrue);
      expect(n.options['flow'], 'xtls-rprx-vision');
      expect(
        NodeValidator.validate(n).ok,
        isTrue,
        reason: NodeValidator.validate(n).errors.join(),
      );
    });

    test('vless reality 缺少 pbk 被拒绝', () {
      expect(
        () => parser.parseLink(
          'vless://$uuid@r.example.com:443?security=reality&sni=a.com',
        ),
        throwsA(isA<NodeParseException>()),
      );
    });

    test('trojan grpc', () {
      final n = parser.parseLink(
        'trojan://secret@t.example.com:443?sni=t.example.com&type=grpc&serviceName=svc#T',
      );
      expect(n.protocol, ProxyProtocol.trojan);
      expect(n.transport.type, 'grpc');
      expect(n.transport.serviceName, 'svc');
    });

    test('hysteria2 / hy2 salamander', () {
      final n = parser.parseLink(
        'hy2://auth@h.example.com:8443?sni=h.example.com&obfs=salamander&obfs-password=ob#H',
      );
      expect(n.protocol, ProxyProtocol.hysteria2);
      expect(n.secret['obfs_password'], 'ob');
      expect(NodeValidator.validate(n).ok, isTrue);
    });

    test('hysteria2 端口跳跃明确报不支持', () {
      expect(
        () => parser.parseLink('hysteria2://a@h.com:443?mport=1000-2000'),
        throwsA(
          predicate(
            (e) => e is NodeParseException && e.message.startsWith('不支持'),
          ),
        ),
      );
    });

    test('tuic', () {
      final n = parser.parseLink(
        'tuic://$uuid:pw@t.example.com:443?congestion_control=bbr&alpn=h3&sni=t.example.com#TU',
      );
      expect(n.secret['uuid'], uuid);
      expect(n.options['congestion_control'], 'bbr');
    });

    test('socks5 用户名密码', () {
      final n = parser.parseLink('socks5://user:pass@10.0.0.1:1080#S');
      expect(n.secret['username'], 'user');
      expect(n.secret['password'], 'pass');
    });

    test('未知/不支持协议', () {
      expect(
        () => parser.parseLink('ssr://abc'),
        throwsA(
          predicate(
            (e) => e is NodeParseException && e.message.contains('不支持'),
          ),
        ),
      );
      expect(
        () => parser.parseLink('foo://abc'),
        throwsA(isA<NodeParseException>()),
      );
      expect(
        () => parser.parseLink('not a link'),
        throwsA(isA<NodeParseException>()),
      );
    });

    test('端口越界', () {
      expect(
        () => parser.parseLink('trojan://pw@h.com:70000'),
        throwsA(isA<NodeParseException>()),
      );
    });
  });

  group('订阅解析与去重', () {
    test('Base64 订阅 + 错误条目统计', () {
      final lines = [
        'trojan://pw@a.example.com:443#A',
        'trojan://pw@a.example.com:443#A-renamed',
        'ssr://xxxx',
        'vless://bad-uuid@b.com:443',
        'tuic://$uuid:pw@c.example.com:443#C',
      ].join('\n');
      final rep = parser.parseBulk(base64.encode(utf8.encode(lines)));
      expect(rep.format, 'base64');
      expect(rep.nodes.length, 3);
      expect(rep.issues.length, 2);
      expect(rep.unsupportedCount, 1);
      final (unique, removed) = dedupNodes(rep.nodes);
      expect(unique.length, 2);
      expect(removed, 1);
    });

    test('sing-box JSON 订阅', () {
      final cfg = jsonEncode({
        'outbounds': [
          {
            'type': 'selector',
            'tag': 'sel',
            'outbounds': ['a'],
          },
          {
            'type': 'shadowsocks',
            'tag': 'a',
            'server': 's.example.com',
            'server_port': 8388,
            'method': '2022-blake3-aes-128-gcm',
            'password': 'AAAAAAAAAAAAAAAAAAAAAA==',
          },
          {'type': 'naive', 'tag': 'n', 'server': 'n.com', 'server_port': 443},
          {'type': 'direct', 'tag': 'direct'},
        ],
      });
      final rep = parser.parseBulk(cfg);
      expect(rep.format, 'sing-box-json');
      expect(rep.nodes.single.name, 'a');
      expect(rep.unsupportedCount, 1);
    });

    test('HTML / Clash YAML / 空内容给出明确错误', () {
      expect(
        () => parser.parseBulk('<html>login</html>'),
        throwsA(
          predicate(
            (e) => e is NodeParseException && e.message.contains('HTML'),
          ),
        ),
      );
      expect(
        () => parser.parseBulk('port: 7890\nproxies:\n  - name: a'),
        throwsA(
          predicate(
            (e) => e is NodeParseException && e.message.contains('Clash'),
          ),
        ),
      );
      expect(() => parser.parseBulk('   '), throwsA(isA<NodeParseException>()));
    });
  });

  group('节点校验', () {
    ProxyNode base({
      ProxyProtocol p = ProxyProtocol.trojan,
      Map<String, String> secret = const {'password': 'x'},
      Map<String, dynamic> options = const {},
      TlsOptions tls = const TlsOptions(enabled: true),
      String server = 'a.example.com',
      int port = 443,
    }) => ProxyNode(
      id: 'n1xxxxxxxx',
      name: 'n',
      protocol: p,
      server: server,
      port: port,
      secret: secret,
      options: options,
      tls: tls,
    );

    test('合法 trojan', () => expect(NodeValidator.validate(base()).ok, isTrue));
    test(
      '非法主机',
      () =>
          expect(NodeValidator.validate(base(server: 'bad host!')).ok, isFalse),
    );
    test(
      'IPv4 越界',
      () =>
          expect(NodeValidator.validate(base(server: '300.1.1.1')).ok, isFalse),
    );
    test(
      'IPv6 合法',
      () => expect(
        NodeValidator.validate(base(server: '2001:db8::1')).ok,
        isTrue,
      ),
    );
    test('拒绝跳过证书校验', () {
      final r = NodeValidator.validate(
        base(tls: const TlsOptions(enabled: true, insecure: true)),
      );
      expect(r.ok, isFalse);
      expect(r.errors.join(), contains('证书'));
    });
    test('SS 不支持的加密', () {
      expect(
        NodeValidator.validate(
          base(p: ProxyProtocol.shadowsocks, options: {'method': 'rc4-md5'}),
        ).ok,
        isFalse,
      );
    });
    test('vision 不能配 ws', () {
      final n = ProxyNode(
        id: 'x',
        name: 'v',
        protocol: ProxyProtocol.vless,
        server: 'a.com',
        port: 443,
        secret: const {'uuid': uuid},
        options: const {'flow': 'xtls-rprx-vision'},
        tls: const TlsOptions(enabled: true),
        transport: const TransportOptions(type: 'ws', path: '/'),
      );
      expect(NodeValidator.validate(n).ok, isFalse);
    });
  });

  group('uTLS 指纹白名单（fp=unsafe 修复回归）', () {
    // 背景：部分订阅/分享链接带 fp=unsafe（其他客户端“跳过证书校验”的约定值），
    // sing-box 不识别该指纹名，原样写入会导致整份配置校验失败、换任何节点都连不上。
    const uuid2 = 'b831381d-6324-4d53-ad4f-8cda48b30811';
    test('fp=unsafe 在导入时被丢弃', () {
      final n = parser.parseLink(
        'vless://$uuid2@a.example.com:443?security=tls&sni=a.example.com&fp=unsafe#X',
      );
      expect(n.tls.fingerprint, isNull);
    });
    test('fp=chrome 原样保留', () {
      final n = parser.parseLink(
        'vless://$uuid2@a.example.com:443?security=tls&fp=chrome#X',
      );
      expect(n.tls.fingerprint, 'chrome');
    });
    test('大小写与空白被规整（Firefox → firefox）', () {
      final n = parser.parseLink(
        'vless://$uuid2@a.example.com:443?security=tls&fp=%20Firefox%20#X',
      );
      expect(n.tls.fingerprint, 'firefox');
    });
    test('合法新值 randomized 保留', () {
      final n = parser.parseLink(
        'vless://$uuid2@a.example.com:443?security=tls&fp=randomized#X',
      );
      expect(n.tls.fingerprint, 'randomized');
    });
    test('sanitizeUtlsFingerprint 白名单行为', () {
      expect(sanitizeUtlsFingerprint(null), isNull);
      expect(sanitizeUtlsFingerprint(''), isNull);
      expect(sanitizeUtlsFingerprint('  '), isNull);
      expect(sanitizeUtlsFingerprint('unsafe'), isNull);
      expect(sanitizeUtlsFingerprint('allowInsecure'), isNull);
      expect(sanitizeUtlsFingerprint('Chrome'), 'chrome');
      expect(sanitizeUtlsFingerprint('safari'), 'safari');
    });
    test('healUtlsFingerprint 自愈：非法值清除、合法值原样返回', () {
      final base = ProxyNode(
        id: 'x',
        name: 'v',
        protocol: ProxyProtocol.vless,
        server: 'a.com',
        port: 443,
        secret: const {'uuid': uuid2},
        tls: const TlsOptions(enabled: true, fingerprint: 'unsafe'),
      );
      final healed = healUtlsFingerprint(base);
      expect(healed.tls.fingerprint, isNull);
      expect(healed.tls.enabled, isTrue);

      final ok = base.copyWith(
        tls: const TlsOptions(enabled: true, fingerprint: 'chrome'),
      );
      expect(identical(healUtlsFingerprint(ok), ok), isTrue);
    });
    test('REALITY 节点 fp=unsafe 导入后无指纹（内核侧回退 chrome）', () {
      final n = parser.parseLink(
        'vless://$uuid2@a.example.com:443?security=reality&sni=www.apple.com'
        '&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=6ba85179e30d4fc2&fp=unsafe#R',
      );
      expect(n.tls.isReality, isTrue);
      expect(n.tls.fingerprint, isNull);
    });
  });
}
