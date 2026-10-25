// SPDX-License-Identifier: GPL-3.0-or-later
// 节点风险评估：不会被拒绝导入，但会在列表中单独标记，连接前要求用户确认。
//
// high    —— 跳过 TLS 证书校验（insecure/allowInsecure）：可被中间人冒充服务器、窃取凭据。
//            默认不进入运行配置；只有用户对该节点确认“风险连接”（或在设置中允许全部风险连接）后才会写入。
// caution —— 流量明文或不加密（无 TLS 的 VLESS/Trojan/VMess none、SS none、SOCKS/HTTP、无密码 Hysteria2）。
//            可以运行，但连接前同样提示。

import '../models/models.dart';

enum RiskLevel { none, caution, high }

class NodeRisk {
  const NodeRisk(this.level, this.reasons);
  static const safe = NodeRisk(RiskLevel.none, []);
  final RiskLevel level;
  final List<String> reasons;
  bool get risky => level != RiskLevel.none;
  bool get high => level == RiskLevel.high;
}

NodeRisk assessRisk(ProxyNode n) {
  final high = <String>[];
  final caution = <String>[];
  if (n.tls.insecure) high.add('跳过 TLS 证书校验，可能被中间人冒充服务器、窃取账号');
  final m = '${n.options['method'] ?? ''}';
  final s = '${n.options['security'] ?? 'auto'}';
  switch (n.protocol) {
    case ProxyProtocol.shadowsocks:
      if (m == 'none') caution.add('Shadowsocks 不加密，流量为明文');
    case ProxyProtocol.vmess:
      if (!n.tls.enabled && (s == 'none' || s == 'zero')) {
        caution.add('VMess 未启用 TLS 且不加密');
      }
    case ProxyProtocol.vless:
      if (!n.tls.enabled) caution.add('VLESS 未启用 TLS，流量为明文');
    case ProxyProtocol.trojan:
      if (!n.tls.enabled) caution.add('Trojan 未启用 TLS');
    case ProxyProtocol.hysteria2:
      if ((n.secret['password'] ?? '').isEmpty) caution.add('Hysteria2 无认证密码');
    case ProxyProtocol.socks:
    case ProxyProtocol.http:
      caution.add('${n.protocol.label} 代理本身不加密');
    case ProxyProtocol.tuic:
      break;
  }
  if (high.isNotEmpty) return NodeRisk(RiskLevel.high, [...high, ...caution]);
  if (caution.isNotEmpty) return NodeRisk(RiskLevel.caution, caution);
  return NodeRisk.safe;
}
