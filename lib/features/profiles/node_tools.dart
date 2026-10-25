// SPDX-License-Identifier: GPL-3.0-or-later
// 节点页工具：检测范围选择、自定义分组管理、一键删除失效节点、风险连接确认。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state.dart';
import '../../app/theme.dart';
import '../../core/engine/node_risk.dart';
import '../../core/models/models.dart';
import 'node_grouping.dart';

/// 一个可检测的范围（全部 / 某个分组）。
class TestScope {
  const TestScope(this.title, this.nodes, {this.subtitle});
  final String title;
  final String? subtitle;
  final List<ProxyNode> nodes;
}

/// 让用户选择本次检测哪个分组。返回要检测的节点（只含已启用的），取消返回 null。
Future<List<ProxyNode>?> pickTestScope(
  BuildContext context,
  List<TestScope> scopes,
) {
  return showModalBottomSheet<List<ProxyNode>>(
    context: context,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(c).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text('检测哪些节点？', style: Theme.of(c).textTheme.titleMedium),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '只检测已启用的节点。',
                style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in scopes)
                    Builder(
                      builder: (_) {
                        final enabled = s.nodes.where((n) => n.enabled).toList();
                        return ListTile(
                          leading: const Icon(Icons.network_ping_rounded),
                          title: Text(s.title),
                          subtitle: Text(s.subtitle ?? '${enabled.length} 个已启用节点'),
                          enabled: enabled.isNotEmpty,
                          onTap: () => Navigator.pop(c, enabled),
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 一键删除失效节点（最近一次检测失败或超时）。
Future<void> deleteFailedNodes(
  BuildContext context,
  WidgetRef ref,
  List<ProxyNode> failed,
) async {
  if (failed.isEmpty) {
    showSnack(context, '没有失效节点（只统计检测失败或超时的节点，未检测的不算）');
    return;
  }
  final fromSub = failed.where((n) => (n.subscriptionId ?? '').isNotEmpty).length;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('删除 ${failed.length} 个失效节点？'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              failed.take(12).map((n) => '· ${n.name}').join('\n') +
                  (failed.length > 12 ? '\n…等 ${failed.length} 个' : ''),
            ),
            const SizedBox(height: 12),
            Text(
              '依据最近一次检测结果（失败或超时）。网络临时波动也可能导致失败，建议连接 VPN 后再检测一次再删。'
              '${fromSub > 0 ? '\n其中 $fromSub 个来自订阅，订阅下次更新时可能重新出现。' : ''}',
              style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kBad),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final n = await ref
      .read(nodesProvider.notifier)
      .deleteMany(failed.map((e) => e.id));
  if (context.mounted) showSnack(context, '已删除 $n 个失效节点');
}

/// 连接前的风险确认。返回 true = 用户选择风险连接（并已记住该节点）。
/// 非风险节点、已允许过的节点、或设置中允许全部风险连接时直接返回 true。
Future<bool> confirmRiskyConnect(
  BuildContext context,
  WidgetRef ref,
  ProxyNode node,
) async {
  final risk = assessRisk(node);
  final st = ref.read(settingsProvider);
  if (!risk.risky || st.allowAllRisky || st.riskAllowedIds.contains(node.id)) {
    return true;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      icon: Icon(
        Icons.gpp_maybe_rounded,
        color: risk.high ? kBad : kWarn,
      ),
      title: Text(risk.high ? '高风险节点' : '风险节点'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('「${node.name}」存在以下风险：'),
          const SizedBox(height: 8),
          for (final r in risk.reasons) Text('· $r'),
          const SizedBox(height: 12),
          const Text(
            '仍然连接后会记住你的选择，可在节点菜单中取消。',
            style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child: Text('仍然连接', style: TextStyle(color: risk.high ? kBad : kWarn)),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  await ref.read(settingsProvider.notifier).setRiskAllowed(node.id, true);
  return true;
}

/// 风险标记小标签。
class RiskPill extends StatelessWidget {
  const RiskPill(this.risk, {super.key});
  final NodeRisk risk;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: risk.reasons.join('\n'),
    child: StatusPill(
      risk.high ? '高风险' : '风险',
      color: risk.high ? kBad : kWarn,
    ),
  );
}

Future<String?> _askName(BuildContext context, String title, [String initial = '']) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLength: 24,
        decoration: const InputDecoration(hintText: '例如：常用、游戏、备用'),
        onSubmitted: (v) => Navigator.pop(d, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('确定')),
      ],
    ),
  );
}

/// 新建分组：返回新分组 id。
Future<String?> createCustomGroup(BuildContext context, WidgetRef ref) async {
  final name = await _askName(context, '新建分组');
  if (name == null || !context.mounted) return null;
  final id = await ref.read(customGroupsProvider.notifier).create(name);
  if (id == null && context.mounted) showSnack(context, '名称为空或已存在');
  return id;
}

/// 把单个节点移到某个自定义分组。
Future<void> moveNodeToGroup(BuildContext context, WidgetRef ref, ProxyNode node) async {
  final groups = ref.read(customGroupsProvider);
  final current = customGroupOf(node, groups);
  final pick = await showModalBottomSheet<String>(
    context: context,
    builder: (c) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('「${node.name}」移到分组', style: Theme.of(c).textTheme.titleSmall),
            ),
            for (final g in groups)
              ListTile(
                leading: Icon(
                  current?.id == g.id ? Icons.radio_button_checked : Icons.radio_button_off,
                ),
                title: Text(g.name),
                onTap: () => Navigator.pop(c, g.id),
              ),
            if (current != null)
              ListTile(
                leading: const Icon(Icons.remove_circle_outline),
                title: const Text('移出分组'),
                onTap: () => Navigator.pop(c, ''),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('新建分组…'),
              onTap: () => Navigator.pop(c, '+'),
            ),
          ],
        ),
      ),
    ),
  );
  if (pick == null || !context.mounted) return;
  var id = pick;
  if (pick == '+') {
    final created = await createCustomGroup(context, ref);
    if (created == null) return;
    id = created;
  }
  await ref.read(customGroupsProvider.notifier).assign([node], id.isEmpty ? null : id);
  if (context.mounted && ref.read(nodeGroupPrefsProvider).mode != NodeGroupMode.custom) {
    await ref.read(nodeGroupPrefsProvider.notifier).setMode(NodeGroupMode.custom);
  }
}

/// 自定义分组管理页：新建、重命名、删除、勾选成员。
class CustomGroupsPage extends ConsumerWidget {
  const CustomGroupsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(customGroupsProvider);
    final nodes = ref.watch(nodesProvider).nodes;
    final n = ref.read(customGroupsProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('自定义分组')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final id = await createCustomGroup(context, ref);
          if (id != null && context.mounted) {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => GroupMembersPage(groupId: id)),
            );
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('新建分组'),
      ),
      body: groups.isEmpty
          ? const EmptyState(
              icon: Icons.folder_open_outlined,
              title: '还没有自定义分组',
              message: '新建分组后勾选节点即可。也可以在节点菜单里选「移到分组」。',
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                for (final g in groups)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(g.name),
                    subtitle: Text('${nodes.where(g.contains).length} 个节点'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => GroupMembersPage(groupId: g.id)),
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'rename') {
                          final name = await _askName(context, '重命名分组', g.name);
                          if (name != null && !await n.rename(g.id, name) && context.mounted) {
                            showSnack(context, '名称为空或已存在');
                          }
                        } else if (v == 'del') {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: Text('删除分组「${g.name}」？'),
                              content: const Text('只删除分组，节点不会被删除，会回到「未分组」。'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                                TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除')),
                              ],
                            ),
                          );
                          if (ok == true) await n.remove(g.id);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('重命名')),
                        PopupMenuItem(value: 'del', child: Text('删除分组')),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

/// 勾选分组成员。
class GroupMembersPage extends ConsumerStatefulWidget {
  const GroupMembersPage({super.key, required this.groupId});
  final String groupId;
  @override
  ConsumerState<GroupMembersPage> createState() => _GroupMembersPageState();
}

class _GroupMembersPageState extends ConsumerState<GroupMembersPage> {
  Set<String>? _picked; // 节点 id
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(customGroupsProvider);
    final g = groups.where((x) => x.id == widget.groupId).firstOrNull;
    final nodes = ref.watch(nodesProvider).nodes;
    if (g == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('分组不存在')));
    }
    _picked ??= {for (final n in nodes) if (g.contains(n)) n.id};
    final picked = _picked!;
    final q = _q.toLowerCase();
    final shown = nodes
        .where((n) => q.isEmpty || n.name.toLowerCase().contains(q) || n.server.toLowerCase().contains(q))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text('${g.name} · 已选 ${picked.length}'),
        actions: [
          TextButton(
            onPressed: () async {
              await ref.read(customGroupsProvider.notifier).setMembers(
                g.id,
                nodes.where((n) => picked.contains(n.id)),
              );
              if (ref.read(nodeGroupPrefsProvider).mode != NodeGroupMode.custom) {
                await ref.read(nodeGroupPrefsProvider.notifier).setMode(NodeGroupMode.custom);
              }
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded, size: 20),
                hintText: '搜索名称或地址',
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Row(
            children: [
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => picked.addAll(shown.map((n) => n.id))),
                child: const Text('全选当前'),
              ),
              TextButton(
                onPressed: () => setState(() => picked.removeAll(shown.map((n) => n.id))),
                child: const Text('取消当前'),
              ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              itemCount: shown.length,
              itemBuilder: (c, i) {
                final n = shown[i];
                final other = customGroupOf(n, groups);
                return CheckboxListTile(
                  value: picked.contains(n.id),
                  onChanged: (v) => setState(() => v == true ? picked.add(n.id) : picked.remove(n.id)),
                  title: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    other != null && other.id != g.id
                        ? '${n.protocol.label} · 当前在「${other.name}」，勾选后移过来'
                        : n.protocol.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
