// SPDX-License-Identifier: GPL-3.0-or-later
// 节点 → 分享链接序列化（ShareLinkParser 的逆操作）。
//
// 只输出 ShareLinkParser 能解析回来的格式，保证“序列化 → 解析”往返不丢必要字段。
// 输出内容包含凭据（UUID/密码/REALITY 参数），调用方必须先向用户做隐私提示。
import 'dart:convert';

import '../models/models.dart';

class ShareLinkExportException implements Exception {
  ShareLinkExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ShareLinkSerializer {
  const ShareLinkSerializer._();

  static bool canExport(ProxyNode n) => n.protocol != ProxyProtocol.http;

  /// 导出单个节点为分享链接。指纹按原样导出（不在导出时改写用户数据）。
  static String toLink(ProxyNode n) {
    final name = Uri.encodeComponent(n.name);
    final host = n.server.contains(':') ? '[${n.server}]' : n.server;
    String sec(String k) => n.secret[k] ?? '';
    String enc(String v) => Uri.encodeComponent(v);
    String query(Map<String, String?> q) {
      final parts = [
        for (final e in q.entries)
          if (e.value != null && e.value!.isNotEmpty)
            '${e.key}=${Uri.encodeQueryComponent(e.value!)}',
      ];
      return parts.isEmpty ? '' : '?${parts.join('&')}';
    }

    Map<String, String?> transportQ() {
      final t = n.transport;
      return {
        'type': t.type,
        if (t.type == 'grpc') 'serviceName': t.serviceName,
        if (t.type != 'grpc') 'path': t.path,
        if (t.type != 'grpc') 'host': t.host,
      };
    }

    Map<String, String?> tlsQ({bool includeFp = true}) => {
      'sni': n.tls.serverName,
      if (n.tls.alpn.isNotEmpty) 'alpn': n.tls.alpn.join(','),
      if (includeFp) 'fp': n.tls.fingerprint,
    };

    switch (n.protocol) {
      case ProxyProtocol.shadowsocks:
        final ui = base64Url
            .encode(utf8.encode('${n.options['method']}:${sec('password')}'))
            .replaceAll('=', '');
        final plugin = n.options['plugin'] as String?;
        final opts = n.options['plugin_opts'] as String? ?? '';
        final q = plugin == null
            ? ''
            : '/?plugin=${Uri.encodeQueryComponent(opts.isEmpty ? plugin : '$plugin;$opts')}';
        return 'ss://$ui@$host:${n.port}$q#$name';
      case ProxyProtocol.vmess:
        final t = n.transport;
        final j = {
          'v': '2',
          'ps': n.name,
          'add': n.server,
          'port': '${n.port}',
          'id': sec('uuid'),
          'aid': '${n.options['alter_id'] ?? 0}',
          'scy': '${n.options['security'] ?? 'auto'}',
          'net': t.type,
          'type': 'none',
          'host': t.host ?? '',
          'path': t.type == 'grpc' ? (t.serviceName ?? '') : (t.path ?? ''),
          'tls': n.tls.enabled ? 'tls' : '',
          'sni': n.tls.serverName ?? '',
          'alpn': n.tls.alpn.join(','),
          'fp': n.tls.fingerprint ?? '',
        };
        return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
      case ProxyProtocol.vless:
        final security = n.tls.isReality
            ? 'reality'
            : (n.tls.enabled ? 'tls' : 'none');
        return 'vless://${enc(sec('uuid'))}@$host:${n.port}${query({
          'encryption': 'none',
          'security': security,
          'flow': n.options['flow'] as String?,
          ...tlsQ(),
          if (n.tls.isReality) 'pbk': n.tls.realityPublicKey,
          if (n.tls.isReality) 'sid': n.tls.realityShortId,
          if (n.tls.insecure) 'allowInsecure': '1',
          ...transportQ(),
        })}#$name';
      case ProxyProtocol.trojan:
        return 'trojan://${enc(sec('password'))}@$host:${n.port}${query({
          if (!n.tls.enabled) 'security': 'none',
          ...tlsQ(),
          if (n.tls.insecure) 'allowInsecure': '1',
          ...transportQ(),
        })}#$name';
      case ProxyProtocol.hysteria2:
        return 'hysteria2://${enc(sec('password'))}@$host:${n.port}${query({
          ...tlsQ(includeFp: false),
          if (n.options['obfs'] == 'salamander') 'obfs': 'salamander',
          if (n.options['obfs'] == 'salamander')
            'obfs-password': sec('obfs_password'),
          if (n.tls.insecure) 'insecure': '1',
        })}#$name';
      case ProxyProtocol.tuic:
        return 'tuic://${enc(sec('uuid'))}:${enc(sec('password'))}@$host:${n.port}${query({
          'congestion_control': n.options['congestion_control'] as String?,
          'udp_relay_mode': n.options['udp_relay_mode'] as String?,
          ...tlsQ(includeFp: false),
          if (n.tls.insecure) 'insecure': '1',
        })}#$name';
      case ProxyProtocol.socks:
        final user = sec('username'), pass = sec('password');
        final ui = user.isEmpty && pass.isEmpty
            ? ''
            : '${enc(user)}:${enc(pass)}@';
        return 'socks5://$ui$host:${n.port}#$name';
      case ProxyProtocol.http:
        throw ShareLinkExportException('HTTP 代理没有通用的分享链接格式，无法导出');
    }
  }

  /// 批量导出：返回逐行链接与无法导出的节点名。
  static ({String text, List<String> skipped}) toLines(List<ProxyNode> nodes) {
    final lines = <String>[], skipped = <String>[];
    for (final n in nodes) {
      if (canExport(n)) {
        lines.add(toLink(n));
      } else {
        skipped.add(n.name);
      }
    }
    return (text: lines.join('\n'), skipped: skipped);
  }

  /// 订阅格式（Base64 编码的逐行链接，ShareLinkParser.parseBulk 可直接读回）。
  static ({String text, List<String> skipped}) toSubscription(
    List<ProxyNode> nodes,
  ) {
    final r = toLines(nodes);
    return (text: base64.encode(utf8.encode(r.text)), skipped: r.skipped);
  }
}
