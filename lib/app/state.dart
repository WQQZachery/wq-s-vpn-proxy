// SPDX-License-Identifier: GPL-3.0-or-later
// 应用状态（Riverpod）。选择 Riverpod：编译期安全、可测试、无需 BuildContext 访问状态，是 Flutter 社区主流成熟方案。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/engine/config_builder.dart';
import '../core/engine/node_validator.dart';
import '../core/engine/traffic_meter.dart';
import '../core/engine/vpn_engine.dart';
import '../core/models/models.dart';
import '../core/networking/probes.dart';
import '../core/networking/share_link_parser.dart';
import '../core/security/redact.dart';
import '../core/storage/app_database.dart';

final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('在 main() 中覆盖'),
);
final vpnEngineProvider = Provider<VpnEngine>((ref) => VpnEngine());

String newId() {
  final r = Random.secure();
  return List.generate(
    16,
    (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

final parserProvider = Provider<ShareLinkParser>(
  (ref) => ShareLinkParser(newId: newId),
);

// ---------------- 应用日志（已脱敏，内存环形缓冲） ----------------
class AppLog extends Notifier<List<String>> {
  @override
  List<String> build() => [];
  void add(String msg) {
    final line = '${DateTime.now().toIso8601String()} ${redact(msg)}';
    final next = [...state, line];
    state = next.length > 500 ? next.sublist(next.length - 500) : next;
  }
}

final appLogProvider = NotifierProvider<AppLog, List<String>>(AppLog.new);

// ---------------- 设置 ----------------
class SettingsState {
  const SettingsState({
    this.engine = const EngineSettings(),
    this.retentionDays = 30,
    this.abuseIpDbKey = '',
    this.cloudflareTarget = 'https://www.cloudflare.com/cdn-cgi/trace',
    this.claudeTarget = 'https://api.anthropic.com/v1/messages',
  });
  final EngineSettings engine;
  final int retentionDays;
  final String abuseIpDbKey;
  final String cloudflareTarget;
  final String claudeTarget;

  SettingsState copyWith({
    EngineSettings? engine,
    int? retentionDays,
    String? abuseIpDbKey,
    String? cloudflareTarget,
    String? claudeTarget,
  }) => SettingsState(
    engine: engine ?? this.engine,
    retentionDays: retentionDays ?? this.retentionDays,
    abuseIpDbKey: abuseIpDbKey ?? this.abuseIpDbKey,
    cloudflareTarget: cloudflareTarget ?? this.cloudflareTarget,
    claudeTarget: claudeTarget ?? this.claudeTarget,
  );
}

class SettingsNotifier extends Notifier<SettingsState> {
  @override
  SettingsState build() {
    unawaited(_load());
    return const SettingsState();
  }

  AppDatabase get _db => ref.read(databaseProvider);

  Future<void> _load() async {
    final raw = await _db.getKv('engine');
    final ret = int.tryParse(await _db.getKv('retentionDays') ?? '') ?? 30;
    final key = await _db.getSecretSetting('abuseipdb') ?? '';
    state = SettingsState(
      engine: raw == null
          ? const EngineSettings()
          : EngineSettings.fromJson(
              (jsonDecode(raw) as Map).cast<String, dynamic>(),
            ),
      retentionDays: ret,
      abuseIpDbKey: key,
      cloudflareTarget: await _db.getKv('cfTarget') ?? state.cloudflareTarget,
      claudeTarget: await _db.getKv('claudeTarget') ?? state.claudeTarget,
    );
    await _db.pruneProbes(Duration(days: ret));
  }

  Future<void> updateEngine(EngineSettings e) async {
    state = state.copyWith(engine: e);
    await _db.setKv('engine', jsonEncode(e.toJson()));
  }

  Future<void> setRetention(int days) async {
    state = state.copyWith(retentionDays: days);
    await _db.setKv('retentionDays', '$days');
    await _db.pruneProbes(Duration(days: days));
  }

  Future<void> setAbuseKey(String k) async {
    state = state.copyWith(abuseIpDbKey: k.trim());
    await _db.setSecretSetting('abuseipdb', k.trim());
  }

  Future<void> setTargets({String? cf, String? claude}) async {
    if (cf != null) {
      state = state.copyWith(cloudflareTarget: cf);
      await _db.setKv('cfTarget', cf);
    }
    if (claude != null) {
      state = state.copyWith(claudeTarget: claude);
      await _db.setKv('claudeTarget', claude);
    }
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, SettingsState>(
  SettingsNotifier.new,
);

// ---------------- 节点与订阅 ----------------
class NodesState {
  const NodesState({
    this.nodes = const [],
    this.health = const {},
    this.subscriptions = const [],
    this.selectedId,
    this.loading = true,
    this.testing = const {},
  });
  final List<ProxyNode> nodes;
  final Map<String, NodeHealth> health;
  final List<Subscription> subscriptions;
  final String? selectedId;
  final bool loading;
  final Set<String> testing;

  ProxyNode? get selected {
    for (final n in nodes) {
      if (n.id == selectedId) return n;
    }
    return null;
  }

  NodesState copyWith({
    List<ProxyNode>? nodes,
    Map<String, NodeHealth>? health,
    List<Subscription>? subscriptions,
    String? selectedId,
    bool? loading,
    Set<String>? testing,
    bool clearSelected = false,
  }) => NodesState(
    nodes: nodes ?? this.nodes,
    health: health ?? this.health,
    subscriptions: subscriptions ?? this.subscriptions,
    selectedId: clearSelected ? null : (selectedId ?? this.selectedId),
    loading: loading ?? this.loading,
    testing: testing ?? this.testing,
  );
}

class ImportOutcome {
  ImportOutcome({
    required this.added,
    required this.duplicates,
    required this.rejected,
    required this.issues,
  });
  final int added;
  final int duplicates;
  final int rejected;
  final List<String> issues;
}

class NodesNotifier extends Notifier<NodesState> {
  @override
  NodesState build() {
    unawaited(reload());
    return const NodesState();
  }

  AppDatabase get _db => ref.read(databaseProvider);
  void _log(String m) => ref.read(appLogProvider.notifier).add(m);

  Future<void> reload() async {
    final nodes = await _db.listNodes();
    final subs = await _db.listSubscriptions();
    final health = await _db.listHealth();
    var sel = await _db.getKv('selectedNode');
    if (sel != null && !nodes.any((n) => n.id == sel)) sel = null;
    sel ??= nodes.where((n) => n.enabled).firstOrNull?.id;
    state = NodesState(
      nodes: nodes,
      health: health,
      subscriptions: subs,
      selectedId: sel,
      loading: false,
    );
  }

  Future<void> select(String id) async {
    state = state.copyWith(selectedId: id);
    await _db.setKv('selectedNode', id);
    await ref.read(vpnControllerProvider.notifier).onSelectedNodeChanged();
  }

  /// 保存（新增或编辑）手动节点；校验失败抛出异常。
  Future<ValidationResult> save(ProxyNode n) async {
    final r = NodeValidator.validate(n);
    if (!r.ok) return r;
    await _db.upsertNode(n);
    await reload();
    return r;
  }

  Future<void> delete(String id) async {
    await _db.deleteNode(id);
    await reload();
  }

  Future<void> duplicate(ProxyNode n) async {
    await _db.upsertNode(
      n.copyWith(
        id: newId(),
        name: '${n.name} 副本',
        source: NodeSource.manual,
        subscriptionId: '',
      ),
    );
    await reload();
  }

  Future<void> toggle(ProxyNode n) async {
    await _db.upsertNode(n.copyWith(enabled: !n.enabled));
    await reload();
  }

  /// 导入分享链接 / 配置文本（逐条校验并去重）。
  Future<ImportOutcome> importText(String text) async {
    final parser = ref.read(parserProvider);
    final ParseReport rep;
    try {
      rep =
          text.trim().contains('\n') ||
              text.trim().startsWith('{') ||
              !text.contains('://')
          ? parser.parseBulk(
              text,
              source: text.trim().startsWith('{')
                  ? NodeSource.configFile
                  : NodeSource.shareLink,
            )
          : ParseReport([parser.parseLink(text)], const []);
    } on NodeParseException catch (e) {
      return ImportOutcome(
        added: 0,
        duplicates: 0,
        rejected: 1,
        issues: [e.message],
      );
    }
    return _ingest(
      rep.nodes,
      rep.issues.map((i) => '第 ${i.index} 条：${i.reason}').toList(),
      null,
    );
  }

  Future<ImportOutcome> _ingest(
    List<ProxyNode> candidates,
    List<String> issues,
    String? subId,
  ) async {
    final existingKeys = state.nodes
        .where((n) => subId == null || n.subscriptionId != subId)
        .map((n) => n.dedupKey)
        .toSet();
    final (unique, dupInBatch) = dedupNodes(candidates);
    var rejected = 0;
    var dups = dupInBatch;
    final accepted = <ProxyNode>[];
    for (final n in unique) {
      final v = NodeValidator.validate(n);
      if (!v.ok) {
        rejected++;
        issues.add('「${n.name}」未通过校验：${v.errors.join('；')}');
        continue;
      }
      if (existingKeys.contains(n.dedupKey)) {
        dups++;
        continue;
      }
      accepted.add(n);
    }
    if (subId == null) {
      for (final n in accepted) {
        await _db.upsertNode(n);
      }
    } else {
      await _db.replaceSubscriptionNodes(subId, accepted);
    }
    await reload();
    _log('导入完成：新增 ${accepted.length}，重复 $dups，拒绝 $rejected');
    return ImportOutcome(
      added: accepted.length,
      duplicates: dups,
      rejected: rejected + issues.where((i) => i.startsWith('第')).length,
      issues: issues,
    );
  }

  Future<Subscription> addSubscription(String name, String url) async {
    final u = Uri.tryParse(url.trim());
    if (u == null ||
        (u.scheme != 'https' && u.scheme != 'http') ||
        u.host.isEmpty) {
      throw const FormatException('订阅地址必须是 http(s) URL');
    }
    final s = Subscription(
      id: newId(),
      name: name.trim().isEmpty ? u.host : name.trim(),
      url: url.trim(),
    );
    await _db.upsertSubscription(s);
    await reload();
    return s;
  }

  Future<void> deleteSubscription(String id) async {
    await _db.deleteSubscription(id);
    await reload();
  }

  /// 下载并解析订阅；错误写回订阅记录（不含 URL）。
  Future<ImportOutcome> updateSubscription(Subscription s) async {
    _log('更新订阅「${s.name}」：${redactUrl(s.url)}');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'WQsProxyVPN/1.0.0 (sing-box 1.14)';
    try {
      final req = await client
          .getUrl(Uri.parse(s.url))
          .timeout(const Duration(seconds: 15));
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode == 404 || resp.statusCode == 410)
        throw const HttpException('订阅链接不存在或已过期（HTTP 404/410）');
      if (resp.statusCode == 401 || resp.statusCode == 403)
        throw HttpException('订阅服务拒绝访问（HTTP ${resp.statusCode}），令牌可能失效');
      if (resp.statusCode != 200)
        throw HttpException('订阅服务返回 HTTP ${resp.statusCode}');
      final bytes = <int>[];
      await for (final c in resp.timeout(const Duration(seconds: 30))) {
        bytes.addAll(c);
        if (bytes.length > 5 * 1024 * 1024)
          throw const HttpException('订阅内容超过 5 MB 上限');
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final rep = ref
          .read(parserProvider)
          .parseBulk(
            text,
            source: NodeSource.subscription,
            subscriptionId: s.id,
          );
      final out = await _ingest(
        rep.nodes,
        rep.issues.map((i) => '第 ${i.index} 条：${i.reason}').toList(),
        s.id,
      );
      await _db.upsertSubscription(
        s.copyWith(
          updatedAt: DateTime.now(),
          nodeCount: out.added,
          clearError: true,
        ),
      );
      await reload();
      return out;
    } catch (e) {
      final msg = e is NodeParseException
          ? e.message
          : (e is HttpException
                ? e.message
                : '${classifyError(e).label}：${redact(describeError(e))}');
      await _db.upsertSubscription(s.copyWith(lastError: msg));
      await reload();
      _log('订阅「${s.name}」更新失败：$msg');
      return ImportOutcome(added: 0, duplicates: 0, rejected: 0, issues: [msg]);
    } finally {
      client.close(force: true);
    }
  }

  /// 节点健康检查：VPN 运行时经 sing-box 实际代理请求；否则仅测 TCP 端口（明确标注）。并发上限 4。
  Future<void> testNodes(List<ProxyNode> nodes) async {
    final vpn = ref.read(vpnControllerProvider);
    state = state.copyWith(
      testing: {...state.testing, ...nodes.map((n) => n.id)},
    );
    final probes = NetworkProbes(timeout: const Duration(seconds: 5));
    await runLimited<ProxyNode, void>(nodes, 4, (n) async {
      final tag = vpn.nodeTags[n.id];
      try {
        if (vpn.state == VpnState.started && tag != null && vpn.clash != null) {
          final ms = await vpn.clash!.delay(tag);
          await _db.recordHealth(n.id, latencyMs: ms, method: 'proxy');
        } else {
          final ms = await probes.tcpPing(n.server, n.port);
          await _db.recordHealth(n.id, latencyMs: ms, method: 'tcp');
        }
      } catch (e) {
        await _db.recordHealth(
          n.id,
          error: '${classifyError(e).label}：${redact(describeError(e))}',
          method: (vpn.state == VpnState.started && tag != null)
              ? 'proxy'
              : 'tcp',
        );
      }
      final health = await _db.listHealth();
      state = state.copyWith(
        health: health,
        testing: {...state.testing}..remove(n.id),
      );
    });
  }
}

final nodesProvider = NotifierProvider<NodesNotifier, NodesState>(
  NodesNotifier.new,
);

// ---------------- VPN 控制 ----------------
class VpnStatus {
  const VpnStatus({
    this.state = VpnState.stopped,
    this.message,
    this.connectedAt,
    this.nodeName,
    this.nodeTags = const {},
    this.clash,
    this.tick = 0,
    this.mode,
  });
  final VpnState state;
  final String? message;
  final DateTime? connectedAt;
  final String? nodeName;
  final Map<String, String> nodeTags;
  final ClashApiClient? clash;
  final int tick;
  final RouteMode? mode;

  VpnStatus copyWith({
    VpnState? state,
    String? message,
    DateTime? connectedAt,
    String? nodeName,
    Map<String, String>? nodeTags,
    ClashApiClient? clash,
    int? tick,
    RouteMode? mode,
    bool clearMessage = false,
  }) => VpnStatus(
    state: state ?? this.state,
    message: clearMessage ? null : (message ?? this.message),
    connectedAt: connectedAt ?? this.connectedAt,
    nodeName: nodeName ?? this.nodeName,
    nodeTags: nodeTags ?? this.nodeTags,
    clash: clash ?? this.clash,
    tick: tick ?? this.tick,
    mode: mode ?? this.mode,
  );
}

class VpnController extends Notifier<VpnStatus> {
  final meter = TrafficMeter();
  StreamSubscription<EngineEvent>? _sub;

  @override
  VpnStatus build() {
    final engine = ref.read(vpnEngineProvider);
    _sub = engine.events().listen(
      _onEvent,
      onError: (Object e) => _log('事件通道错误：$e'),
    );
    ref.onDispose(() => _sub?.cancel());
    unawaited(
      engine
          .currentState()
          .then((s) {
            state = state.copyWith(state: s.$1, message: s.$2);
          })
          .catchError((Object e) {
            _log('读取原生状态失败：$e');
          }),
    );
    return const VpnStatus();
  }

  void _log(String m) => ref.read(appLogProvider.notifier).add(m);

  void _onEvent(EngineEvent e) {
    if (e.state != null) {
      final s = e.state!;
      _log('VPN 状态：${s.name}${e.message != null ? '（${e.message}）' : ''}');
      if (s == VpnState.started && state.state != VpnState.started) {
        meter.reset();
        state = state.copyWith(
          state: s,
          connectedAt: DateTime.now(),
          message: e.message,
          clearMessage: e.message == null,
        );
      } else if (s == VpnState.stopped || s == VpnState.error) {
        state = VpnStatus(state: s, message: e.message);
      } else {
        state = state.copyWith(
          state: s,
          message: e.message,
          clearMessage: e.message == null,
        );
      }
    } else if (e.traffic != null) {
      meter.add(e.traffic!);
      state = state.copyWith(tick: state.tick + 1);
    }
  }

  Future<String?> connect() async {
    final nodes = ref.read(nodesProvider);
    final sel = nodes.selected;
    if (sel == null) return '请先选择一个节点';
    final engine = ref.read(vpnEngineProvider);
    final settings = ref.read(settingsProvider).engine;
    final secret = newId();
    final BuiltConfig built;
    try {
      built = ConfigBuilder.build(
        nodes: nodes.nodes,
        selected: sel,
        settings: settings,
        clashSecret: secret,
      );
    } on ConfigBuildException catch (e) {
      return e.message;
    }
    final err = await engine.checkConfig(built.json);
    if (err != null) {
      _log('配置校验失败：$err');
      return '配置校验失败：${redact(err)}';
    }
    if (!await engine.prepare()) return '未获得 VPN 授权';
    state = VpnStatus(
      state: VpnState.starting,
      nodeName: sel.name,
      nodeTags: built.nodeTags,
      clash: ClashApiClient(port: settings.clashApiPort, secret: secret),
      mode: settings.routeMode,
    );
    try {
      await engine.start(config: built.json, profileName: sel.name);
    } catch (e) {
      state = VpnStatus(state: VpnState.error, message: '$e');
      return '启动失败：$e';
    }
    return null;
  }

  Future<void> disconnect() async {
    state = state.copyWith(state: VpnState.stopping);
    await ref.read(vpnEngineProvider).stop();
  }

  /// 运行中切换节点：通过 Clash API 切换 selector，不重启核心。
  Future<void> onSelectedNodeChanged() async {
    if (state.state != VpnState.started || state.clash == null) return;
    final sel = ref.read(nodesProvider).selected;
    final tag = sel == null ? null : state.nodeTags[sel.id];
    if (tag == null) {
      _log('所选节点不在当前运行配置中，需重新连接后生效');
      return;
    }
    try {
      await state.clash!.select(ConfigBuilder.proxyTag, tag);
      state = state.copyWith(nodeName: sel!.name);
    } catch (e) {
      _log('切换节点失败：$e');
    }
  }
}

final vpnControllerProvider = NotifierProvider<VpnController, VpnStatus>(
  VpnController.new,
);

String probeMethodLabel(VpnStatus s) => s.state == VpnState.started
    ? '经 VPN 隧道（节点：${s.nodeName ?? '?'}，${s.mode?.label ?? ''}）'
    : '直连（VPN 未开启）';
