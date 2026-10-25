// SPDX-License-Identifier: GPL-3.0-or-later
// 根据节点与设置生成 sing-box 1.14 配置（JSON）。生成结果在 Kotlin 层启动前还会经 Libbox.checkConfig 校验。

import 'dart:convert';

import '../models/models.dart';
import 'node_validator.dart';
import 'utls_fingerprint.dart';

class EngineSettings {
  const EngineSettings({
    this.routeMode = RouteMode.rule,
    this.remoteDns = 'https://1.1.1.1/dns-query',
    this.directDns = '223.5.5.5',
    this.enableIpv6 = true,
    this.strictRoute = true,
    this.directDomains = const [],
    this.proxyDomains = const [],
    this.mtu = 9000,
    this.clashApiPort = 9090,
    this.logLevel = 'warn',
  });

  final RouteMode routeMode;

  /// 远程 DNS（经代理）。支持 https://host/path、tls://host、udp://host 或纯 IP（视作 UDP）。
  final String remoteDns;

  /// 直连 DNS（用于解析节点服务器地址与直连域名）。
  final String directDns;
  final bool enableIpv6;

  /// strict_route：VPN 运行期间阻止流量绕过隧道（断线保护的一部分）。
  final bool strictRoute;
  final List<String> directDomains;
  final List<String> proxyDomains;
  final int mtu;
  final int clashApiPort;
  final String logLevel;

  Map<String, dynamic> toJson() => {
    'routeMode': routeMode.name,
    'remoteDns': remoteDns,
    'directDns': directDns,
    'enableIpv6': enableIpv6,
    'strictRoute': strictRoute,
    'directDomains': directDomains,
    'proxyDomains': proxyDomains,
    'mtu': mtu,
    'clashApiPort': clashApiPort,
    'logLevel': logLevel,
  };

  factory EngineSettings.fromJson(Map<String, dynamic> j) => EngineSettings(
    routeMode: RouteMode.values.asNameMap()[j['routeMode']] ?? RouteMode.rule,
    remoteDns: j['remoteDns'] as String? ?? 'https://1.1.1.1/dns-query',
    directDns: j['directDns'] as String? ?? '223.5.5.5',
    enableIpv6: j['enableIpv6'] as bool? ?? true,
    strictRoute: j['strictRoute'] as bool? ?? true,
    directDomains: ((j['directDomains'] as List?) ?? const []).cast<String>(),
    proxyDomains: ((j['proxyDomains'] as List?) ?? const []).cast<String>(),
    mtu: j['mtu'] as int? ?? 9000,
    clashApiPort: j['clashApiPort'] as int? ?? 9090,
    logLevel: j['logLevel'] as String? ?? 'warn',
  );

  EngineSettings copyWith({
    RouteMode? routeMode,
    String? remoteDns,
    String? directDns,
    bool? enableIpv6,
    bool? strictRoute,
    List<String>? directDomains,
    List<String>? proxyDomains,
  }) => EngineSettings(
    routeMode: routeMode ?? this.routeMode,
    remoteDns: remoteDns ?? this.remoteDns,
    directDns: directDns ?? this.directDns,
    enableIpv6: enableIpv6 ?? this.enableIpv6,
    strictRoute: strictRoute ?? this.strictRoute,
    directDomains: directDomains ?? this.directDomains,
    proxyDomains: proxyDomains ?? this.proxyDomains,
    mtu: mtu,
    clashApiPort: clashApiPort,
    logLevel: logLevel,
  );
}

class ConfigBuildException implements Exception {
  ConfigBuildException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BuiltConfig {
  BuiltConfig(
    this.json,
    this.nodeTags,
    this.selectedTag,
    this.warnings, [
    this.outboundLabels = const [],
  ]);
  final String json;

  /// outbounds 数组下标 → 可读名称（节点名或内置出站），用于把内核报错
  /// “initialize outbound[N]: …” 定位到具体节点，而不是假设是所选节点。
  final List<String> outboundLabels;

  String annotateError(String err) =>
      err.replaceAllMapped(RegExp(r'outbound\[(\d+)\]'), (m) {
        final i = int.parse(m.group(1)!);
        return i < outboundLabels.length
            ? '${m.group(0)}（${outboundLabels[i]}）'
            : m.group(0)!;
      });

  /// 节点 id → 出站 tag
  final Map<String, String> nodeTags;
  final String selectedTag;
  final List<String> warnings;
}

class ConfigBuilder {
  static const proxyTag = 'proxy';
  static const directTag = 'direct';

  /// [nodes] 为所有已启用节点（用于在运行时通过 Clash API 对每个节点做真实代理延迟测试），
  /// [selected] 为当前选中的节点。[clashSecret] 由调用方随机生成，不写入日志。
  static BuiltConfig build({
    required List<ProxyNode> nodes,
    required ProxyNode selected,
    required EngineSettings settings,
    required String clashSecret,
  }) {
    final warnings = <String>[];
    final valid = <ProxyNode>[];
    for (final n in nodes.where((n) => n.enabled)) {
      final r = NodeValidator.validate(n);
      if (r.ok) valid.add(n);
    }
    final sr = NodeValidator.validate(selected);
    if (!sr.ok) throw ConfigBuildException('所选节点未通过校验：${sr.errors.join('；')}');
    if (!valid.any((n) => n.id == selected.id)) valid.insert(0, selected);
    warnings.addAll(sr.warnings);
    for (final n in valid) {
      final msg = resolveUtlsFingerprint(n.tls.fingerprint).message;
      if (msg != null && n.id != selected.id) warnings.add('节点「${n.name}」：$msg');
    }

    final tags = <String, String>{};
    final used = <String>{proxyTag, directTag, 'dns-out'};
    for (final n in valid) {
      var base = 'node-${n.id.substring(0, n.id.length.clamp(0, 8))}';
      var t = base;
      var k = 2;
      while (!used.add(t)) {
        t = '$base-${k++}';
      }
      tags[n.id] = t;
    }

    final outbounds = <Map<String, dynamic>>[
      {
        'type': 'selector',
        'tag': proxyTag,
        'outbounds': valid.map((n) => tags[n.id]!).toList(),
        'default': tags[selected.id],
        'interrupt_exist_connections': true,
      },
      for (final n in valid) nodeOutbound(n, tags[n.id]!),
      {'type': 'direct', 'tag': directTag},
    ];

    final inet6 = settings.enableIpv6;
    final config = <String, dynamic>{
      'log': {'level': settings.logLevel, 'timestamp': true},
      'dns': _dns(settings),
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': ['172.19.0.1/30', if (inet6) 'fdfe:dcba:9876::1/126'],
          'mtu': settings.mtu,
          'auto_route': true,
          'strict_route': settings.strictRoute,
          'stack': 'mixed',
        },
      ],
      'outbounds': outbounds,
      'route': _route(settings),
      'experimental': {
        'clash_api': {
          'external_controller': '127.0.0.1:${settings.clashApiPort}',
          'secret': clashSecret,
        },
      },
    };
    return BuiltConfig(
      const JsonEncoder.withIndent('  ').convert(config),
      tags,
      tags[selected.id]!,
      warnings,
      [
        '节点选择器',
        for (final n in valid) '节点「${n.name}」',
        '直连',
      ],
    );
  }

  static Map<String, dynamic> _dnsServer(
    String tag,
    String spec, {
    String? detour,
  }) {
    final s = spec.trim();
    Map<String, dynamic> m;
    if (s.startsWith('https://')) {
      final u = Uri.parse(s);
      m = {
        'type': 'https',
        'server': u.host,
        if (u.hasPort) 'server_port': u.port,
        if (u.path.isNotEmpty && u.path != '/dns-query') 'path': u.path,
      };
    } else if (s.startsWith('tls://')) {
      m = {'type': 'tls', 'server': s.substring(6)};
    } else if (s.startsWith('udp://')) {
      m = {'type': 'udp', 'server': s.substring(6)};
    } else if (s.startsWith('tcp://')) {
      m = {'type': 'tcp', 'server': s.substring(6)};
    } else if (s == 'local') {
      m = {'type': 'local'};
    } else {
      if (!NodeValidator.isValidHost(s))
        throw ConfigBuildException('DNS 服务器地址无效：$s');
      m = {'type': 'udp', 'server': s};
    }
    final host = m['server'] as String?;
    if (host != null && !NodeValidator.isValidHost(host))
      throw ConfigBuildException('DNS 服务器地址无效：$host');
    return {'tag': tag, ...m, if (detour != null) 'detour': detour};
  }

  static Map<String, dynamic> _dns(EngineSettings s) {
    final servers = <Map<String, dynamic>>[
      _dnsServer('dns-direct', s.directDns),
    ];
    final rules = <Map<String, dynamic>>[];
    String finalServer;
    if (s.routeMode == RouteMode.direct) {
      finalServer = 'dns-direct';
    } else {
      // 远程 DNS 的服务器若为域名，需先由直连 DNS 解析
      final remote = _dnsServer('dns-remote', s.remoteDns, detour: proxyTag);
      if (remote['server'] is String && !_isIp(remote['server'] as String)) {
        remote['domain_resolver'] = 'dns-direct';
      }
      servers.add(remote);
      finalServer = 'dns-remote';
      if (s.routeMode == RouteMode.rule && s.directDomains.isNotEmpty) {
        rules.add({
          'domain_suffix': s.directDomains,
          'action': 'route',
          'server': 'dns-direct',
        });
      }
    }
    return {
      'servers': servers,
      'rules': rules,
      'final': finalServer,
      'strategy': s.enableIpv6 ? 'prefer_ipv4' : 'ipv4_only',
    };
  }

  static bool _isIp(String h) =>
      RegExp(r'^[\d.]+$').hasMatch(h) || h.contains(':');

  /// 路由规则（按顺序匹配，首个命中即生效）：
  /// 1. sniff（识别域名，供后续域名规则使用）
  /// 2. DNS 流量 → hijack-dns（交给内置 DNS 模块）
  /// 3. 私有/局域网地址 → direct
  /// 4.（仅自动分流）用户直连域名 → direct
  /// 5.（仅自动分流）用户代理域名 → proxy
  /// final：全局/自动分流 → proxy；直连模式 → direct
  static Map<String, dynamic> _route(EngineSettings s) {
    final rules = <Map<String, dynamic>>[
      {'action': 'sniff'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
      {'ip_is_private': true, 'outbound': directTag},
    ];
    if (s.routeMode == RouteMode.rule) {
      if (s.directDomains.isNotEmpty)
        rules.add({'domain_suffix': s.directDomains, 'outbound': directTag});
      if (s.proxyDomains.isNotEmpty)
        rules.add({'domain_suffix': s.proxyDomains, 'outbound': proxyTag});
    }
    return {
      'rules': rules,
      'final': s.routeMode == RouteMode.direct ? directTag : proxyTag,
      'auto_detect_interface': true,
      'default_domain_resolver': 'dns-direct',
    };
  }

  /// 单个节点 → sing-box 出站。
  static Map<String, dynamic> nodeOutbound(ProxyNode n, String tag) {
    final o = <String, dynamic>{
      'type': n.protocol.singBoxType,
      'tag': tag,
      'server': n.server,
      'server_port': n.port,
    };
    String? sec(String k) => n.secret[k];
    switch (n.protocol) {
      case ProxyProtocol.shadowsocks:
        o['method'] = n.options['method'];
        o['password'] = sec('password') ?? '';
        if (n.options['plugin'] != null) {
          o['plugin'] = n.options['plugin'];
          o['plugin_opts'] = n.options['plugin_opts'] ?? '';
        }
      case ProxyProtocol.vmess:
        o['uuid'] = sec('uuid');
        o['security'] = n.options['security'] ?? 'auto';
        o['alter_id'] = n.options['alter_id'] ?? 0;
      case ProxyProtocol.vless:
        o['uuid'] = sec('uuid');
        final flow = '${n.options['flow'] ?? ''}';
        if (flow.isNotEmpty) o['flow'] = flow;
      case ProxyProtocol.trojan:
        o['password'] = sec('password');
      case ProxyProtocol.hysteria2:
        if ((sec('password') ?? '').isNotEmpty) o['password'] = sec('password');
        if (n.options['obfs'] == 'salamander') {
          o['obfs'] = {
            'type': 'salamander',
            'password': sec('obfs_password') ?? '',
          };
        }
      case ProxyProtocol.tuic:
        o['uuid'] = sec('uuid');
        o['password'] = sec('password') ?? '';
        o['congestion_control'] = n.options['congestion_control'] ?? 'cubic';
        if (n.options['udp_relay_mode'] != null)
          o['udp_relay_mode'] = n.options['udp_relay_mode'];
      case ProxyProtocol.socks:
        o['version'] = '5';
        if (sec('username') != null) o['username'] = sec('username');
        if (sec('password') != null) o['password'] = sec('password');
      case ProxyProtocol.http:
        if (sec('username') != null) o['username'] = sec('username');
        if (sec('password') != null) o['password'] = sec('password');
    }
    final needsTls =
        n.tls.enabled ||
        n.protocol == ProxyProtocol.hysteria2 ||
        n.protocol == ProxyProtocol.tuic;
    if (needsTls) {
      final fp = resolveUtlsFingerprint(n.tls.fingerprint);
      o['tls'] = {
        'enabled': true,
        'server_name': (n.tls.serverName?.isNotEmpty ?? false)
            ? n.tls.serverName
            : n.server,
        if (n.tls.alpn.isNotEmpty) 'alpn': n.tls.alpn,
        // 指纹在这里做最后一道规范化：无论来自分享链接、订阅、JSON、手动编辑
        // 还是历史数据库，非法值都不会进入最终配置。
        if (fp.value != null)
          'utls': {'enabled': true, 'fingerprint': fp.value}
        else if (n.tls.isReality)
          // REALITY 依赖 uTLS；未设置/不支持时使用 sing-box 的默认指纹 chrome。
          'utls': {'enabled': true, 'fingerprint': 'chrome'},
        if (n.tls.isReality)
          'reality': {
            'enabled': true,
            'public_key': n.tls.realityPublicKey,
            'short_id': n.tls.realityShortId ?? '',
          },
      };
    }
    final t = n.transport;
    if (t.type != 'tcp') {
      o['transport'] = switch (t.type) {
        'ws' => {
          'type': 'ws',
          'path': t.path ?? '/',
          if (t.host != null) 'headers': {'Host': t.host},
        },
        'grpc' => {'type': 'grpc', 'service_name': t.serviceName ?? ''},
        'http' => {
          'type': 'http',
          if (t.path != null) 'path': t.path,
          if (t.host != null) 'host': [t.host],
        },
        'httpupgrade' => {
          'type': 'httpupgrade',
          if (t.path != null) 'path': t.path,
          if (t.host != null) 'host': t.host,
        },
        _ => throw ConfigBuildException('不支持的传输：${t.type}'),
      };
    }
    return o;
  }
}

/// 规则命中解释器：按与 [ConfigBuilder] 生成的路由规则完全相同的顺序，判断某个目标会走哪个出站。
/// 用于界面展示“当前路由状态”与单元测试；实际转发由 sing-box 核心决定。
class RouteExplainer {
  static (String outbound, String rule) explain(String host, EngineSettings s) {
    final h = host.toLowerCase();
    if (_isPrivate(h)) return (ConfigBuilder.directTag, '规则 3：私有/局域网地址');
    if (s.routeMode == RouteMode.rule) {
      for (final d in s.directDomains) {
        if (h == d || h.endsWith('.$d'))
          return (ConfigBuilder.directTag, '规则 4：直连域名后缀 $d');
      }
      for (final d in s.proxyDomains) {
        if (h == d || h.endsWith('.$d'))
          return (ConfigBuilder.proxyTag, '规则 5：代理域名后缀 $d');
      }
    }
    return s.routeMode == RouteMode.direct
        ? (ConfigBuilder.directTag, '默认出站（直连模式）')
        : (ConfigBuilder.proxyTag, '默认出站（${s.routeMode.label}）');
  }

  static bool _isPrivate(String h) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(h);
    if (m != null) {
      final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
      return a == 10 ||
          a == 127 ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          (a == 169 && b == 254) ||
          (a == 100 && b >= 64 && b <= 127);
    }
    if (h.contains(':')) {
      return h == '::1' ||
          h.startsWith('fc') ||
          h.startsWith('fd') ||
          h.startsWith('fe80');
    }
    return false;
  }
}
