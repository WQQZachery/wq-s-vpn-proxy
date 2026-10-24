// WQ's Proxy VPN — 分享链接 / 订阅内容解析
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import '../models/models.dart';

class NodeParseException implements Exception {
  NodeParseException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ParseIssue {
  const ParseIssue(this.index, this.reason, {this.unsupported = false});

  /// 第几条（从 1 开始）
  final int index;
  final String reason;
  final bool unsupported;
}

class ParseReport {
  ParseReport(this.nodes, this.issues, {this.format = 'unknown'});
  final List<ProxyNode> nodes;
  final List<ParseIssue> issues;

  /// links | base64 | sing-box-json
  final String format;
  int get unsupportedCount => issues.where((i) => i.unsupported).length;
}

typedef IdGen = String Function();

/// 解析器。所有输出都只是“候选节点”，进入数据库或核心前还需经过 [NodeValidator]。
class ShareLinkParser {
  ShareLinkParser({required this.newId});
  final IdGen newId;

  static const supportedSchemes = [
    'ss',
    'vmess',
    'vless',
    'trojan',
    'hysteria2',
    'hy2',
    'tuic',
    'socks',
    'socks5',
  ];
  static const knownUnsupported = {
    'ssr': 'ShadowsocksR 不被 sing-box 支持',
    'naive+https': 'NaïveProxy 出站需要 cronet，本版本未编入',
    'naive+quic': 'NaïveProxy 出站需要 cronet，本版本未编入',
    'hysteria': 'Hysteria v1 本版本未实现解析',
    'wireguard': 'WireGuard 链接本版本未实现解析',
    'anytls': 'AnyTLS 链接本版本未实现解析',
  };

  /// 解析单条分享链接。
  ProxyNode parseLink(
    String raw, {
    NodeSource source = NodeSource.shareLink,
    String? subscriptionId,
  }) {
    final link = raw.trim();
    final sep = link.indexOf('://');
    if (sep <= 0) throw NodeParseException('不是有效的分享链接（缺少 scheme://）');
    final scheme = link.substring(0, sep).toLowerCase();
    if (knownUnsupported.containsKey(scheme)) {
      throw NodeParseException('不支持的协议：${knownUnsupported[scheme]}');
    }
    final ProxyNode node;
    switch (scheme) {
      case 'ss':
        node = _parseSs(link);
      case 'vmess':
        node = _parseVmess(link);
      case 'vless':
        node = _parseVless(link);
      case 'trojan':
        node = _parseTrojan(link);
      case 'hysteria2':
      case 'hy2':
        node = _parseHy2(link);
      case 'tuic':
        node = _parseTuic(link);
      case 'socks':
      case 'socks5':
        node = _parseSocks(link);
      default:
        throw NodeParseException('不支持的协议：$scheme');
    }
    return node.copyWith(source: source, subscriptionId: subscriptionId);
  }

  /// 解析订阅/批量文本：自动识别 sing-box JSON、Base64 或逐行链接。
  ParseReport parseBulk(
    String content, {
    NodeSource source = NodeSource.subscription,
    String? subscriptionId,
  }) {
    final text = content.trim();
    if (text.isEmpty) throw NodeParseException('内容为空');
    if (text.startsWith('{')) {
      return _parseSingBoxJson(
        text,
        source: source,
        subscriptionId: subscriptionId,
      );
    }
    if (_looksLikeClashYaml(text)) {
      throw NodeParseException(
        '检测到 Clash YAML 格式，本版本尚未实现该格式解析；请使用通用（Base64/分享链接）订阅或 sing-box JSON',
      );
    }
    var format = 'links';
    var body = text;
    if (!text.contains('://')) {
      final decoded = tryDecodeBase64(text.replaceAll(RegExp(r'\s'), ''));
      if (decoded == null || !decoded.contains('://')) {
        if (text.startsWith('<')) {
          throw NodeParseException('返回内容是 HTML 页面，订阅链接可能已过期或需要登录');
        }
        throw NodeParseException(
          '无法识别的订阅格式（既不是分享链接，也不是 Base64 或 sing-box JSON）',
        );
      }
      body = decoded;
      format = 'base64';
    }
    final nodes = <ProxyNode>[];
    final issues = <ParseIssue>[];
    final lines = body
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    for (var i = 0; i < lines.length; i++) {
      try {
        nodes.add(
          parseLink(lines[i], source: source, subscriptionId: subscriptionId),
        );
      } on NodeParseException catch (e) {
        issues.add(
          ParseIssue(
            i + 1,
            e.message,
            unsupported: e.message.startsWith('不支持'),
          ),
        );
      } catch (e) {
        issues.add(ParseIssue(i + 1, '解析失败：${e.runtimeType}'));
      }
    }
    return ParseReport(nodes, issues, format: format);
  }

  static bool _looksLikeClashYaml(String t) =>
      RegExp(r'^proxies\s*:', multiLine: true).hasMatch(t) ||
      RegExp(r'^port\s*:\s*\d+', multiLine: true).hasMatch(t);

  /// 宽松 Base64 解码（标准/URL-safe、可缺少填充）。失败返回 null。
  static String? tryDecodeBase64(String s) {
    var t = s.trim().replaceAll('-', '+').replaceAll('_', '/');
    if (t.isEmpty || !RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(t)) return null;
    t = t.replaceAll('=', '');
    while (t.length % 4 != 0) {
      t += '=';
    }
    try {
      return utf8.decode(base64.decode(t), allowMalformed: false);
    } catch (_) {
      return null;
    }
  }

  // ---------------- 各协议 ----------------

  String _fragmentName(Uri u, String fallback) {
    if (u.fragment.isEmpty) return fallback;
    try {
      return Uri.decodeComponent(u.fragment);
    } catch (_) {
      return u.fragment;
    }
  }

  int _port(String? p) {
    final v = int.tryParse(p ?? '');
    if (v == null || v < 1 || v > 65535)
      throw NodeParseException('端口无效：${p ?? '缺失'}');
    return v;
  }

  String _host(String h) {
    var host = h.trim();
    if (host.startsWith('[') && host.endsWith(']'))
      host = host.substring(1, host.length - 1);
    if (host.isEmpty) throw NodeParseException('服务器地址为空');
    return host;
  }

  Uri _uri(String link) {
    try {
      return Uri.parse(link);
    } catch (_) {
      throw NodeParseException('链接格式错误');
    }
  }

  ProxyNode _parseSs(String link) {
    // SIP002: ss://base64url(method:password)@host:port/?plugin=...#name
    // 旧格式: ss://base64(method:password@host:port)#name
    var rest = link.substring(5);
    var name = '';
    final hash = rest.indexOf('#');
    if (hash >= 0) {
      name = Uri.decodeComponent(rest.substring(hash + 1));
      rest = rest.substring(0, hash);
    }
    String method, password, host;
    int port;
    Map<String, String> query = {};
    final q = rest.indexOf('?');
    if (q >= 0) {
      query = Uri.splitQueryString(rest.substring(q + 1));
      rest = rest.substring(0, q);
    }
    if (rest.endsWith('/')) rest = rest.substring(0, rest.length - 1);
    if (rest.contains('@')) {
      final at = rest.lastIndexOf('@');
      final userInfoRaw = rest.substring(0, at);
      final hostPort = rest.substring(at + 1);
      var userInfo =
          tryDecodeBase64(userInfoRaw) ?? Uri.decodeComponent(userInfoRaw);
      final c = userInfo.indexOf(':');
      if (c <= 0) throw NodeParseException('Shadowsocks 用户信息格式错误');
      method = userInfo.substring(0, c);
      password = userInfo.substring(c + 1);
      final hp = _splitHostPort(hostPort);
      host = hp.$1;
      port = hp.$2;
    } else {
      final decoded = tryDecodeBase64(rest);
      if (decoded == null)
        throw NodeParseException('Shadowsocks 链接 Base64 解码失败');
      final m = RegExp(r'^([^:]+):(.*)@(.+)$').firstMatch(decoded);
      if (m == null) throw NodeParseException('Shadowsocks 链接格式错误');
      method = m.group(1)!;
      password = m.group(2)!;
      final hp = _splitHostPort(m.group(3)!);
      host = hp.$1;
      port = hp.$2;
    }
    final options = <String, dynamic>{'method': method.toLowerCase()};
    final plugin = query['plugin'];
    if (plugin != null && plugin.isNotEmpty) {
      final parts = plugin.split(';');
      final pname = parts.first;
      if (pname != 'obfs-local' &&
          pname != 'simple-obfs' &&
          pname != 'v2ray-plugin') {
        throw NodeParseException(
          '不支持的 Shadowsocks 插件：$pname（sing-box 仅支持 obfs-local、v2ray-plugin）',
        );
      }
      options['plugin'] = pname == 'simple-obfs' ? 'obfs-local' : pname;
      options['plugin_opts'] = parts.skip(1).join(';');
    }
    return ProxyNode(
      id: newId(),
      name: name.isEmpty ? '$host:$port' : name,
      protocol: ProxyProtocol.shadowsocks,
      server: host,
      port: port,
      secret: {'password': password},
      options: options,
    );
  }

  (String, int) _splitHostPort(String hp) {
    final m = RegExp(r'^\[?([^\]]+?)\]?:(\d+)$').firstMatch(hp.trim());
    if (m == null) throw NodeParseException('地址或端口缺失：$hp');
    return (_host(m.group(1)!), _port(m.group(2)));
  }

  ProxyNode _parseVmess(String link) {
    final body = link.substring(8);
    final decoded = tryDecodeBase64(body.split('#').first);
    if (decoded == null) throw NodeParseException('VMess 链接 Base64 解码失败');
    final Map<String, dynamic> j;
    try {
      j = (jsonDecode(decoded) as Map).cast<String, dynamic>();
    } catch (_) {
      throw NodeParseException('VMess 链接内容不是有效 JSON');
    }
    String s(String k) => (j[k] ?? '').toString();
    final uuid = s('id');
    if (!_isUuid(uuid)) throw NodeParseException('VMess UUID 无效');
    final net = s('net').isEmpty ? 'tcp' : s('net');
    final tlsOn = s('tls') == 'tls';
    if (net == 'tcp' && s('type') == 'http') {
      throw NodeParseException('不支持的 VMess 传输：tcp+http 伪装');
    }
    return ProxyNode(
      id: newId(),
      name: s('ps').isEmpty ? '${s('add')}:${s('port')}' : s('ps'),
      protocol: ProxyProtocol.vmess,
      server: _host(s('add')),
      port: _port(s('port')),
      secret: {'uuid': uuid},
      options: {
        'alter_id': int.tryParse(s('aid')) ?? 0,
        'security': s('scy').isEmpty ? 'auto' : s('scy'),
      },
      tls: TlsOptions(
        enabled: tlsOn,
        serverName: s('sni').isNotEmpty
            ? s('sni')
            : (s('host').isNotEmpty ? s('host') : null),
        alpn: s('alpn').isEmpty ? const [] : s('alpn').split(','),
        fingerprint: s('fp').isEmpty ? null : s('fp'),
      ),
      transport: _transport(
        net,
        path: s('path'),
        host: s('host'),
        serviceName: s('path'),
      ),
    );
  }

  TransportOptions _transport(
    String net, {
    String? path,
    String? host,
    String? serviceName,
  }) {
    switch (net) {
      case 'tcp':
      case '':
        return const TransportOptions();
      case 'ws':
        return TransportOptions(
          type: 'ws',
          path: (path == null || path.isEmpty) ? '/' : path,
          host: (host?.isEmpty ?? true) ? null : host,
        );
      case 'grpc':
        return TransportOptions(type: 'grpc', serviceName: serviceName ?? '');
      case 'h2':
      case 'http':
        return TransportOptions(
          type: 'http',
          path: path,
          host: (host?.isEmpty ?? true) ? null : host,
        );
      case 'httpupgrade':
        return TransportOptions(
          type: 'httpupgrade',
          path: path,
          host: (host?.isEmpty ?? true) ? null : host,
        );
      default:
        throw NodeParseException('不支持的传输类型：$net');
    }
  }

  static bool _isUuid(String s) => RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(s);

  ProxyNode _parseVless(String link) {
    final u = _uri(link);
    final uuid = Uri.decodeComponent(u.userInfo);
    if (!_isUuid(uuid)) throw NodeParseException('VLESS UUID 无效');
    final q = u.queryParameters;
    final security = q['security'] ?? 'none';
    if (security != 'none' && security != 'tls' && security != 'reality') {
      throw NodeParseException('不支持的 VLESS security：$security');
    }
    final type = q['type'] ?? 'tcp';
    final reality = security == 'reality';
    if (reality && (q['pbk'] ?? '').isEmpty)
      throw NodeParseException('REALITY 缺少公钥 pbk');
    final flow = q['flow'] ?? '';
    return ProxyNode(
      id: newId(),
      name: _fragmentName(u, '${u.host}:${u.port}'),
      protocol: ProxyProtocol.vless,
      server: _host(u.host),
      port: _port(u.hasPort ? '${u.port}' : null),
      secret: {'uuid': uuid},
      options: {if (flow.isNotEmpty) 'flow': flow},
      tls: TlsOptions(
        enabled: security != 'none',
        serverName: q['sni'] ?? q['peer'],
        insecure: q['allowInsecure'] == '1' || q['insecure'] == '1',
        alpn: (q['alpn'] ?? '').isEmpty ? const [] : q['alpn']!.split(','),
        fingerprint: q['fp'],
        realityPublicKey: reality ? q['pbk'] : null,
        realityShortId: reality ? (q['sid'] ?? '') : null,
      ),
      transport: _transport(
        type,
        path: q['path'],
        host: q['host'],
        serviceName: q['serviceName'],
      ),
    );
  }

  ProxyNode _parseTrojan(String link) {
    final u = _uri(link);
    final password = Uri.decodeComponent(u.userInfo);
    if (password.isEmpty) throw NodeParseException('Trojan 密码为空');
    final q = u.queryParameters;
    return ProxyNode(
      id: newId(),
      name: _fragmentName(u, '${u.host}:${u.port}'),
      protocol: ProxyProtocol.trojan,
      server: _host(u.host),
      port: _port(u.hasPort ? '${u.port}' : '443'),
      secret: {'password': password},
      tls: TlsOptions(
        enabled: q['security'] != 'none',
        serverName: q['sni'] ?? q['peer'],
        insecure: q['allowInsecure'] == '1',
        alpn: (q['alpn'] ?? '').isEmpty ? const [] : q['alpn']!.split(','),
        fingerprint: q['fp'],
      ),
      transport: _transport(
        q['type'] ?? 'tcp',
        path: q['path'],
        host: q['host'],
        serviceName: q['serviceName'],
      ),
    );
  }

  ProxyNode _parseHy2(String link) {
    final u = _uri(link);
    final auth = Uri.decodeComponent(u.userInfo);
    final q = u.queryParameters;
    if ((q['mport'] ?? '').isNotEmpty) {
      throw NodeParseException('不支持：Hysteria2 端口跳跃（mport）本版本未实现');
    }
    final obfs = q['obfs'];
    if (obfs != null && obfs.isNotEmpty && obfs != 'salamander') {
      throw NodeParseException('不支持的 Hysteria2 混淆：$obfs');
    }
    return ProxyNode(
      id: newId(),
      name: _fragmentName(u, '${u.host}:${u.port}'),
      protocol: ProxyProtocol.hysteria2,
      server: _host(u.host),
      port: _port(u.hasPort ? '${u.port}' : '443'),
      secret: {
        'password': auth,
        if (obfs == 'salamander') 'obfs_password': q['obfs-password'] ?? '',
      },
      options: {if (obfs == 'salamander') 'obfs': 'salamander'},
      tls: TlsOptions(
        enabled: true,
        serverName: q['sni'],
        insecure: q['insecure'] == '1',
        alpn: (q['alpn'] ?? '').isEmpty ? const [] : q['alpn']!.split(','),
      ),
    );
  }

  ProxyNode _parseTuic(String link) {
    final u = _uri(link);
    final ui = Uri.decodeComponent(u.userInfo);
    final c = ui.indexOf(':');
    if (c <= 0) throw NodeParseException('TUIC 链接需包含 uuid:password');
    final uuid = ui.substring(0, c);
    if (!_isUuid(uuid)) throw NodeParseException('TUIC UUID 无效');
    final q = u.queryParameters;
    return ProxyNode(
      id: newId(),
      name: _fragmentName(u, '${u.host}:${u.port}'),
      protocol: ProxyProtocol.tuic,
      server: _host(u.host),
      port: _port(u.hasPort ? '${u.port}' : null),
      secret: {'uuid': uuid, 'password': ui.substring(c + 1)},
      options: {
        'congestion_control': q['congestion_control'] ?? 'cubic',
        if (q['udp_relay_mode'] != null) 'udp_relay_mode': q['udp_relay_mode'],
      },
      tls: TlsOptions(
        enabled: true,
        serverName: q['sni'],
        insecure: q['allow_insecure'] == '1' || q['insecure'] == '1',
        alpn: (q['alpn'] ?? 'h3').split(','),
      ),
    );
  }

  ProxyNode _parseSocks(String link) {
    final u = _uri(link);
    var user = '', pass = '';
    if (u.userInfo.isNotEmpty) {
      final raw = u.userInfo;
      final decoded = raw.contains(':')
          ? Uri.decodeComponent(raw)
          : (tryDecodeBase64(raw) ?? raw);
      final c = decoded.indexOf(':');
      user = c >= 0 ? decoded.substring(0, c) : decoded;
      pass = c >= 0 ? decoded.substring(c + 1) : '';
    }
    return ProxyNode(
      id: newId(),
      name: _fragmentName(u, '${u.host}:${u.port}'),
      protocol: ProxyProtocol.socks,
      server: _host(u.host),
      port: _port(u.hasPort ? '${u.port}' : null),
      secret: {
        if (user.isNotEmpty) 'username': user,
        if (pass.isNotEmpty) 'password': pass,
      },
    );
  }

  // ---------------- sing-box JSON ----------------

  ParseReport _parseSingBoxJson(
    String text, {
    required NodeSource source,
    String? subscriptionId,
  }) {
    final Map<String, dynamic> j;
    try {
      j = (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      throw NodeParseException('JSON 格式错误');
    }
    final outbounds = j['outbounds'];
    if (outbounds is! List)
      throw NodeParseException('sing-box 配置中没有 outbounds 数组');
    final nodes = <ProxyNode>[];
    final issues = <ParseIssue>[];
    const skipTypes = {'direct', 'block', 'dns', 'selector', 'urltest'};
    for (var i = 0; i < outbounds.length; i++) {
      final o = outbounds[i];
      if (o is! Map) {
        issues.add(ParseIssue(i + 1, '条目不是对象'));
        continue;
      }
      final m = o.cast<String, dynamic>();
      final type = m['type']?.toString() ?? '';
      if (skipTypes.contains(type)) continue;
      try {
        nodes.add(
          _fromSingBoxOutbound(m)
              .copyWith(source: source, subscriptionId: subscriptionId),
        );
      } on NodeParseException catch (e) {
        issues.add(
          ParseIssue(
            i + 1,
            e.message,
            unsupported: e.message.startsWith('不支持'),
          ),
        );
      }
    }
    return ParseReport(nodes, issues, format: 'sing-box-json');
  }

  ProxyNode _fromSingBoxOutbound(Map<String, dynamic> m) {
    final type = m['type']?.toString() ?? '';
    final protocol = ProxyProtocol.fromName(type);
    if (protocol == null) throw NodeParseException('不支持的出站类型：$type');
    final server = (m['server'] ?? '').toString();
    final port = _port('${m['server_port']}');
    final tlsJ = (m['tls'] as Map?)?.cast<String, dynamic>();
    final reality = (tlsJ?['reality'] as Map?)?.cast<String, dynamic>();
    final utls = (tlsJ?['utls'] as Map?)?.cast<String, dynamic>();
    final tls = TlsOptions(
      enabled: tlsJ?['enabled'] == true,
      serverName: tlsJ?['server_name'] as String?,
      insecure: tlsJ?['insecure'] == true,
      alpn: ((tlsJ?['alpn'] as List?) ?? const []).map((e) => '$e').toList(),
      fingerprint: utls?['fingerprint'] as String?,
      realityPublicKey: reality?['enabled'] == true
          ? reality!['public_key'] as String?
          : null,
      realityShortId: reality?['enabled'] == true
          ? (reality!['short_id'] ?? '') as String
          : null,
    );
    final tr = (m['transport'] as Map?)?.cast<String, dynamic>();
    final transport = tr == null
        ? const TransportOptions()
        : TransportOptions(
            type: tr['type'] as String? ?? 'tcp',
            path: tr['path'] as String?,
            host:
                (tr['headers'] as Map?)?['Host']?.toString() ??
                (tr['host'] is String ? tr['host'] as String : null),
            serviceName: tr['service_name'] as String?,
          );
    final secret = <String, String>{};
    final options = <String, dynamic>{};
    for (final k in ['password', 'uuid', 'username']) {
      if (m[k] != null) secret[k] = '${m[k]}';
    }
    for (final k in [
      'method',
      'flow',
      'alter_id',
      'security',
      'congestion_control',
      'udp_relay_mode',
      'plugin',
      'plugin_opts',
    ]) {
      if (m[k] != null) options[k] = m[k];
    }
    final obfs = (m['obfs'] as Map?)?.cast<String, dynamic>();
    if (obfs != null) {
      options['obfs'] = obfs['type'];
      secret['obfs_password'] = '${obfs['password'] ?? ''}';
    }
    return ProxyNode(
      id: newId(),
      name: (m['tag'] ?? '$server:$port').toString(),
      protocol: protocol,
      server: _host(server),
      port: port,
      secret: secret,
      options: options,
      tls: tls,
      transport: transport,
    );
  }
}

/// 去重：保留首次出现的节点，返回去重后列表与被移除数量。
(List<ProxyNode>, int) dedupNodes(Iterable<ProxyNode> nodes) {
  final seen = <String>{};
  final out = <ProxyNode>[];
  var removed = 0;
  for (final n in nodes) {
    if (seen.add(n.dedupKey)) {
      out.add(n);
    } else {
      removed++;
    }
  }
  return (out, removed);
}
