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
  protocol('按协议');

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

String groupKeyOf(ProxyNode n, NodeGroupMode mode) => switch (mode) {
  NodeGroupMode.none => 'all',
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
    (buckets[groupKeyOf(n, mode)] ??= []).add(n);
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
