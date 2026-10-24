// WQ's Proxy VPN — 节点模型
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

/// 本版本实际实现解析与配置生成的协议（均为 sing-box 1.14 支持的出站类型）。
/// 未列出的协议（如 naive、tailscale、openvpn）在导入时会被明确拒绝。
enum ProxyProtocol {
  shadowsocks('shadowsocks', 'Shadowsocks'),
  vmess('vmess', 'VMess'),
  vless('vless', 'VLESS'),
  trojan('trojan', 'Trojan'),
  hysteria2('hysteria2', 'Hysteria2'),
  tuic('tuic', 'TUIC'),
  socks('socks', 'SOCKS5'),
  http('http', 'HTTP');

  const ProxyProtocol(this.singBoxType, this.label);
  final String singBoxType;
  final String label;

  static ProxyProtocol? fromName(String name) {
    for (final p in values) {
      if (p.name == name || p.singBoxType == name) return p;
    }
    return null;
  }
}

/// 节点来源：自有服务器手动录入 / 分享链接 / 订阅。
enum NodeSource { manual, shareLink, subscription, configFile }

/// 传输层（v2ray transport）。
class TransportOptions {
  const TransportOptions({
    this.type = 'tcp',
    this.path,
    this.host,
    this.serviceName,
  });

  /// tcp | ws | grpc | http | httpupgrade
  final String type;
  final String? path;
  final String? host;
  final String? serviceName;

  Map<String, dynamic> toJson() => {
    'type': type,
    if (path != null) 'path': path,
    if (host != null) 'host': host,
    if (serviceName != null) 'serviceName': serviceName,
  };

  factory TransportOptions.fromJson(Map<String, dynamic> j) => TransportOptions(
    type: (j['type'] as String?) ?? 'tcp',
    path: j['path'] as String?,
    host: j['host'] as String?,
    serviceName: j['serviceName'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is TransportOptions &&
      other.type == type &&
      other.path == path &&
      other.host == host &&
      other.serviceName == serviceName;

  @override
  int get hashCode => Object.hash(type, path, host, serviceName);
}

class TlsOptions {
  const TlsOptions({
    this.enabled = false,
    this.serverName,
    this.insecure = false,
    this.alpn = const [],
    this.fingerprint,
    this.realityPublicKey,
    this.realityShortId,
  });

  final bool enabled;
  final String? serverName;

  /// 仅记录来源链接中的 insecure 标志；配置校验会拒绝 insecure=true（任务书禁止绕过证书校验）。
  final bool insecure;
  final List<String> alpn;
  final String? fingerprint;
  final String? realityPublicKey;
  final String? realityShortId;

  bool get isReality =>
      realityPublicKey != null && realityPublicKey!.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    if (serverName != null) 'serverName': serverName,
    'insecure': insecure,
    if (alpn.isNotEmpty) 'alpn': alpn,
    if (fingerprint != null) 'fingerprint': fingerprint,
    if (realityPublicKey != null) 'realityPublicKey': realityPublicKey,
    if (realityShortId != null) 'realityShortId': realityShortId,
  };

  factory TlsOptions.fromJson(Map<String, dynamic> j) => TlsOptions(
    enabled: j['enabled'] == true,
    serverName: j['serverName'] as String?,
    insecure: j['insecure'] == true,
    alpn: ((j['alpn'] as List?) ?? const []).cast<String>(),
    fingerprint: j['fingerprint'] as String?,
    realityPublicKey: j['realityPublicKey'] as String?,
    realityShortId: j['realityShortId'] as String?,
  );
}

/// 节点。敏感字段（password / uuid / 私钥等）放在 [secret]，
/// 持久化时写入 Android Keystore 保护的安全存储，SQLite 只保存非敏感字段。
class ProxyNode {
  ProxyNode({
    required this.id,
    required this.name,
    required this.protocol,
    required this.server,
    required this.port,
    this.secret = const {},
    this.options = const {},
    this.tls = const TlsOptions(),
    this.transport = const TransportOptions(),
    this.enabled = true,
    this.source = NodeSource.manual,
    this.subscriptionId,
    this.createdAt,
  });

  final String id;
  final String name;
  final ProxyProtocol protocol;
  final String server;
  final int port;

  /// 敏感凭据：password、uuid、username 等。
  final Map<String, String> secret;

  /// 非敏感协议参数：method、flow、alterId、security、obfs 类型、congestion_control 等。
  final Map<String, dynamic> options;
  final TlsOptions tls;
  final TransportOptions transport;
  final bool enabled;
  final NodeSource source;
  final String? subscriptionId;
  final DateTime? createdAt;

  /// 去重键：协议 + 地址 + 端口 + 凭据 + 关键参数。名称不参与（同一节点在不同订阅中常改名）。
  String get dedupKey {
    final s = (secret.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) => '${e.key}=${e.value}')
        .join('&');
    final o = (options.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) => '${e.key}=${e.value}')
        .join('&');
    return '${protocol.name}|${server.toLowerCase()}|$port|$s|$o|'
        '${transport.type}|${transport.path ?? ''}|${tls.enabled}|${tls.serverName ?? ''}';
  }

  ProxyNode copyWith({
    String? id,
    String? name,
    String? server,
    int? port,
    Map<String, String>? secret,
    Map<String, dynamic>? options,
    TlsOptions? tls,
    TransportOptions? transport,
    bool? enabled,
    NodeSource? source,
    String? subscriptionId,
  }) => ProxyNode(
    id: id ?? this.id,
    name: name ?? this.name,
    protocol: protocol,
    server: server ?? this.server,
    port: port ?? this.port,
    secret: secret ?? this.secret,
    options: options ?? this.options,
    tls: tls ?? this.tls,
    transport: transport ?? this.transport,
    enabled: enabled ?? this.enabled,
    source: source ?? this.source,
    subscriptionId: subscriptionId ?? this.subscriptionId,
    createdAt: createdAt,
  );

  /// 非敏感部分，写入 SQLite。
  Map<String, Object?> toDbRow() => {
    'id': id,
    'name': name,
    'protocol': protocol.name,
    'server': server,
    'port': port,
    'options': jsonEncode(options),
    'tls': jsonEncode(tls.toJson()),
    'transport': jsonEncode(transport.toJson()),
    'enabled': enabled ? 1 : 0,
    'source': source.name,
    'subscription_id': subscriptionId,
    'created_at': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
  };

  static ProxyNode fromDbRow(
    Map<String, Object?> r,
    Map<String, String> secret,
  ) => ProxyNode(
    id: r['id'] as String,
    name: r['name'] as String,
    protocol:
        ProxyProtocol.fromName(r['protocol'] as String) ?? ProxyProtocol.socks,
    server: r['server'] as String,
    port: r['port'] as int,
    secret: secret,
    options: (jsonDecode(r['options'] as String) as Map)
        .cast<String, dynamic>(),
    tls: TlsOptions.fromJson(
      (jsonDecode(r['tls'] as String) as Map).cast<String, dynamic>(),
    ),
    transport: TransportOptions.fromJson(
      (jsonDecode(r['transport'] as String) as Map).cast<String, dynamic>(),
    ),
    enabled: (r['enabled'] as int) == 1,
    source: NodeSource.values.byName(r['source'] as String),
    subscriptionId: r['subscription_id'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
  );
}
