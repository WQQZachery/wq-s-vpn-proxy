// SPDX-License-Identifier: GPL-3.0-or-later
// 出口 IP 与 IP 信誉。所有字段均来自第三方真实返回；失败时返回“数据不可用”，不编造。
// 隐私：这些查询会把你的出口 IP 发送给对应第三方（api.ip.sb / ipinfo.io / AbuseIPDB）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import '../networking/probes.dart';

class ExitIpInfo {
  ExitIpInfo({
    required this.ip,
    this.asn,
    this.org,
    this.isp,
    this.country,
    this.region,
    this.city,
    required this.source,
    required this.fetchedAt,
  });
  final String ip;
  final String? asn;
  final String? org;
  final String? isp;
  final String? country;
  final String? region;
  final String? city;
  final String source;
  final DateTime fetchedAt;

  Map<String, dynamic> toJson() => {
    'ip': ip,
    'asn': asn,
    'org': org,
    'isp': isp,
    'country': country,
    'region': region,
    'city': city,
    'source': source,
    'fetchedAt': fetchedAt.toIso8601String(),
  };
}

/// 解析 api.ip.sb/geoip 返回。
ExitIpInfo parseIpSb(String body, DateTime now) {
  final j = (jsonDecode(body) as Map).cast<String, dynamic>();
  final ip = j['ip'] as String?;
  if (ip == null || ip.isEmpty) throw const FormatException('响应缺少 ip 字段');
  return ExitIpInfo(
    ip: ip,
    asn: j['asn'] == null ? null : 'AS${j['asn']}',
    org: j['asn_organization'] as String?,
    isp: j['isp'] as String? ?? j['organization'] as String?,
    country: j['country'] as String?,
    region: j['region'] as String?,
    city: j['city'] as String?,
    source: 'api.ip.sb',
    fetchedAt: now,
  );
}

/// 解析 ipinfo.io/json 返回（无 token 时的免费字段）。
ExitIpInfo parseIpInfo(String body, DateTime now) {
  final j = (jsonDecode(body) as Map).cast<String, dynamic>();
  final ip = j['ip'] as String?;
  if (ip == null) throw const FormatException('响应缺少 ip 字段');
  final org = j['org'] as String?; // 形如 "AS13335 Cloudflare, Inc."
  String? asn;
  String? orgName = org;
  if (org != null && org.startsWith('AS')) {
    final sp = org.indexOf(' ');
    asn = sp > 0 ? org.substring(0, sp) : org;
    orgName = sp > 0 ? org.substring(sp + 1) : null;
  }
  return ExitIpInfo(
    ip: ip,
    asn: asn,
    org: orgName,
    isp: orgName,
    country: j['country'] as String?,
    region: j['region'] as String?,
    city: j['city'] as String?,
    source: 'ipinfo.io',
    fetchedAt: now,
  );
}

/// 信誉字段：保留原始字段名与提供方定义，不自创“纯净度”。
class ReputationField {
  const ReputationField(this.key, this.value, this.definition);
  final String key;
  final String value;
  final String definition;
}

class ReputationReport {
  ReputationReport({
    required this.provider,
    required this.ip,
    required this.fields,
    required this.fetchedAt,
    this.fromCache = false,
    this.raw = const {},
    this.quotaLimit,
    this.quotaRemaining,
  });
  final String provider;

  /// 来自响应头 X-RateLimit-Limit / X-RateLimit-Remaining（每日配额）；未返回时为 null。
  final int? quotaLimit;
  final int? quotaRemaining;
  final String ip;
  final List<ReputationField> fields;
  final DateTime fetchedAt;
  final bool fromCache;

  /// 接口返回的 data 原始字段（类型化读取用）。
  final Map<String, dynamic> raw;

  int? get abuseScore => (raw['abuseConfidenceScore'] as num?)?.toInt();
  int? get totalReports => (raw['totalReports'] as num?)?.toInt();
  int? get distinctUsers => (raw['numDistinctUsers'] as num?)?.toInt();
  DateTime? get lastReportedAt =>
      DateTime.tryParse('${raw['lastReportedAt'] ?? ''}');
  String? get usageType => raw['usageType'] as String?;
  String? get isp => raw['isp'] as String?;
  String? get domain => raw['domain'] as String?;
  String? get countryCode => raw['countryCode'] as String?;
  bool? get isTor => raw['isTor'] as bool?;
  bool? get isWhitelisted => raw['isWhitelisted'] as bool?;
  bool? get isPublic => raw['isPublic'] as bool?;

  /// 统计窗口（查询参数 maxAgeInDays）。
  static const maxAgeDays = 90;

  ReputationReport cachedCopy() => ReputationReport(
    provider: provider,
    ip: ip,
    fields: fields,
    fetchedAt: fetchedAt,
    fromCache: true,
    raw: raw,
    quotaLimit: quotaLimit,
    quotaRemaining: quotaRemaining,
  );
}

/// 滥用置信度的中文分档说明（仅描述 AbuseIPDB 分数本身的含义，不是对 IP 安全性的结论）。
String abuseScoreBand(int score) {
  if (score == 0) return '近 90 天内没有可计入的举报';
  if (score < 25) return '有少量举报，置信度低';
  if (score < 75) return '有一定数量的举报，置信度中等';
  return '举报较多，AbuseIPDB 认为滥用可能性高';
}

/// 解析 AbuseIPDB v2 /check 返回。
ReputationReport parseAbuseIpDb(String body, DateTime now) {
  final j = (jsonDecode(body) as Map).cast<String, dynamic>();
  final d = (j['data'] as Map?)?.cast<String, dynamic>();
  if (d == null) throw const FormatException('AbuseIPDB 响应缺少 data');
  String v(String k) => d[k] == null ? '（未返回）' : '${d[k]}';
  return ReputationReport(
    provider: 'AbuseIPDB',
    ip: v('ipAddress'),
    fetchedAt: now,
    raw: d,
    fields: [
      ReputationField(
        'abuseConfidenceScore',
        v('abuseConfidenceScore'),
        'AbuseIPDB 根据用户举报计算的滥用置信度，0–100，越高表示越可能有恶意活动（定义见 AbuseIPDB API 文档）',
      ),
      ReputationField(
        'totalReports',
        v('totalReports'),
        '统计窗口（maxAgeInDays=90）内收到的举报次数',
      ),
      ReputationField('numDistinctUsers', v('numDistinctUsers'), '提交举报的不同用户数'),
      ReputationField('lastReportedAt', v('lastReportedAt'), '最近一次被举报时间'),
      ReputationField(
        'usageType',
        v('usageType'),
        'AbuseIPDB 对该 IP 用途的分类（如 Data Center/Web Hosting/Transit）',
      ),
      ReputationField('isp', v('isp'), 'AbuseIPDB 记录的 ISP'),
      ReputationField('domain', v('domain'), 'AbuseIPDB 记录的所属域名'),
      ReputationField('isPublic', v('isPublic'), '是否为公网地址'),
      ReputationField('countryCode', v('countryCode'), 'AbuseIPDB 记录的国家代码'),
      ReputationField('isTor', v('isTor'), '是否为已知 Tor 出口节点'),
      ReputationField(
        'isWhitelisted',
        v('isWhitelisted'),
        '是否在 AbuseIPDB 白名单中',
      ),
    ],
  );
}

/// 失败原因分类，界面据此给出不同的提示。
enum ReputationFailure { noKey, quota, auth, http, network, data }

class ReputationException implements Exception {
  ReputationException(this.kind, this.message, [ReputationFailure? failure])
    : failure = failure ??
          switch (kind) {
            ProbeErrorKind.quotaExceeded => ReputationFailure.quota,
            ProbeErrorKind.apiUnavailable => ReputationFailure.data,
            ProbeErrorKind.httpError => ReputationFailure.http,
            ProbeErrorKind.protocolError => ReputationFailure.data,
            _ => ReputationFailure.network,
          };
  final ProbeErrorKind kind;
  final String message;
  final ReputationFailure failure;
  @override
  String toString() => message;
}

class IpReputationService {
  IpReputationService({
    this.timeout = const Duration(seconds: 8),
    this.cacheTtl = const Duration(minutes: 30),
  });
  final Duration timeout;
  final Duration cacheTtl;
  final Map<String, ReputationReport> _cache = {};

  Future<ExitIpInfo> fetchExitIp() async {
    final probes = NetworkProbes(timeout: timeout);
    Object? lastErr;
    for (final (url, parser) in [
      (Uri.parse('https://api.ip.sb/geoip'), parseIpSb),
      (Uri.parse('https://ipinfo.io/json'), parseIpInfo),
    ]) {
      try {
        final r = await probes.httpGet(
          url,
          headers: {'Accept': 'application/json'},
        );
        if (r.status != 200) throw HttpException('HTTP ${r.status}');
        return parser(r.body, DateTime.now());
      } catch (e) {
        lastErr = e;
      }
    }
    throw ReputationException(
      classifyError(lastErr!),
      '出口 IP 查询失败：${describeError(lastErr)}',
    );
  }

  /// 查询 AbuseIPDB。apiKey 由用户在设置中填写（安全存储），源码中不含任何密钥。
  Future<ReputationReport> checkAbuseIpDb(
    String ip,
    String apiKey, {
    String endpoint = 'https://api.abuseipdb.com/api/v2/check',
  }) async {
    if (apiKey.isEmpty)
      throw ReputationException(
        ProbeErrorKind.apiUnavailable,
        '未配置 AbuseIPDB API Key',
        ReputationFailure.noKey,
      );
    final cached = _cache[ip];
    if (cached != null &&
        DateTime.now().difference(cached.fetchedAt) < cacheTtl) {
      return cached.cachedCopy();
    }
    final url = Uri.parse(endpoint)
        .replace(queryParameters: {'ipAddress': ip, 'maxAgeInDays': '90'});
    final probes = NetworkProbes(timeout: timeout);
    for (var attempt = 0; attempt < 2; attempt++) {
      HttpTiming r;
      try {
        r = await probes.httpGet(
          url,
          headers: {'Key': apiKey, 'Accept': 'application/json'},
        );
      } catch (e) {
        if (attempt == 1)
          throw ReputationException(classifyError(e), describeError(e));
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      if (r.status == 429) {
        throw ReputationException(
          ProbeErrorKind.quotaExceeded,
          'AbuseIPDB 配额已用尽或被限流（HTTP 429${r.headers['retry-after'] != null ? '，${r.headers['retry-after']} 秒后重试' : ''}）',
        );
      }
      if (r.status == 401 || r.status == 403)
        throw ReputationException(
          ProbeErrorKind.httpError,
          'API Key 无效或无权限（HTTP ${r.status}）',
          ReputationFailure.auth,
        );
      if (r.status >= 500 && attempt == 0) {
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      if (r.status != 200)
        throw ReputationException(
          ProbeErrorKind.httpError,
          'AbuseIPDB 返回 HTTP ${r.status}',
        );
      final ReputationReport rep;
      try {
        rep = parseAbuseIpDb(r.body, DateTime.now());
      } on FormatException catch (e) {
        throw ReputationException(
          ProbeErrorKind.protocolError,
          '返回数据不完整：${e.message}',
          ReputationFailure.data,
        );
      }
      final withQuota = ReputationReport(
        provider: rep.provider,
        ip: rep.ip,
        fields: rep.fields,
        fetchedAt: rep.fetchedAt,
        raw: rep.raw,
        quotaLimit: int.tryParse(r.headers['x-ratelimit-limit'] ?? ''),
        quotaRemaining: int.tryParse(r.headers['x-ratelimit-remaining'] ?? ''),
      );
      _cache[ip] = withQuota;
      return withQuota;
    }
    throw ReputationException(ProbeErrorKind.apiUnavailable, '数据不可用');
  }
}
