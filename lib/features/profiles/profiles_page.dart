// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state.dart';
import '../../app/theme.dart';
import '../../core/models/models.dart';
import 'node_editor.dart';

enum NodeFilter { all, enabled, healthy, failed, untested }

class ProfilesPage extends ConsumerStatefulWidget {
  const ProfilesPage({super.key});
  @override
  ConsumerState<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends ConsumerState<ProfilesPage> {
  String _q = '';
  NodeFilter _filter = NodeFilter.all;

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(nodesProvider);
    final n = ref.read(nodesProvider.notifier);
    var list = st.nodes
        .where(
          (x) =>
              _q.isEmpty ||
              x.name.toLowerCase().contains(_q.toLowerCase()) ||
              x.server.toLowerCase().contains(_q.toLowerCase()),
        )
        .toList();
    list = list.where((x) {
      final h = st.health[x.id];
      return switch (_filter) {
        NodeFilter.all => true,
        NodeFilter.enabled => x.enabled,
        NodeFilter.healthy =>
          h != null && h.lastError == null && h.lastTestAt != null,
        NodeFilter.failed => h?.lastFailed ?? false,
        NodeFilter.untested => h == null || h.untested,
      };
    }).toList();
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addMenu(context),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '搜索名称或地址',
                    ),
                    onChanged: (v) => setState(() => _q = v),
                  ),
                ),
                IconButton(
                  tooltip: '订阅管理',
                  icon: const Icon(Icons.rss_feed),
                  onPressed: () => _subs(context),
                ),
                IconButton(
                  tooltip: '批量测试（并发 4）',
                  icon: const Icon(Icons.network_check),
                  onPressed: list.isEmpty
                      ? null
                      : () =>
                            n.testNodes(list.where((x) => x.enabled).toList()),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final f in NodeFilter.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(
                        const {
                          NodeFilter.all: '全部',
                          NodeFilter.enabled: '已启用',
                          NodeFilter.healthy: '可用',
                          NodeFilter.failed: '失败',
                          NodeFilter.untested: '未测试',
                        }[f]!,
                      ),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  ),
              ],
            ),
          ),
          if (ref.watch(vpnControllerProvider).state != VpnState.started)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Text(
                'VPN 未开启：延迟测试仅检测 TCP 端口连通，不代表代理协议可用；开启后将经核心实际代理测试。',
                style: TextStyle(fontSize: 12, color: Colors.white38),
              ),
            ),
          Expanded(
            child: st.loading
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                ? const Center(
                    child: Text(
                      '暂无节点。点击右下角 + 手动添加或导入。',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: list.length,
                    itemBuilder: (c, i) => _tile(c, list[i], st),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, ProxyNode node, NodesState st) {
    final h = st.health[node.id];
    final testing = st.testing.contains(node.id);
    final selected = st.selectedId == node.id;
    String health;
    Color color;
    if (testing) {
      health = '测试中…';
      color = kWarn;
    } else if (h == null || h.untested) {
      health = '未测试';
      color = Colors.white38;
    } else if (h.lastError != null) {
      health = '失败';
      color = kBad;
    } else {
      health = '${h.lastLatencyMs} ms${h.method == 'tcp' ? '（TCP）' : ''}';
      color = (h.lastLatencyMs ?? 9999) < 300 ? kGood : kWarn;
    }
    final sub = node.subscriptionId == null || node.subscriptionId!.isEmpty
        ? null
        : st.subscriptions
              .where((s) => s.id == node.subscriptionId)
              .firstOrNull
              ?.name;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected
            ? const BorderSide(color: kAccent, width: 1.5)
            : BorderSide.none,
      ),
      child: ListTile(
        enabled: node.enabled,
        onTap: node.enabled
            ? () => ref.read(nodesProvider.notifier).select(node.id)
            : null,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
          color: selected ? kAccent : null,
        ),
        title: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${node.protocol.label} · ${node.transport.type}${node.tls.enabled ? ' · TLS' : ''}${sub != null ? ' · $sub' : ''}${!node.enabled ? ' · 已禁用' : ''}'
          '${h?.lastSuccessAt != null ? '\n最近成功：${_ago(h!.lastSuccessAt!)}  失败率 ${(h.failureRate * 100).toStringAsFixed(0)}%' : ''}'
          '${h?.lastError != null ? '\n${h!.lastError}' : ''}',
        ),
        isThreeLine: h?.lastSuccessAt != null || h?.lastError != null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(health, style: TextStyle(color: color, fontSize: 12)),
            PopupMenuButton<String>(
              onSelected: (v) => _action(context, v, node),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'test', child: Text('测试')),
                if (node.source == NodeSource.manual ||
                    node.subscriptionId == null)
                  const PopupMenuItem(value: 'edit', child: Text('编辑')),
                const PopupMenuItem(value: 'dup', child: Text('复制为手动节点')),
                PopupMenuItem(
                  value: 'toggle',
                  child: Text(node.enabled ? '禁用' : '启用'),
                ),
                const PopupMenuItem(value: 'del', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  Future<void> _action(BuildContext context, String v, ProxyNode node) async {
    final n = ref.read(nodesProvider.notifier);
    switch (v) {
      case 'test':
        await n.testNodes([node]);
      case 'edit':
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => NodeEditorPage(initial: node)),
        );
      case 'dup':
        await n.duplicate(node);
      case 'toggle':
        await n.toggle(node);
      case 'del':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('删除节点'),
            content: Text('确定删除「${node.name}」？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (ok == true) await n.delete(node.id);
    }
  }

  void _addMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('手动添加自有服务器'),
              onTap: () {
                Navigator.pop(c);
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const NodeEditorPage()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('导入分享链接 / sing-box JSON'),
              subtitle: const Text('支持多行粘贴'),
              onTap: () {
                Navigator.pop(c);
                _importDialog(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.rss_feed),
              title: const Text('添加订阅'),
              onTap: () {
                Navigator.pop(c);
                _addSubDialog(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importDialog(BuildContext context) async {
    final ctl = TextEditingController();
    final clip = await Clipboard.getData('text/plain');
    if (clip?.text?.contains('://') ?? false) ctl.text = clip!.text!;
    if (!context.mounted) return;
    final text = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('导入节点'),
        content: TextField(
          controller: ctl,
          maxLines: 8,
          minLines: 4,
          decoration: const InputDecoration(
            hintText: 'vless://… / ss://… / trojan://… 或 sing-box 配置 JSON',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctl.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty || !context.mounted) return;
    final r = await ref.read(nodesProvider.notifier).importText(text);
    if (context.mounted) _showOutcome(context, r);
  }

  void _showOutcome(BuildContext context, ImportOutcome r) {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          '新增 ${r.added} · 重复 ${r.duplicates} · 失败 ${r.issues.length}',
        ),
        content: r.issues.isEmpty
            ? const Text('全部导入成功')
            : SizedBox(
                width: double.maxFinite,
                height: 240,
                child: ListView(
                  children: [
                    for (final i in r.issues)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(i, style: const TextStyle(fontSize: 13)),
                      ),
                  ],
                ),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _addSubDialog(BuildContext context) async {
    final name = TextEditingController();
    final url = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('添加订阅'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '名称（可选）'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: url,
              decoration: const InputDecoration(labelText: '订阅 URL'),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 8),
            const Text(
              '订阅地址仅保存在本机安全存储中，日志只显示域名。',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('添加并更新'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final s = await ref
          .read(nodesProvider.notifier)
          .addSubscription(name.text, url.text);
      final r = await ref.read(nodesProvider.notifier).updateSubscription(s);
      if (context.mounted) _showOutcome(context, r);
    } on FormatException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    }
  }

  void _subs(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => Consumer(
        builder: (c, ref, _) {
          final subs = ref.watch(nodesProvider).subscriptions;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: const Text(
                      '订阅管理',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () {
                        Navigator.pop(c);
                        _addSubDialog(context);
                      },
                    ),
                  ),
                  if (subs.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('暂无订阅'),
                    ),
                  for (final s in subs)
                    ListTile(
                      title: Text(s.name),
                      subtitle: Text(
                        '${s.nodeCount} 个节点 · ${s.updatedAt == null ? '从未更新' : '更新于 ${s.updatedAt!.toLocal().toString().substring(0, 16)}'}${s.lastError != null ? '\n错误：${s.lastError}' : ''}',
                        style: TextStyle(
                          color: s.lastError != null ? kBad : null,
                        ),
                      ),
                      isThreeLine: s.lastError != null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            onPressed: () async {
                              final r = await ref
                                  .read(nodesProvider.notifier)
                                  .updateSubscription(s);
                              if (context.mounted) _showOutcome(context, r);
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => ref
                                .read(nodesProvider.notifier)
                                .deleteSubscription(s.id),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
