// SPDX-License-Identifier: GPL-3.0-or-later
// 日志脱敏：订阅 URL、密码、UUID、令牌、私钥不得出现在普通日志中。

final _uuidRe = RegExp(
  r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
);
final _linkRe = RegExp(
  r'\b(ss|ssr|vmess|vless|trojan|hysteria2|hy2|tuic|socks5?)://\S+',
  caseSensitive: false,
);
final _urlRe = RegExp(r'https?://[^\s"<>]+', caseSensitive: false);
final _kvRe = RegExp(
  r'("?(?:password|passwd|secret|token|key|auth|uuid|private_key|public_key|pbk|obfs-password|obfs_password)"?\s*[:=]\s*)("[^"]*"|[^\s,&}]+)',
  caseSensitive: false,
);
final _bearerRe = RegExp(
  r'(Bearer\s+)[A-Za-z0-9._~+/=-]+',
  caseSensitive: false,
);

/// 脱敏任意文本。
String redact(String input) {
  var s = input;
  s = s.replaceAllMapped(_linkRe, (m) => '${m.group(1)}://<已隐藏>');
  s = s.replaceAllMapped(_urlRe, (m) => redactUrl(m.group(0)!));
  s = s.replaceAllMapped(_kvRe, (m) => '${m.group(1)}<已隐藏>');
  s = s.replaceAllMapped(_bearerRe, (m) => '${m.group(1)}<已隐藏>');
  s = s.replaceAll(_uuidRe, '<uuid>');
  return s;
}

/// URL 只保留 scheme + 主机，去掉用户信息、路径和查询参数（订阅令牌通常在路径或查询中）。
String redactUrl(String url) {
  try {
    final u = Uri.parse(url);
    if (u.host.isEmpty) return '<url>';
    final hasMore = u.path.length > 1 || u.hasQuery || u.userInfo.isNotEmpty;
    return '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}${hasMore ? '/…' : ''}';
  } catch (_) {
    return '<url>';
  }
}
