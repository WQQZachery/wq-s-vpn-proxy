// SPDX-License-Identifier: GPL-3.0-or-later
// 节点校验：任何导入内容在入库或交给核心前都必须通过这里。

import '../models/models.dart';
import 'utls_fingerprint.dart';

class ValidationResult {
  const ValidationResult(this.errors, this.warnings);
  final List<String> errors;
  final List<String> warnings;
  bool get ok => errors.isEmpty;
}

class NodeValidator {
  static const ssMethods = {
    'aes-128-gcm',
    'aes-192-gcm',
    'aes-256-gcm',
    'chacha20-ietf-poly1305',
    'xchacha20-ietf-poly1305',
    '2022-blake3-aes-128-gcm',
    '2022-blake3-aes-256-gcm',
    '2022-blake3-chacha20-poly1305',
    'none',
  };
  static const vmessSecurity = {
    'auto',
    'none',
    'zero',
    'aes-128-gcm',
    'chacha20-poly1305',
    'aes-128-ctr',
  };
  static const vlessFlows = {'', 'xtls-rprx-vision'};
  static const transports = {'tcp', 'ws', 'grpc', 'http', 'httpupgrade'};
  static const tuicCongestion = {'cubic', 'new_reno', 'bbr'};

  static final _hostRe = RegExp(
    r'^(?=.{1,253}$)([A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9])?$',
  );
  static final _ipv4Re = RegExp(
    r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$',
  );

  static bool isValidHost(String h) {
    if (h.isEmpty) return false;
    final m4 = _ipv4Re.firstMatch(h);
    if (m4 != null)
      return List.generate(
        4,
        (i) => int.parse(m4.group(i + 1)!),
      ).every((o) => o <= 255);
    if (h.contains(':'))
      return RegExp(r'^[0-9a-fA-F:.]+$').hasMatch(h) &&
          h.split(':').length >= 3;
    return _hostRe.hasMatch(h);
  }

  static ValidationResult validate(ProxyNode n) {
    final e = <String>[];
    final w = <String>[];
    if (n.name.trim().isEmpty) e.add('名称不能为空');
    if (n.name.length > 128) e.add('名称过长（>128）');
    if (!isValidHost(n.server)) e.add('服务器地址无效：${n.server}');
    if (n.port < 1 || n.port > 65535) e.add('端口超出范围：${n.port}');
    if (n.tls.insecure) {
      // 不再拒绝：作为高风险节点单独标记，连接前须用户确认（见 node_risk.dart）
      w.add('该节点跳过 TLS 证书校验（insecure），属于高风险节点，需确认后才能连接');
    }
    final needsTls =
        n.tls.enabled ||
        n.protocol == ProxyProtocol.hysteria2 ||
        n.protocol == ProxyProtocol.tuic;
    if (needsTls) {
      final fpMsg = resolveUtlsFingerprint(n.tls.fingerprint).message;
      if (fpMsg != null) w.add(fpMsg);
    }
    if (!transports.contains(n.transport.type))
      e.add('不支持的传输：${n.transport.type}');
    String sec(String k) => n.secret[k] ?? '';
    switch (n.protocol) {
      case ProxyProtocol.shadowsocks:
        final m = '${n.options['method'] ?? ''}';
        if (!ssMethods.contains(m)) e.add('不支持的 Shadowsocks 加密方式：$m');
        if (m != 'none' && sec('password').isEmpty) e.add('Shadowsocks 密码为空');
        if (m == 'none') w.add('Shadowsocks 使用 none 加密，流量不加密');
      case ProxyProtocol.vmess:
        if (!_uuid(sec('uuid'))) e.add('VMess UUID 无效');
        final s = '${n.options['security'] ?? 'auto'}';
        if (!vmessSecurity.contains(s)) e.add('不支持的 VMess security：$s');
        if (!n.tls.enabled && (s == 'none' || s == 'zero'))
          w.add('VMess 未启用 TLS 且不加密');
      case ProxyProtocol.vless:
        if (!_uuid(sec('uuid'))) e.add('VLESS UUID 无效');
        final f = '${n.options['flow'] ?? ''}';
        if (!vlessFlows.contains(f)) e.add('不支持的 VLESS flow：$f');
        if (f == 'xtls-rprx-vision' && n.transport.type != 'tcp')
          e.add('xtls-rprx-vision 仅支持 TCP 传输');
        if (!n.tls.enabled) w.add('VLESS 未启用 TLS，流量为明文');
        if (n.tls.isReality &&
            !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(n.tls.realityPublicKey!)) {
          e.add('REALITY 公钥格式无效');
        }
        if (n.tls.isReality &&
            !RegExp(r'^[0-9a-fA-F]{0,16}$')
                .hasMatch(n.tls.realityShortId ?? '')) {
          e.add('REALITY short_id 格式无效');
        }
      case ProxyProtocol.trojan:
        if (sec('password').isEmpty) e.add('Trojan 密码为空');
        if (!n.tls.enabled) w.add('Trojan 未启用 TLS');
      case ProxyProtocol.hysteria2:
        if (sec('password').isEmpty) w.add('Hysteria2 认证密码为空');
        if (n.options['obfs'] == 'salamander' && sec('obfs_password').isEmpty)
          e.add('salamander 混淆密码为空');
      case ProxyProtocol.tuic:
        if (!_uuid(sec('uuid'))) e.add('TUIC UUID 无效');
        final cc = '${n.options['congestion_control'] ?? 'cubic'}';
        if (!tuicCongestion.contains(cc)) e.add('不支持的拥塞控制：$cc');
      case ProxyProtocol.socks:
      case ProxyProtocol.http:
        w.add('${n.protocol.label} 代理本身不加密');
    }
    final grpcOrWs =
        n.transport.type == 'ws' || n.transport.type == 'httpupgrade';
    if (grpcOrWs &&
        (n.transport.path ?? '').isNotEmpty &&
        !n.transport.path!.startsWith('/')) {
      e.add('传输路径必须以 / 开头');
    }
    return ValidationResult(e, w);
  }

  static bool _uuid(String s) => RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(s);
}
