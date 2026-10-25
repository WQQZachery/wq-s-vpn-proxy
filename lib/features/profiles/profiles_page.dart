// SPDX-License-Identifier: GPL-3.0-or-later
// 节点页：标题、检测状态与搜索/筛选形成一个连续的头部区域，节点列表作为一个整体分组承接其下。
// 进入页面即自动检测（调度、并发与冷却见 LatencyScheduler）。
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/state.dart';
import '../../app/theme.dart';
import '../../core/engine/latency_tester.dart';
import '../../core/models/models.dart';
import '../../core/networking/share_link_serializer.dart';
import '../../app/vpn_tint.dart';
import 'node_editor.dart';
import 'node_grouping.dart';
import 'qr_import.dart';

/// 一个二维码（纠错级别 L、字节模式）可容纳约 2900 字节；留余量。
const qrMaxChars = 2400;

enum NodeFilter { all, enabled, healthy, failed, untested }

/// 合并“本次检测”与“历史（缓存）”后，节点当前应显示的检测结论。
class NodeLatencyView {
  const NodeLatencyView({
    required this.status,
    this.ms,
    this.layer,
    this.error,
    this.at,
    this.cached = false,
  });
  final LatencyStatus? status; // null = 从未检测
  final int? ms;
  final LatencyLayer? layer;
  final String? error;
  final DateTime? at;

  /// true 表示来自之前会话保存的结果（不是本次实时检测）。
  final bool cached;

  bool get ok => status == LatencyStatus.ok;
  bool get failed =>
      status == LatencyStatus.failed || status == LatencyStatus.timeout;

  static NodeLatencyView of(NodesState st, String id) {
    final e = st.latency[id];
    if (e != null && e.status != LatencyStatus.cancelled) {
      // 排队/检测中时保留上一次数值，避免文字闪烁
      return NodeLatencyView(
        status: e.status,
        ms: e.ms,
        layer: e.layer,
        error: e.error,
        at: e.at,
      );
    }
    final h = st.health[id];
    if (h == null || h.untested) {
      return NodeLatencyView(status: e?.status);
    }
    final err = h.lastError;
    return NodeLatencyView(
      status: err == null
          ? LatencyStatus.ok
          : (err.contains('超时') ? LatencyStatus.timeout : LatencyStatus.failed),
      ms: h.lastLatencyMs,
      layer: LatencyLayerX.parse(h.method),
      error: err,
      at: h.lastTestAt,
      cached: true,
    );
  }
}

/// Hysteria2 / TUIC 走 QUIC（UDP），没有 tcp/ws 这类传输层选项。
String transportLabel(ProxyNode n) =>
    n.protocol == ProxyProtocol.hysteria2 || n.protocol == ProxyProtocol.tuic
    ? 'QUIC'
    : n.transport.type;

Color latencyColor(int ms) => ms < 200
    ? kGood
    : ms < 500
    ? kWarn
    : kBad;

class ProfilesPage extends ConsumerStatefulWidget {
  const ProfilesPage({super.key, this.active = false});

  /// 当前是否为可见的标签页；变为可见时触发自动检测。
  final bool active;
  @override
  ConsumerState<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends ConsumerState<ProfilesPage> {
  String _q = '';
  NodeFilter _filter = NodeFilter.all;

  @override
  void initState() {
    super.initState();
    if (widget.active) _scheduleAuto();
  }

  @override
  void didUpdateWidget(ProfilesPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _scheduleAuto();
  }

  Timer? _autoTimer;

  void _scheduleAuto() {
    // 等页面转场完成后再发起，避免与转场争抢首帧；快速切走又切回只保留最后一次
    _autoTimer?.cancel();
    _autoTimer = Timer(const Duration(milliseconds: 280), () {
      if (mounted &&
          widget.active &&
          ref.read(settingsProvider).autoTestNodes) {
        ref.read(nodesProvider.notifier).autoTest();
      }
    });
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    super.dispose();
  }

  bool _match(ProxyNode x, NodesState st) {
    if (_q.isNotEmpty) {
      final q = _q.toLowerCase();
      if (!x.name.toLowerCase().contains(q) &&
          !x.server.toLowerCase().contains(q)) {
        return false;
      }
    }
    final v = NodeLatencyView.of(st, x.id);
    return switch (_filter) {
      NodeFilter.all => true,
      NodeFilter.enabled => x.enabled,
      NodeFilter.healthy => v.ok,
      NodeFilter.failed => v.failed,
      NodeFilter.untested => v.status == null,
    };
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(nodesProvider.select((s) => s.loading), (prev, loading) {
      if (prev == true &&
          !loading &&
          widget.active &&
          ref.read(settingsProvider).autoTestNodes) {
        ref.read(nodesProvider.notifier).autoTest();
      }
    });
    final st = ref.watch(nodesProvider);
    final vpn = ref.watch(vpnControllerProvider);
    final list = st.nodes.where((x) => _match(x, st)).toList();
    final prefs = ref.watch(nodeGroupPrefsProvider);
    final groups = groupNodes(
      list,
      mode: prefs.mode,
      sort: prefs.sort,
      subscriptions: st.subscriptions,
      latencyOf: (n) {
        final v = NodeLatencyView.of(st, n.id);
        return v.ok ? v.ms : null;
      },
    );
    final enabledCount = st.nodes.where((x) => x.enabled).length;
    final busy = st.latency.values.where((e) => e.busy).length;
    final doneThisRun = st.latency.values.where((e) => e.done).length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        tooltip: '添加节点',
        onPressed: () => _addMenu(context),
        child: const Icon(Icons.add),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: PageHeader(
              '节点',
              subtitle: Text(
                st.loading ? '加载中…' : '${st.nodes.length} 个节点 · $enabledCount 个已启用',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '分组与排序',
                    icon: Icon(
                      prefs.mode == NodeGroupMode.none
                          ? Icons.view_agenda_outlined
                          : Icons.view_agenda_rounded,
                    ),
                    onPressed: () => _groupSheet(context),
                  ),
                  IconButton(
                    tooltip: '订阅管理',
                    icon: const Icon(Icons.rss_feed_rounded),
                    onPressed: () => _subs(context),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _ProbeStatusBar(
              viaProxy: vpn.state == VpnState.started,
              busy: busy,
              done: doneThisRun,
              onCancel: busy > 0
                  ? () => ref.read(nodesProvider.notifier).cancelTests()
                  : null,
              onRetestAll: busy > 0 || list.isEmpty
                  ? null
                  : () => ref
                        .read(nodesProvider.notifier)
                        .testNodes(list.where((x) => x.enabled).toList()),
            ),
          ),
          SliverPersistentHeader(
            pinned: true,
            delegate: _SearchHeader(
              textScale: MediaQuery.textScalerOf(context).scale(14) / 14,
              filter: _filter,
              onQuery: (v) => setState(() => _q = v),
              onFilter: (f) => setState(() => _filter = f),
              groupLabel: prefs.mode == NodeGroupMode.none
                  ? '分组'
                  : '${prefs.mode.label}分组',
              onGroup: () => _groupSheet(context),
              bg: switch (ref.watch(vpnTintProvider).color) {
                null => AppColors.bg,
                final c => tintTop(c),
              },
            ),
          ),
          if (st.loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (st.nodes.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.dns_outlined,
                title: '还没有节点',
                message: '可以手动添加自有服务器，或导入分享链接 / 订阅。',
                action: FilledButton.icon(
                  onPressed: () => _addMenu(context),
                  icon: const Icon(Icons.add),
                  label: const Text('添加节点'),
                ),
              ),
            )
          else if (list.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.filter_alt_off_outlined,
                title: '没有符合条件的节点',
                message: '试试清空搜索词或切换筛选条件。',
              ),
            )
          else ...[
            for (final g in groups) ...[
              if (prefs.mode != NodeGroupMode.none)
                SliverToBoxAdapter(
                  child: _GroupHeader(
                    key: ValueKey('h-${g.key}'),
                    title: g.title,
                    count: g.nodes.length,
                    okCount: g.nodes
                        .where((n) => NodeLatencyView.of(st, n.id).ok)
                        .length,
                    collapsed: prefs.collapsed.contains(g.key),
                    onToggle: () => ref
                        .read(nodeGroupPrefsProvider.notifier)
                        .toggle(g.key),
                  ),
                ),
              if (prefs.mode == NodeGroupMode.none ||
                  !prefs.collapsed.contains(g.key))
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    Gaps.page - 4,
                    4,
                    Gaps.page - 4,
                    8,
                  ),
                  sliver: SliverList.builder(
                    itemCount: g.nodes.length,
                    itemBuilder: (c, i) {
                      final n = g.nodes[i];
                      return _NodeRow(
                        key: ValueKey(n.id),
                        node: n,
                        first: i == 0,
                        last: i == g.nodes.length - 1,
                        selected: st.selectedId == n.id,
                        inUse: st.selectedId == n.id &&
                            vpn.state == VpnState.started,
                        view: NodeLatencyView.of(st, n.id),
                        subName: _subName(st, n),
                        onTap: n.enabled
                            ? () => ref.read(nodesProvider.notifier).select(n.id)
                            : null,
                        onAction: (v) => _action(context, v, n),
                      );
                    },
                  ),
                ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 88)),
          ],
        ],
      ),
    );
  }

  String? _subName(NodesState st, ProxyNode node) =>
      node.subscriptionId == null || node.subscriptionId!.isEmpty
      ? null
      : st.subscriptions
            .where((s) => s.id == node.subscriptionId)
            .firstOrNull
            ?.name;


  Future<void> _action(BuildContext context, String v, ProxyNode node) async {
    final n = ref.read(nodesProvider.notifier);
    switch (v) {
      case 'test':
        unawaited(n.testNodes([node]));
      case 'edit':
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => NodeEditorPage(initial: node)),
        );
      case 'dup':
        await n.duplicate(node);
      case 'toggle':
        await n.toggle(node);
      case 'export':
        await _exportNodes(context, [node]);
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

  /// R2：导出节点。内容含凭据，任何导出动作前都必须经过隐私确认。
  Future<void> _exportNodes(BuildContext context, List<ProxyNode> nodes) async {
    if (nodes.isEmpty) return;
    final exportable = nodes.where(ShareLinkSerializer.canExport).toList();
    final skipped = nodes.length - exportable.length;
    if (exportable.isEmpty) {
      showSnack(context, '没有可导出的节点（HTTP 代理没有通用分享链接格式）');
      return;
    }
    final single = exportable.length == 1;
    final links = ShareLinkSerializer.toLines(exportable).text;
    final qrOk = utf8.encode(links).length <= qrMaxChars;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                single
                    ? '导出「${exportable.first.name}」'
                    : '导出 ${exportable.length} 个节点'
                          '${skipped > 0 ? '（跳过 $skipped 个 HTTP 节点）' : ''}',
                style: Theme.of(c).textTheme.titleMedium,
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                '导出内容包含服务器地址、UUID/密码和 REALITY 参数等完整凭据，'
                '拿到它的人都能使用该节点。只发给可信的人，不要贴到公开场合；'
                '剪贴板可能被输入法或其他应用读取，用完建议清空。',
                style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('复制分享链接'),
              onTap: () => Navigator.pop(c, 'copy'),
            ),
            if (!single)
              ListTile(
                leading: const Icon(Icons.rss_feed_rounded),
                title: const Text('复制为订阅内容（Base64）'),
                onTap: () => Navigator.pop(c, 'sub'),
              ),
            ListTile(
              leading: const Icon(Icons.share_rounded),
              title: const Text('系统分享'),
              onTap: () => Navigator.pop(c, 'share'),
            ),
            ListTile(
              enabled: qrOk,
              leading: const Icon(Icons.qr_code_2_rounded),
              title: const Text('显示二维码'),
              subtitle: qrOk ? null : const Text('内容过长，无法放进一个二维码，请减少节点数量'),
              onTap: () => Navigator.pop(c, 'qr'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'copy':
      case 'sub':
        final text = action == 'sub'
            ? ShareLinkSerializer.toSubscription(exportable).text
            : links;
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) showSnack(context, '已复制 ${exportable.length} 个节点');
      case 'share':
        await SharePlus.instance.share(
          ShareParams(
            text: links,
            subject: single ? exportable.first.name : 'WQ\'s Proxy VPN 节点',
          ),
        );
      case 'qr':
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(single ? exportable.first.name : '${exportable.length} 个节点'),
            content: SizedBox(
              width: 260,
              height: 260,
              child: ColoredBox(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: QrImageView(
                    data: links,
                    errorCorrectionLevel: QrErrorCorrectLevel.L,
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
    }
  }

  Future<void> _importQr(BuildContext context, {required bool gallery}) async {
    final QrPayload? p = gallery
        ? await pickQrFromGallery(context)
        : await Navigator.of(context).push<QrPayload>(
            MaterialPageRoute(builder: (_) => const QrScanPage()),
          );
    if (p == null || !context.mounted) return;
    switch (p.kind) {
      case QrPayloadKind.unknown:
        showSnack(context, '没有识别到节点或订阅二维码');
      case QrPayloadKind.subscriptionUrl:
        await _addSubDialog(context, initialUrl: p.text);
      case QrPayloadKind.nodes:
        final r = await ref.read(nodesProvider.notifier).importText(p.text);
        if (context.mounted) _showOutcome(context, r);
    }
  }

  void _groupSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => Consumer(
        builder: (c, ref, _) {
          final p = ref.watch(nodeGroupPrefsProvider);
          final n = ref.read(nodeGroupPrefsProvider.notifier);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('分组', style: Theme.of(c).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<NodeGroupMode>(
                    showSelectedIcon: false,
                    segments: [
                      for (final m in NodeGroupMode.values)
                        ButtonSegment(value: m, label: Text(m.label)),
                    ],
                    selected: {p.mode},
                    onSelectionChanged: (v) => n.setMode(v.first),
                  ),
                  const SizedBox(height: 16),
                  Text('排序', style: Theme.of(c).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<NodeSortMode>(
                    showSelectedIcon: false,
                    segments: [
                      for (final m in NodeSortMode.values)
                        ButtonSegment(value: m, label: Text(m.label)),
                    ],
                    selected: {p.sort},
                    onSelectionChanged: (v) => n.setSort(v.first),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '分组和排序只改变列表显示，不影响节点配置和连接。',
                    style: Theme.of(c).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
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
              leading: const Icon(Icons.qr_code_scanner_rounded),
              title: const Text('扫码导入'),
              subtitle: const Text('节点二维码或订阅二维码'),
              onTap: () {
                Navigator.pop(c);
                _importQr(context, gallery: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册图片识别'),
              onTap: () {
                Navigator.pop(c);
                _importQr(context, gallery: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('导出节点'),
              subtitle: const Text('导出当前列表中显示的节点（含凭据）'),
              onTap: () {
                Navigator.pop(c);
                final st = ref.read(nodesProvider);
                _exportNodes(
                  context,
                  st.nodes.where((x) => _match(x, st)).toList(),
                );
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

  Future<void> _addSubDialog(BuildContext context, {String? initialUrl}) async {
    final name = TextEditingController();
    final url = TextEditingController(text: initialUrl ?? '');
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


class _ProbeStatusBar extends StatelessWidget {
  const _ProbeStatusBar({
    required this.viaProxy,
    required this.busy,
    required this.done,
    this.onCancel,
    this.onRetestAll,
  });
  final bool viaProxy;
  final int busy;
  final int done;
  final VoidCallback? onCancel;
  final VoidCallback? onRetestAll;

  @override
  Widget build(BuildContext context) {
    final total = busy + done;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gaps.page, 10, Gaps.page - 8, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: StatusPill(
                        viaProxy ? '经内核代理检测' : '仅 TCP / TLS 检测',
                        color: viaProxy ? kGood : kWarn,
                        icon: viaProxy ? Icons.verified_rounded : Icons.lan_outlined,
                      ),
                    ),
                    InfoTip(
                      title: '检测方式',
                      message: viaProxy
                          ? 'VPN 已连接：每个节点都由 sing-box 内核实际发起一次 HTTP 请求（generate_204），显示的是经该节点完成请求的耗时，能代表节点真实可用。'
                          : 'VPN 未连接：只能检测服务器 TCP 端口是否可达；对普通 TLS 节点还会做一次严格校验证书的 TLS 握手。\n'
                                '这两项都不能证明代理协议、密码或 UUID 正确。Hysteria2 / TUIC 基于 UDP，需连接 VPN 后检测。\n'
                                '连接 VPN 后进入本页会自动改为经代理检测。',
                    ),
                  ],
                ),
              ),
              SwapSwitcher(
                identity: busy > 0,
                alignment: Alignment.centerRight,
                child: busy > 0
                    ? TextButton(
                        onPressed: onCancel,
                        child: const Text('取消'),
                      )
                    : TextButton.icon(
                        onPressed: onRetestAll,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('重测'),
                      ),
              ),
            ],
          ),
          // 固定高度，检测开始/结束时下方列表不跳动
          SizedBox(
            height: 18,
            child: AnimatedOpacity(
              opacity: busy > 0 ? 1 : 0,
              duration: Motion.of(context, Motion.medium),
              child: Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: total == 0 ? null : done / total,
                        minHeight: 3,
                        backgroundColor: AppColors.border,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '检测中 $done/$total · 并发 4',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textTertiary,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchHeader extends SliverPersistentHeaderDelegate {
  _SearchHeader({
    required this.textScale,
    required this.filter,
    required this.onQuery,
    required this.onFilter,
    required this.groupLabel,
    required this.onGroup,
    required this.bg,
  });
  final Color bg;
  final String groupLabel;
  final VoidCallback onGroup;
  final double textScale;
  final NodeFilter filter;
  final ValueChanged<String> onQuery;
  final ValueChanged<NodeFilter> onFilter;

  static const _labels = {
    NodeFilter.all: '全部',
    NodeFilter.enabled: '已启用',
    NodeFilter.healthy: '可用',
    NodeFilter.failed: '失败',
    NodeFilter.untested: '未检测',
  };

  // 高度随系统字体缩放计算，避免大字体时溢出
  double get _extent =>
      6 + 8 + (26 * textScale + 22) + (24 * textScale + 18).clamp(40, 80) + 4;
  @override
  double get minExtent => _extent;
  @override
  double get maxExtent => _extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.96),
        border: Border(
          bottom: BorderSide(
            color: overlaps ? AppColors.border : Colors.transparent,
          ),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gaps.page - 4, 6, Gaps.page - 4, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded, size: 20),
                hintText: '搜索名称或地址',
              ),
              onChanged: onQuery,
            ),
          ),
          SizedBox(
            height: (24 * textScale + 18).clamp(40, 80),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gaps.page - 8),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ActionChip(
                    avatar: const Icon(Icons.view_agenda_outlined, size: 18),
                    label: Text(groupLabel),
                    onPressed: onGroup,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                for (final f in NodeFilter.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(_labels[f]!),
                      selected: filter == f,
                      onSelected: (_) => onFilter(f),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_SearchHeader old) =>
      old.filter != filter ||
      old.textScale != textScale ||
      old.groupLabel != groupLabel ||
      old.bg != bg;
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    super.key,
    required this.title,
    required this.count,
    required this.okCount,
    required this.collapsed,
    required this.onToggle,
  });
  final String title;
  final int count;
  final int okCount;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      expanded: !collapsed,
      label: '$title，$count 个节点',
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gaps.page, 12, Gaps.page - 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.titleSmall,
                ),
              ),
              Text(
                okCount > 0 ? '$okCount/$count 可用' : '$count 个',
                style: t.bodySmall?.copyWith(color: AppColors.textTertiary),
              ),
              AnimatedRotation(
                turns: collapsed ? -0.25 : 0,
                duration: Motion.of(context, Motion.fast),
                child: const Icon(
                  Icons.expand_more_rounded,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    super.key,
    required this.node,
    required this.first,
    required this.last,
    required this.selected,
    required this.inUse,
    required this.view,
    required this.subName,
    required this.onTap,
    required this.onAction,
  });
  final ProxyNode node;
  final bool first;
  final bool last;
  final bool selected;
  final bool inUse;
  final NodeLatencyView view;
  final String? subName;
  final VoidCallback? onTap;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.vertical(
      top: first ? const Radius.circular(Radii.lg) : Radius.zero,
      bottom: last ? const Radius.circular(Radii.lg) : Radius.zero,
    );
    final accent = inUse ? kGood : kAccent;
    final meta = [
      node.protocol.label,
      transportLabel(node),
      if (node.tls.isReality) 'REALITY' else if (node.tls.enabled) 'TLS',
      ?subName,
    ].join(' · ');
    final errorLine = view.failed || view.status == LatencyStatus.unsupported
        ? view.error
        : null;
    return Container(
      decoration: BoxDecoration(
        color: selected
            ? Color.lerp(AppColors.surface, accent, 0.07)
            : AppColors.surface,
        borderRadius: radius,
        border: Border(
          left: const BorderSide(color: AppColors.border),
          right: const BorderSide(color: AppColors.border),
          top: first ? const BorderSide(color: AppColors.border) : BorderSide.none,
          bottom: const BorderSide(color: AppColors.border),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Opacity(
            opacity: node.enabled ? 1 : 0.45,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 2, 12),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: Motion.of(context, Motion.medium),
                    curve: Curves.easeOutCubic,
                    width: 4,
                    height: 34,
                    decoration: BoxDecoration(
                      color: selected ? accent : Colors.transparent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                node.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight:
                                      selected ? FontWeight.w700 : FontWeight.w500,
                                ),
                              ),
                            ),
                            if (inUse) ...[
                              const SizedBox(width: 6),
                              const StatusPill('使用中', color: kGood),
                            ] else if (selected) ...[
                              const SizedBox(width: 6),
                              const StatusPill('已选', color: kAccent),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          node.enabled ? meta : '$meta · 已禁用',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textTertiary,
                          ),
                        ),
                        // 错误行使用 AnimatedSize，结果出现时平滑展开而不是跳动
                        AnimatedSize(
                          duration: Motion.of(context, Motion.medium),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topLeft,
                          child: errorLine == null
                              ? const SizedBox(width: double.infinity)
                              : Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    errorLine,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: view.status ==
                                              LatencyStatus.unsupported
                                          ? AppColors.textMuted
                                          : kBad.withValues(alpha: 0.85),
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _LatencyBadge(view: view),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    icon: const Icon(
                      Icons.more_vert_rounded,
                      size: 20,
                      color: AppColors.textTertiary,
                    ),
                    onSelected: onAction,
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'test', child: Text('重新检测')),
                      if (node.source == NodeSource.manual ||
                          node.subscriptionId == null)
                        const PopupMenuItem(value: 'edit', child: Text('编辑')),
                      const PopupMenuItem(value: 'dup', child: Text('复制为手动节点')),
                      if (ShareLinkSerializer.canExport(node))
                        const PopupMenuItem(value: 'export', child: Text('导出分享链接')),
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
          ),
        ),
      ),
    );
  }
}

/// 固定宽度的延迟徽标：状态切换时交叉淡入，不改变行宽。
class _LatencyBadge extends StatelessWidget {
  const _LatencyBadge({required this.view});
  final NodeLatencyView view;

  @override
  Widget build(BuildContext context) {
    final v = view;
    Widget main;
    String? sub;
    String key;
    switch (v.status) {
      case LatencyStatus.queued:
        key = 'q';
        main = _t(v.ms != null ? '${v.ms} ms' : '排队中', AppColors.textMuted);
        sub = '排队中';
      case LatencyStatus.testing:
        key = 't';
        main = const SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        sub = '检测中';
      case LatencyStatus.ok:
        key = 'ok${v.ms}${v.cached}';
        final c = v.cached
            ? AppColors.textSecondary
            : (v.layer == LatencyLayer.proxy
                  ? latencyColor(v.ms ?? 9999)
                  : AppColors.textPrimary);
        main = _t('${v.ms} ms', c);
        sub = v.cached ? '上次 · ${v.layer?.label ?? ''}' : v.layer?.label;
      case LatencyStatus.timeout:
        key = 'to${v.cached}';
        main = _t('超时', v.cached ? AppColors.textTertiary : kWarn);
        sub = v.cached ? '上次结果' : v.layer?.label;
      case LatencyStatus.failed:
        key = 'f${v.cached}';
        main = _t('失败', v.cached ? AppColors.textTertiary : kBad);
        sub = v.cached ? '上次结果' : v.layer?.label;
      case LatencyStatus.unsupported:
        key = 'u';
        main = _t('不适用', AppColors.textMuted);
        sub = '需连接 VPN';
      case LatencyStatus.cancelled:
        key = 'c';
        main = _t('已取消', AppColors.textMuted);
      case null:
        key = 'n';
        main = _t('未检测', AppColors.textMuted);
    }
    // 固定宽度 + 最小高度：状态切换时行宽不变；系统大字体时高度可随之增长而不溢出
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 78, maxWidth: 78, minHeight: 34),
      child: SwapSwitcher(
        identity: key,
        alignment: Alignment.centerRight,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            FittedBox(fit: BoxFit.scaleDown, child: main),
            if (sub != null)
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
              ),
          ],
        ),
      ),
    );
  }

  Widget _t(String s, Color c) => Text(
    s,
    maxLines: 1,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: c,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}
