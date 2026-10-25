// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state.dart';
import '../../app/theme.dart';
import '../../core/models/models.dart';
import '../../core/security/redact.dart';

/// 必须与 pubspec.yaml 的 version 一致（当前 1.1.1+3）
const appVersion = '1.1.1';
const appBrandName = "WQ's Proxy VPN";

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  Future<String?> _edit(
    BuildContext context,
    String title,
    String initial, {
    String? hint,
    int lines = 1,
    bool obscure = false,
  }) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          maxLines: obscure ? 1 : lines,
          obscureText: obscure,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, c.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  List<String> _domains(String s) => s
      .split(RegExp(r'[\s,]+'))
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final e = st.engine;
    final running = ref.watch(vpnControllerProvider).state == VpnState.started;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const PageHeader('设置'),
        if (running)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              '路由与 DNS 设置在下次连接时生效。',
              style: TextStyle(color: kWarn, fontSize: 12),
            ),
          ),
        const SectionTitle('路由模式'),
        Card(
          child: RadioGroup<RouteMode>(
            groupValue: e.routeMode,
            onChanged: (v) => n.updateEngine(e.copyWith(routeMode: v)),
            child: Column(
              children: [
                for (final m in RouteMode.values)
                  RadioListTile<RouteMode>(
                    value: m,
                    title: Text(m.label),
                    subtitle: Text(
                      m.description,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '说明：本版本未内置 GeoIP/GeoSite 规则集，自动分流仅按上述顺序匹配私有地址与你填写的域名后缀；地区规则、应用分流尚未实现。',
            style: TextStyle(fontSize: 11, color: Colors.white38),
          ),
        ),
        const SectionTitle('分流规则（仅自动分流模式）'),
        Card(
          child: Column(
            children: [
              ListTile(
                title: const Text('直连域名后缀'),
                subtitle: Text(
                  e.directDomains.isEmpty ? '未设置' : e.directDomains.join(', '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  final v = await _edit(
                    context,
                    '直连域名后缀',
                    e.directDomains.join('\n'),
                    hint: '每行一个，如 cn 或 example.com',
                    lines: 6,
                  );
                  if (v != null)
                    await n.updateEngine(
                      e.copyWith(directDomains: _domains(v)),
                    );
                },
              ),
              ListTile(
                title: const Text('代理域名后缀'),
                subtitle: Text(
                  e.proxyDomains.isEmpty ? '未设置' : e.proxyDomains.join(', '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  final v = await _edit(
                    context,
                    '代理域名后缀',
                    e.proxyDomains.join('\n'),
                    hint: '每行一个',
                    lines: 6,
                  );
                  if (v != null)
                    await n.updateEngine(e.copyWith(proxyDomains: _domains(v)));
                },
              ),
            ],
          ),
        ),
        const SectionTitle('DNS 与网络'),
        Card(
          child: Column(
            children: [
              ListTile(
                title: const Text('远程 DNS（经代理）'),
                subtitle: Text(e.remoteDns),
                onTap: () async {
                  final v = await _edit(
                    context,
                    '远程 DNS',
                    e.remoteDns,
                    hint: 'https://1.1.1.1/dns-query 或 tls://8.8.8.8',
                  );
                  if (v != null && v.trim().isNotEmpty)
                    await n.updateEngine(e.copyWith(remoteDns: v.trim()));
                },
              ),
              ListTile(
                title: const Text('直连 DNS'),
                subtitle: Text(e.directDns),
                onTap: () async {
                  final v = await _edit(
                    context,
                    '直连 DNS',
                    e.directDns,
                    hint: '223.5.5.5',
                  );
                  if (v != null && v.trim().isNotEmpty)
                    await n.updateEngine(e.copyWith(directDns: v.trim()));
                },
              ),
              SwitchListTile(
                title: const Text('IPv6'),
                subtitle: const Text('TUN 分配 IPv6 地址并允许 IPv6 解析'),
                value: e.enableIpv6,
                onChanged: (v) => n.updateEngine(e.copyWith(enableIpv6: v)),
              ),
              SwitchListTile(
                title: const Text('严格路由（断线保护）'),
                subtitle: const Text(
                  'VPN 运行期间阻止流量绕过隧道。核心异常退出时系统会关闭 VPN，流量恢复直连；如需完全阻断，请在系统设置中开启“始终开启 VPN + 屏蔽未使用 VPN 的连接”。',
                ),
                value: e.strictRoute,
                onChanged: (v) => n.updateEngine(e.copyWith(strictRoute: v)),
              ),
            ],
          ),
        ),
        const SectionTitle(
          'API 配置',
          info: 'AbuseIPDB API Key 仅用于在“检测中心 → IP 信誉”查询当前出口 IP 的举报记录。\n'
              '获取方式：在 abuseipdb.com 注册免费账号 → Account → API → 创建 Key。\n'
              'Key 保存在系统安全存储（Android Keystore 加密），不写入普通数据库、日志或代码仓库。',
        ),
        Card(
          child: Column(
            children: [
              ListTile(
                title: const Text('AbuseIPDB API Key'),
                subtitle: Text(
                  st.abuseIpDbKey.isEmpty
                      ? '未配置 · 用于查询出口 IP 信誉（可选）'
                      : '已配置 · 保存在安全存储中',
                ),
                onTap: () async {
                  final v = await _edit(
                    context,
                    'AbuseIPDB API Key',
                    '',
                    hint: '留空并保存可清除',
                    obscure: true,
                  );
                  if (v != null) await n.setAbuseKey(v);
                },
              ),
              ListTile(
                title: const Text('Cloudflare 检测目标'),
                subtitle: Text(st.cloudflareTarget),
                onTap: () async {
                  final v = await _edit(
                    context,
                    'Cloudflare 检测目标',
                    st.cloudflareTarget,
                  );
                  if (v != null &&
                      Uri.tryParse(v.trim())?.host.isNotEmpty == true)
                    await n.setTargets(cf: v.trim());
                },
              ),
              ListTile(
                title: const Text('Claude 检测端点'),
                subtitle: Text(st.claudeTarget),
                onTap: () async {
                  final v = await _edit(
                    context,
                    'Claude 检测端点',
                    st.claudeTarget,
                  );
                  if (v != null &&
                      Uri.tryParse(v.trim())?.host.isNotEmpty == true)
                    await n.setTargets(claude: v.trim());
                },
              ),
            ],
          ),
        ),
        const SectionTitle('数据与隐私'),
        Card(
          child: Column(
            children: [
              ListTile(
                title: const Text('检测历史保留'),
                trailing: DropdownButton<int>(
                  value: st.retentionDays,
                  items: const [1, 7, 30, 90]
                      .map(
                        (d) => DropdownMenuItem(value: d, child: Text('$d 天')),
                      )
                      .toList(),
                  onChanged: (v) => n.setRetention(v!),
                ),
              ),
              const ListTile(
                title: Text('隐私说明'),
                subtitle: Text(
                  '节点列表、订阅内容与凭据只保存在本机，不上传。出口 IP、信誉、测速检测会访问对应第三方服务。',
                ),
              ),
              ListTile(
                title: const Text('导出日志（已脱敏）'),
                subtitle: const Text('复制应用日志与核心日志到剪贴板'),
                onTap: () async {
                  final app = ref.read(appLogProvider).join('\n');
                  String core = '';
                  try {
                    core = await ref.read(vpnEngineProvider).exportLogs();
                  } catch (err) {
                    core = '读取核心日志失败：$err';
                  }
                  await Clipboard.setData(
                    ClipboardData(
                      text: redact('=== 应用日志 ===\n$app\n\n=== 核心日志 ===\n$core'),
                    ),
                  );
                  if (context.mounted) showSnack(context, '已复制（敏感信息已脱敏）');
                },
              ),
            ],
          ),
        ),
        const SectionTitle('关于'),
        Card(
          child: Column(
            children: [
              FutureBuilder<String>(
                future: ref
                    .read(vpnEngineProvider)
                    .coreVersion()
                    .catchError((_) => '未知'),
                builder: (c, s) => ListTile(
                  title: const Text('版本'),
                  subtitle: Text(
                    '$appBrandName $appVersion · sing-box ${s.data ?? '…'}',
                  ),
                ),
              ),
              ListTile(
                title: const Text('许可证'),
                subtitle: const Text(
                  '本应用以 GPL-3.0-or-later 发布；内含 sing-box（GPL-3.0-or-later）。第三方声明见 THIRD_PARTY_NOTICES.md',
                ),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: appBrandName,
                  applicationVersion: appVersion,
                  applicationLegalese: 'GPL-3.0-or-later\n包含 sing-box © SagerNet，GPL-3.0-or-later\n源码：https://github.com/SagerNet/sing-box',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
