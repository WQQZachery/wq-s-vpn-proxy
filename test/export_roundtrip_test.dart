// R2：序列化 → 解析往返，必要字段不丢失。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypilot_mobile/core/models/models.dart';
import 'package:proxypilot_mobile/core/networking/share_link_parser.dart';
import 'package:proxypilot_mobile/core/networking/share_link_serializer.dart';

void main() {
  var i = 0;
  final parser = ShareLinkParser(
    newId: () => '${(i++).toString().padLeft(4, '0')}rtrtrtrt',
  );
  const uuid = 'b831381d-6324-4d53-ad4f-8cda48b30811';
  final links = <String>[
    'vless://$uuid@r.example.com:443?security=reality&sni=www.apple.com&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=6ba85179e30d4fc2&fp=chrome&flow=xtls-rprx-vision#Reality%20%E8%8A%82%E7%82%B9',
    'vless://$uuid@r.example.com:443?security=reality&sni=www.apple.com&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=&fp=unsafe#R2',
    'vless://$uuid@v.example.com:8443?security=tls&sni=v.example.com&alpn=h2,http/1.1&type=grpc&serviceName=svc#VG',
    'vless://$uuid@[2001:db8::1]:443?security=none&type=ws&path=%2Fa%3Fed%3D2048&host=cdn.example.com#V6',
    'trojan://p%40ss%3Aword@t.example.com:443?sni=t.example.com&type=ws&path=%2Fws&host=cdn.example.com#T',
    'trojan://pw@t2.example.com:443?type=httpupgrade&path=%2Fup&host=h.example.com&fp=firefox#T2',
    'hy2://auth@h.example.com:8443?sni=h.example.com&obfs=salamander&obfs-password=ob#H',
    'tuic://$uuid:pw@u.example.com:443?congestion_control=bbr&udp_relay_mode=quic&sni=u.example.com&alpn=h3#U',
    'ss://${base64Url.encode(utf8.encode('2022-blake3-aes-128-gcm:AAAAAAAAAAAAAAAAAAAAAA=='))}@s.example.com:8388#S',
    'ss://${base64Url.encode(utf8.encode('aes-256-gcm:pw'))}@s2.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dx.com#S2',
    'vmess://${base64.encode(utf8.encode(jsonEncode({'ps': 'V', 'add': 'v.example.com', 'port': '443', 'id': uuid, 'aid': '0', 'net': 'grpc', 'path': 'svc', 'tls': 'tls', 'sni': 'v.example.com', 'fp': 'safari'})))}',
    'vmess://${base64.encode(utf8.encode(jsonEncode({'ps': '中文', 'add': 'w.example.com', 'port': '80', 'id': uuid, 'aid': '0', 'scy': 'chacha20-poly1305', 'net': 'ws', 'path': '/w', 'host': 'w.example.com', 'tls': ''})))}',
    'socks5://u:p@10.0.0.2:1080#K',
    'socks5://10.0.0.3:1080#K2',
  ];

  Map<String, Object?> essential(ProxyNode n) {
    final r = n.toDbRow()
      ..remove('id')
      ..remove('created_at')
      ..remove('source');
    return {...r, 'secret': n.secret};
  }

  for (final l in links) {
    test('往返：${l.substring(0, l.indexOf('://'))} ${l.split('#').last}', () {
      final a = parser.parseLink(l);
      final out = ShareLinkSerializer.toLink(a);
      final b = parser.parseLink(out);
      expect(essential(b), essential(a), reason: out);
      expect(b.dedupKey, a.dedupKey);
    });
  }

  test('批量与订阅格式可被 parseBulk 读回，数量与内容一致', () {
    final nodes = links.map(parser.parseLink).toList();
    final lines = ShareLinkSerializer.toLines(nodes);
    final sub = ShareLinkSerializer.toSubscription(nodes);
    expect(lines.skipped, isEmpty);
    for (final text in [lines.text, sub.text]) {
      final rep = parser.parseBulk(text);
      expect(rep.issues, isEmpty);
      expect(rep.nodes.map(essential).toList(), nodes.map(essential).toList());
    }
  });

  test('HTTP 节点无法导出时被明确跳过', () {
    final h = ProxyNode(
      id: 'h',
      name: 'Hp',
      protocol: ProxyProtocol.http,
      server: 'p.example.com',
      port: 8080,
    );
    expect(ShareLinkSerializer.canExport(h), isFalse);
    expect(() => ShareLinkSerializer.toLink(h), throwsA(isA<ShareLinkExportException>()));
    expect(ShareLinkSerializer.toLines([h]).skipped, ['Hp']);
  });
}
