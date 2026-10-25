// SPDX-License-Identifier: GPL-3.0-or-later
// R1：节点分组与排序。只影响列表展示，不修改任何节点数据或生成的配置。
// 分组方式、排序方式与折叠状态保存在数据库 kv 表中，重启后恢复。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state.dart';
import '../../core/models/models.dart';

enum NodeGroupMode {
  none('不分组'),
  source('按来源'),
  protocol('按协议'),
  custom('自定义');

  const NodeGroupMode(this.label);
  final String label;
}

enum NodeSortMode {
  original('默认顺序'),
  latency('按延迟'),
  name('按名称');

  const NodeSortMode(this.label);
  final String label;
}

class NodeGroup {
  const NodeGroup(this.key, this.title, this.nodes);

  /// 稳定键（用于保存折叠状态）：`sub:<id>`、`manual`、`proto:<name>`、`all`。
  final String key;
  final String title;
  final List<ProxyNode> nodes;
}

/// 手动添加 / 分享链接导入 / 无订阅归属的节点所在分组。
const manualGroupKey = 'manual';

/// 不属于任何自定义分组的节点。
const ungroupedKey = 'cg:none';

/// 用户自建分组。成员按节点的 dedupKey 记录，订阅刷新后节点 id 变化也不会丢失归属。
/// 一个节点最多属于一个自定义分组。
class CustomGroup {
  const CustomGroup(this.id, this.name, [this.members = const {}]);
  final String id;
  final String name;
  final Set<String> members;

  bool contains(ProxyNode n) => members.contains(n.dedupKey);

  CustomGroup copyWith({String? name, Set<String>? members}) =>
      CustomGroup(id, name ?? this.name, members ?? this.members);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'members': members.toList()..sort(),
  };

  static CustomGroup? fromJson(Object? o) {
    if (o is! Map) return null;
    final id = o['id'], name = o['name'];
    if (id is! String || name is! String || id.isEmpty) return null;
    return CustomGroup(
      id,
      name,
      ((o['members'] as List?) ?? const []).whereType<String>().toSet(),
    );
  }
}

List<CustomGroup> decodeCustomGroups(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  try {
    return [
      for (final o in jsonDecode(raw) as List) ?CustomGroup.fromJson(o),
    ];
  } catch (_) {
    return const [];
  }
}

String encodeCustomGroups(List<CustomGroup> g) =>
    jsonEncode([for (final x in g) x.toJson()]);

CustomGroup? customGroupOf(ProxyNode n, List<CustomGroup> groups) {
  final k = n.dedupKey;
  for (final g in groups) {
    if (g.members.contains(k)) return g;
  }
  return null;
}

String groupKeyOf(
  ProxyNode n,
  NodeGroupMode mode, [
  List<CustomGroup> custom = const [],
]) => switch (mode) {
  NodeGroupMode.none => 'all',
  NodeGroupMode.custom => switch (customGroupOf(n, custom)) {
    null => ungroupedKey,
    final g => 'cg:${g.id}',
  },
  NodeGroupMode.protocol => 'proto:${n.protocol.name}',
  NodeGroupMode.source =>
    (n.subscriptionId == null || n.subscriptionId!.isEmpty)
        ? manualGroupKey
        : 'sub:${n.subscriptionId}',
};

/// 对已经过搜索/筛选的 [nodes] 排序并分组。
/// [latencyOf] 返回节点当前可用的延迟（毫秒），无结果或失败返回 null。
List<NodeGroup> groupNodes(
  List<ProxyNode> nodes, {
  required NodeGroupMode mode,
  NodeSortMode sort = NodeSortMode.original,
  List<Subscription> subscriptions = const [],
  List<CustomGroup> customGroups = const [],
  int? Function(ProxyNode)? latencyOf,
}) {
  final indexed = [for (var i = 0; i < nodes.length; i++) (i, nodes[i])];
  int cmp((int, ProxyNode) a, (int, ProxyNode) b) {
    switch (sort) {
      case NodeSortMode.original:
        break;
      case NodeSortMode.latency:
        final la = latencyOf?.call(a.$2), lb = latencyOf?.call(b.$2);
        // 有结果的在前（小的在前），无结果/失败的在后，保持稳定
        if (la != null && lb != null && la != lb) return la.compareTo(lb);
        if (la != null && lb == null) return -1;
        if (la == null && lb != null) return 1;
      case NodeSortMode.name:
        final c = a.$2.name.toLowerCase().compareTo(b.$2.name.toLowerCase());
        if (c != 0) return c;
    }
    return a.$1.compareTo(b.$1);
  }

  final sorted = [...indexed]..sort(cmp);
  final out = sorted.map((e) => e.$2).toList();
  if (mode == NodeGroupMode.none) {
    return out.isEmpty ? const [] : [NodeGroup('all', '全部节点', out)];
  }

  final buckets = <String, List<ProxyNode>>{};
  for (final n in out) {
    (buckets[groupKeyOf(n, mode, customGroups)] ??= []).add(n);
  }

  final order = <String>[];
  final titles = <String, String>{};
  if (mode == NodeGroupMode.source) {
    order.add(manualGroupKey);
    titles[manualGroupKey] = '手动 / 分享链接';
    for (final s in subscriptions) {
      order.add('sub:${s.id}');
      titles['sub:${s.id}'] = s.name;
    }
  } else if (mode == NodeGroupMode.custom) {
    for (final g in customGroups) {
      order.add('cg:${g.id}');
      titles['cg:${g.id}'] = g.name;
    }
    order.add(ungroupedKey);
    titles[ungroupedKey] = '未分组';
  } else {
    for (final p in ProxyProtocol.values) {
      order.add('proto:${p.name}');
      titles['proto:${p.name}'] = p.label;
    }
  }
  // 订阅已删除但节点仍在的情况：放在最后，标题标注
  for (final k in buckets.keys) {
    if (!order.contains(k)) {
      order.add(k);
      titles[k] = '已删除的订阅';
    }
  }
  return [
    for (final k in order)
      if (buckets[k]?.isNotEmpty ?? false) NodeGroup(k, titles[k]!, buckets[k]!),
  ];
}

class NodeGroupPrefs {
  const NodeGroupPrefs({
    this.mode = NodeGroupMode.source,
    this.sort = NodeSortMode.original,
    this.collapsed = const {},
  });
  final NodeGroupMode mode;
  final NodeSortMode sort;
  final Set<String> collapsed;

  NodeGroupPrefs copyWith({
    NodeGroupMode? mode,
    NodeSortMode? sort,
    Set<String>? collapsed,
  }) => NodeGroupPrefs(
    mode: mode ?? this.mode,
    sort: sort ?? this.sort,
    collapsed: collapsed ?? this.collapsed,
  );

  String encode() => jsonEncode({
    'mode': mode.name,
    'sort': sort.name,
    'collapsed': collapsed.toList()..sort(),
  });

  /// 容错解析：任何异常或未知值都回退到默认，不影响节点页打开。
  static NodeGroupPrefs decode(String? raw) {
    if (raw == null || raw.isEmpty) return const NodeGroupPrefs();
    try {
      final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return NodeGroupPrefs(
        mode: NodeGroupMode.values.asNameMap()[j['mode']] ?? NodeGroupMode.source,
        sort: NodeSortMode.values.asNameMap()[j['sort']] ?? NodeSortMode.original,
        collapsed: ((j['collapsed'] as List?) ?? const [])
            .whereType<String>()
            .toSet(),
      );
    } catch (_) {
      return const NodeGroupPrefs();
    }
  }
}

class NodeGroupPrefsNotifier extends Notifier<NodeGroupPrefs> {
  static const kvKey = 'nodeGroupPrefs';

  @override
  NodeGroupPrefs build() {
    unawaited(_load());
    return const NodeGroupPrefs();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    final raw = await db.getKv(kvKey);
    if (!ref.mounted) return;
    state = NodeGroupPrefs.decode(raw);
  }

  Future<void> _save(NodeGroupPrefs p) async {
    state = p;
    await ref.read(databaseProvider).setKv(kvKey, p.encode());
  }

  Future<void> setMode(NodeGroupMode m) => _save(state.copyWith(mode: m));
  Future<void> setSort(NodeSortMode s) => _save(state.copyWith(sort: s));
  Future<void> toggle(String key) {
    final c = {...state.collapsed};
    if (!c.remove(key)) c.add(key);
    return _save(state.copyWith(collapsed: c));
  }
}

final nodeGroupPrefsProvider =
    NotifierProvider<NodeGroupPrefsNotifier, NodeGroupPrefs>(
      NodeGroupPrefsNotifier.new,
    );


class CustomGroupsNotifier extends Notifier<List<CustomGroup>> {
  static const kvKey = 'customGroups';

  @override
  List<CustomGroup> build() {
    unawaited(_load());
    return const [];
  }

  Future<void> _load() async {
    final raw = await ref.read(databaseProvider).getKv(kvKey);
    if (!ref.mounted) return;
    state = decodeCustomGroups(raw);
  }

  Future<void> _save(List<CustomGroup> g) async {
    state = g;
    await ref.read(databaseProvider).setKv(kvKey, encodeCustomGroups(g));
  }

  /// 返回新分组 id；名称为空或重名时返回 null。
  Future<String?> create(String name) async {
    final n = name.trim();
    if (n.isEmpty || state.any((g) => g.name == n)) return null;
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    await _save([...state, CustomGroup(id, n)]);
    return id;
  }

  Future<bool> rename(String id, String name) async {
    final n = name.trim();
    if (n.isEmpty || state.any((g) => g.name == n && g.id != id)) return false;
    await _save([for (final g in state) g.id == id ? g.copyWith(name: n) : g]);
    return true;
  }

  /// 只删除分组本身，节点不受影响（回到“未分组”）。
  Future<void> remove(String id) =>
      _save([for (final g in state) if (g.id != id) g]);

  /// 把 [nodes] 移入分组 [id]（null = 移出所有分组）。一个节点只属于一个分组。
  Future<void> assign(Iterable<ProxyNode> nodes, String? id) {
    final keys = {for (final n in nodes) n.dedupKey};
    return _save([
      for (final g in state)
        g.copyWith(
          members: g.id == id
              ? {...g.members, ...keys}
              : g.members.difference(keys),
        ),
    ]);
  }

  /// 用勾选结果整体设置分组成员（勾掉的移出，勾上的从其他分组移过来）。
  Future<void> setMembers(String id, Iterable<ProxyNode> nodes) {
    final keys = {for (final n in nodes) n.dedupKey};
    return _save([
      for (final g in state)
        g.copyWith(members: g.id == id ? keys : g.members.difference(keys)),
    ]);
  }
}

final customGroupsProvider =
    NotifierProvider<CustomGroupsNotifier, List<CustomGroup>>(
      CustomGroupsNotifier.new,
    );
