// SPDX-License-Identifier: GPL-3.0-or-later
import 'proxy_node.dart';

export 'proxy_node.dart';

/// sing-box 1.14.3 支持的 uTLS 指纹白名单。
/// 来源：sing-box 源码 common/tls/utls_client.go（case 分支穷举）。
/// 其他客户端的约定值（如 v2rayN 的 `fp=unsafe` 表示跳过证书校验）不在此列，
/// 原样写入会导致 sing-box 配置初始化失败：`unknown uTLS fingerprint: xxx`，
/// 且该失败会让整份配置（含全部节点）校验不过——表现为换任何节点都无法连接。
const kValidUtlsFingerprints = <String>{
  'chrome',
  'chrome_psk',
  'chrome_psk_shuffle',
  'chrome_padding_psk_shuffle',
  'chrome_pq',
  'chrome_pq_psk',
  'firefox',
  'edge',
  'safari',
  '360',
  'qq',
  'ios',
  'android',
  'random',
  'randomized',
};

/// 将任意来源的 fingerprint 规整为 sing-box 可接受的值；
/// 非法值（含空串）返回 null（由调用方回退默认 chrome 或不写 utls）。
String? sanitizeUtlsFingerprint(String? fp) {
  if (fp == null) return null;
  final v = fp.trim().toLowerCase();
  if (v.isEmpty) return null;
  return kValidUtlsFingerprints.contains(v) ? v : null;
}

/// 返回 fingerprint 已净化的节点副本；无需变化时返回原对象（省一次拷贝）。
/// 用于入库自愈：旧数据可能含 sing-box 不认识的指纹（如其他客户端的 'unsafe'）。
ProxyNode healUtlsFingerprint(ProxyNode n) {
  final fixed = sanitizeUtlsFingerprint(n.tls.fingerprint);
  if (fixed == n.tls.fingerprint) return n;
  return n.copyWith(
    tls: TlsOptions(
      enabled: n.tls.enabled,
      serverName: n.tls.serverName,
      insecure: n.tls.insecure,
      alpn: n.tls.alpn,
      fingerprint: fixed,
      realityPublicKey: n.tls.realityPublicKey,
      realityShortId: n.tls.realityShortId,
    ),
  );
}

/// 批量测速档位。参考 V2RayN / NekoBox 等客户端的实践：
/// 快速档用高并发 + 短超时做批量初筛；精确档用低并发 + 多次连接取中位数。
/// rounds 仅作用于 TCP 探测；VPN 运行时经核心的真实代理延迟测试不受档位影响。
/// 节点延迟检测档位。并发与超时作用于 LatencyScheduler / 分层探测：
/// VPN 运行时经 Clash API 做真实代理延迟；否则 TCP（+TLS 握手）。
enum TestProfile {
  quick('快速', 16, 3, '高并发短超时，数秒完成全量初筛'),
  standard('标准', 8, 5, '并发与超时均衡（默认）'),
  accurate('精确', 4, 8, '低并发长超时，弱网环境下结论更稳');

  const TestProfile(this.label, this.concurrency, this.timeoutSec, this.description);

  final String label;
  final int concurrency;
  final int timeoutSec;
  final String description;

  static TestProfile fromName(String? name) => TestProfile.values.firstWhere(
    (p) => p.name == name,
    orElse: () => TestProfile.standard,
  );
}

/// 订阅。URL 本身视为敏感数据（常含 token），存安全存储，SQLite 只存 id/名称/统计。
class Subscription {
  Subscription({
    required this.id,
    required this.name,
    this.url = '',
    this.updatedAt,
    this.nodeCount = 0,
    this.lastError,
  });

  final String id;
  final String name;
  final String url;
  final DateTime? updatedAt;
  final int nodeCount;
  final String? lastError;

  Subscription copyWith({
    String? name,
    String? url,
    DateTime? updatedAt,
    int? nodeCount,
    String? lastError,
    bool clearError = false,
  }) => Subscription(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    updatedAt: updatedAt ?? this.updatedAt,
    nodeCount: nodeCount ?? this.nodeCount,
    lastError: clearError ? null : (lastError ?? this.lastError),
  );

  Map<String, Object?> toDbRow() => {
    'id': id,
    'name': name,
    'updated_at': updatedAt?.millisecondsSinceEpoch,
    'node_count': nodeCount,
    'last_error': lastError,
  };

  static Subscription fromDbRow(Map<String, Object?> r, String url) =>
      Subscription(
        id: r['id'] as String,
        name: r['name'] as String,
        url: url,
        updatedAt: r['updated_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
        nodeCount: (r['node_count'] as int?) ?? 0,
        lastError: r['last_error'] as String?,
      );
}

/// 路由模式。
enum RouteMode {
  global('全局代理', '除局域网与保留地址外，所有流量经所选节点'),
  rule('自动分流', '按规则顺序匹配：DNS 劫持 → 局域网/私有地址直连 → 用户直连域名 → 用户代理域名 → 其余走代理'),
  direct('直连模式', 'VPN 接管流量但全部直连，用于排查或对比');

  const RouteMode(this.label, this.description);
  final String label;
  final String description;
}

/// 统一的检测结果结构：状态、耗时、时间戳、检测方式、错误原因。
enum ProbeStatus { success, failure, partial, skipped }

enum ProbeErrorKind {
  none('无'),
  dnsError('DNS 解析失败'),
  timeout('超时'),
  connectionRefused('连接被拒绝'),
  networkUnreachable('网络不可达'),
  tlsError('TLS 错误'),
  certificateError('证书校验失败'),
  httpError('HTTP 错误状态'),
  protocolError('协议错误'),
  quotaExceeded('配额受限 / 限流'),
  apiUnavailable('数据不可用'),
  unknown('未知错误');

  const ProbeErrorKind(this.label);
  final String label;
}

class ProbeStep {
  const ProbeStep({
    required this.name,
    required this.ok,
    this.durationMs,
    this.detail,
  });
  final String name;
  final bool ok;
  final int? durationMs;
  final String? detail;

  Map<String, dynamic> toJson() => {
    'name': name,
    'ok': ok,
    'durationMs': durationMs,
    'detail': detail,
  };
  factory ProbeStep.fromJson(Map<String, dynamic> j) => ProbeStep(
    name: j['name'] as String,
    ok: j['ok'] as bool,
    durationMs: j['durationMs'] as int?,
    detail: j['detail'] as String?,
  );
}

class ProbeResult {
  ProbeResult({
    required this.kind,
    required this.target,
    required this.method,
    required this.status,
    required this.timestamp,
    required this.totalMs,
    this.errorKind = ProbeErrorKind.none,
    this.errorMessage,
    this.httpStatus,
    this.steps = const [],
    this.data = const {},
    this.conclusion,
  });

  /// dns | tcp | tls | https | cloudflare | claude | exit_ip | reputation | node_latency
  final String kind;
  final String target;

  /// 检测方式说明，例如“直连（未经 VPN）”或“经当前 VPN 隧道”。
  final String method;
  final ProbeStatus status;
  final DateTime timestamp;
  final int totalMs;
  final ProbeErrorKind errorKind;
  final String? errorMessage;
  final int? httpStatus;
  final List<ProbeStep> steps;
  final Map<String, dynamic> data;

  /// 结论（必须如实，例如“网络可达，服务有响应；未验证账户”）。
  final String? conclusion;

  bool get ok => status == ProbeStatus.success;
}

/// 节点健康状态。
class NodeHealth {
  const NodeHealth({
    required this.nodeId,
    this.lastLatencyMs,
    this.lastTestAt,
    this.lastSuccessAt,
    this.testCount = 0,
    this.failCount = 0,
    this.lastError,
    this.method,
  });

  final String nodeId;
  final int? lastLatencyMs;
  final DateTime? lastTestAt;
  final DateTime? lastSuccessAt;
  final int testCount;
  final int failCount;
  final String? lastError;

  /// tcp（仅端口连通）或 proxy（经代理实际请求）
  final String? method;

  bool get untested => lastTestAt == null;
  double get failureRate => testCount == 0 ? 0 : failCount / testCount;
  bool get lastFailed => lastTestAt != null && lastError != null;
}

/// VPN 连接状态（与 Kotlin 层 VpnState 一致）。
enum VpnState { stopped, starting, started, stopping, error }

/// 原生层上报的流量计数快照（累计字节）。
class TrafficSnapshot {
  const TrafficSnapshot({
    required this.timestampMs,
    required this.rxBytes,
    required this.txBytes,
  });
  final int timestampMs;
  final int rxBytes;
  final int txBytes;
}
