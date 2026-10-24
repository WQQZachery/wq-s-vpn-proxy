// SPDX-License-Identifier: GPL-3.0-or-later
// 手动录入/编辑自有服务器节点。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state.dart';
import '../../app/theme.dart';
import '../../core/models/models.dart';

class NodeEditorPage extends ConsumerStatefulWidget {
  const NodeEditorPage({super.key, this.initial});
  final ProxyNode? initial;
  @override
  ConsumerState<NodeEditorPage> createState() => _NodeEditorPageState();
}

class _NodeEditorPageState extends ConsumerState<NodeEditorPage> {
  late ProxyProtocol _protocol;
  late final Map<String, TextEditingController> _c;
  bool _tls = false;
  String _transport = 'tcp';
  List<String> _errors = [];
  List<String> _warnings = [];

  @override
  void initState() {
    super.initState();
    final n = widget.initial;
    _protocol = n?.protocol ?? ProxyProtocol.vless;
    _tls = n?.tls.enabled ?? true;
    _transport = n?.transport.type ?? 'tcp';
    String o(String k) => '${n?.options[k] ?? ''}';
    _c = {
      'name': TextEditingController(text: n?.name ?? ''),
      'server': TextEditingController(text: n?.server ?? ''),
      'port': TextEditingController(text: n == null ? '443' : '${n.port}'),
      'password': TextEditingController(text: n?.secret['password'] ?? ''),
      'uuid': TextEditingController(text: n?.secret['uuid'] ?? ''),
      'username': TextEditingController(text: n?.secret['username'] ?? ''),
      'method': TextEditingController(
        text: o('method').isEmpty ? '2022-blake3-aes-128-gcm' : o('method'),
      ),
      'flow': TextEditingController(text: o('flow')),
      'security': TextEditingController(
        text: o('security').isEmpty ? 'auto' : o('security'),
      ),
      'sni': TextEditingController(text: n?.tls.serverName ?? ''),
      'alpn': TextEditingController(text: n?.tls.alpn.join(',') ?? ''),
      'fp': TextEditingController(text: n?.tls.fingerprint ?? ''),
      'pbk': TextEditingController(text: n?.tls.realityPublicKey ?? ''),
      'sid': TextEditingController(text: n?.tls.realityShortId ?? ''),
      'path': TextEditingController(
        text: n?.transport.path ?? n?.transport.serviceName ?? '',
      ),
      'host': TextEditingController(text: n?.transport.host ?? ''),
      'obfs_password': TextEditingController(
        text: n?.secret['obfs_password'] ?? '',
      ),
      'cc': TextEditingController(
        text: o('congestion_control').isEmpty ? 'bbr' : o('congestion_control'),
      ),
    };
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _t(String k) => _c[k]!.text.trim();

  ProxyNode _build() {
    final p = _protocol;
    final secret = <String, String>{};
    final options = <String, dynamic>{};
    switch (p) {
      case ProxyProtocol.shadowsocks:
        secret['password'] = _t('password');
        options['method'] = _t('method');
      case ProxyProtocol.vmess:
        secret['uuid'] = _t('uuid');
        options['security'] = _t('security');
        options['alter_id'] = 0;
      case ProxyProtocol.vless:
        secret['uuid'] = _t('uuid');
        if (_t('flow').isNotEmpty) options['flow'] = _t('flow');
      case ProxyProtocol.trojan:
        secret['password'] = _t('password');
      case ProxyProtocol.hysteria2:
        secret['password'] = _t('password');
        if (_t('obfs_password').isNotEmpty) {
          options['obfs'] = 'salamander';
          secret['obfs_password'] = _t('obfs_password');
        }
      case ProxyProtocol.tuic:
        secret['uuid'] = _t('uuid');
        secret['password'] = _t('password');
        options['congestion_control'] = _t('cc');
      case ProxyProtocol.socks:
      case ProxyProtocol.http:
        if (_t('username').isNotEmpty) secret['username'] = _t('username');
        if (_t('password').isNotEmpty) secret['password'] = _t('password');
    }
    final forcedTls = p == ProxyProtocol.hysteria2 || p == ProxyProtocol.tuic;
    final tlsOn = forcedTls || (_supportsTls(p) && _tls);
    return ProxyNode(
      id: widget.initial?.id ?? newId(),
      name: _t('name').isEmpty ? '${_t('server')}:${_t('port')}' : _t('name'),
      protocol: p,
      server: _t('server'),
      port: int.tryParse(_t('port')) ?? 0,
      secret: secret,
      options: options,
      tls: TlsOptions(
        enabled: tlsOn,
        serverName: _t('sni').isEmpty ? null : _t('sni'),
        alpn: _t('alpn').isEmpty
            ? const []
            : _t('alpn').split(',').map((e) => e.trim()).toList(),
        fingerprint: _t('fp').isEmpty ? null : _t('fp'),
        realityPublicKey: p == ProxyProtocol.vless && _t('pbk').isNotEmpty
            ? _t('pbk')
            : null,
        realityShortId: p == ProxyProtocol.vless && _t('pbk').isNotEmpty
            ? _t('sid')
            : null,
      ),
      transport: _supportsTransport(p)
          ? TransportOptions(
              type: _transport,
              path: _transport == 'grpc' || _t('path').isEmpty
                  ? null
                  : _t('path'),
              serviceName: _transport == 'grpc' ? _t('path') : null,
              host: _t('host').isEmpty ? null : _t('host'),
            )
          : const TransportOptions(),
      enabled: widget.initial?.enabled ?? true,
      source: NodeSource.manual,
      createdAt: widget.initial?.createdAt,
    );
  }

  static bool _supportsTls(ProxyProtocol p) =>
      p == ProxyProtocol.vmess ||
      p == ProxyProtocol.vless ||
      p == ProxyProtocol.trojan ||
      p == ProxyProtocol.http;
  static bool _supportsTransport(ProxyProtocol p) =>
      p == ProxyProtocol.vmess ||
      p == ProxyProtocol.vless ||
      p == ProxyProtocol.trojan;

  Future<void> _save() async {
    final r = await ref.read(nodesProvider.notifier).save(_build());
    setState(() {
      _errors = r.errors;
      _warnings = r.warnings;
    });
    if (r.ok && mounted) {
      showSnack(
        context,
        r.warnings.isEmpty ? '已保存' : '已保存（注意：${r.warnings.join('；')}）',
      );
      Navigator.of(context).pop();
    }
  }

  Widget _f(
    String k,
    String label, {
    bool obscure = false,
    TextInputType? kb,
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextField(
      controller: _c[k],
      obscureText: obscure,
      keyboardType: kb,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final p = _protocol;
    final needsUuid =
        p == ProxyProtocol.vmess ||
        p == ProxyProtocol.vless ||
        p == ProxyProtocol.tuic;
    final needsPassword = p != ProxyProtocol.vmess && p != ProxyProtocol.vless;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? '添加节点' : '编辑节点'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<ProxyProtocol>(
            initialValue: p,
            decoration: const InputDecoration(labelText: '协议'),
            items: [
              for (final x in ProxyProtocol.values)
                DropdownMenuItem(value: x, child: Text(x.label)),
            ],
            onChanged: widget.initial != null
                ? null
                : (v) => setState(() => _protocol = v!),
          ),
          _f('name', '名称'),
          _f('server', '服务器地址', hint: '域名或 IP'),
          _f('port', '端口', kb: TextInputType.number),
          if (p == ProxyProtocol.socks || p == ProxyProtocol.http)
            _f('username', '用户名（可选）'),
          if (needsUuid) _f('uuid', 'UUID'),
          if (needsPassword)
            _f(
              'password',
              p == ProxyProtocol.hysteria2 ? '认证密码' : '密码',
              obscure: true,
            ),
          if (p == ProxyProtocol.shadowsocks)
            _f(
              'method',
              '加密方式',
              hint: '如 2022-blake3-aes-128-gcm / aes-256-gcm / chacha20-ietf-poly1305',
            ),
          if (p == ProxyProtocol.vmess)
            _f(
              'security',
              '加密（security）',
              hint: 'auto / aes-128-gcm / chacha20-poly1305',
            ),
          if (p == ProxyProtocol.vless)
            _f('flow', 'Flow（可选）', hint: 'xtls-rprx-vision'),
          if (p == ProxyProtocol.hysteria2)
            _f('obfs_password', 'Salamander 混淆密码（可选）', obscure: true),
          if (p == ProxyProtocol.tuic)
            _f('cc', '拥塞控制', hint: 'cubic / new_reno / bbr'),
          if (_supportsTls(p))
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用 TLS'),
              value: _tls,
              onChanged: (v) => setState(() => _tls = v),
            ),
          if (_tls ||
              p == ProxyProtocol.hysteria2 ||
              p == ProxyProtocol.tuic) ...[
            _f('sni', 'SNI（留空则使用服务器地址）'),
            _f('alpn', 'ALPN（逗号分隔，可选）'),
            if (p != ProxyProtocol.hysteria2 && p != ProxyProtocol.tuic)
              _f('fp', 'uTLS 指纹（可选）', hint: 'chrome / firefox / safari'),
            if (p == ProxyProtocol.vless) ...[
              _f('pbk', 'REALITY 公钥（可选）'),
              _f('sid', 'REALITY short_id'),
            ],
          ],
          if (_supportsTransport(p)) ...[
            DropdownButtonFormField<String>(
              initialValue: _transport,
              decoration: const InputDecoration(labelText: '传输'),
              items: const [
                DropdownMenuItem(value: 'tcp', child: Text('TCP')),
                DropdownMenuItem(value: 'ws', child: Text('WebSocket')),
                DropdownMenuItem(value: 'grpc', child: Text('gRPC')),
                DropdownMenuItem(value: 'http', child: Text('HTTP/2')),
                DropdownMenuItem(
                  value: 'httpupgrade',
                  child: Text('HTTPUpgrade'),
                ),
              ],
              onChanged: (v) => setState(() => _transport = v!),
            ),
            if (_transport != 'tcp') ...[
              _f('path', _transport == 'grpc' ? 'gRPC 服务名' : '路径'),
              if (_transport != 'grpc') _f('host', 'Host（可选）'),
            ],
          ],
          const SizedBox(height: 12),
          for (final e in _errors)
            Text('✗ $e', style: const TextStyle(color: kBad)),
          for (final w in _warnings)
            Text('! $w', style: const TextStyle(color: kWarn)),
          const SizedBox(height: 8),
          const Text(
            '凭据保存在 Android Keystore 保护的安全存储中，不写入数据库明文。跳过证书校验的节点不被允许。',
            style: TextStyle(fontSize: 12, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}
