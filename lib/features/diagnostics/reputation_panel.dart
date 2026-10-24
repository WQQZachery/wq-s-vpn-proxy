// SPDX-License-Identifier: GPL-3.0-or-later
// IP 信誉（AbuseIPDB）展示。只展示接口实际返回的字段并用中文解释；不把分数换算成“安全/危险”结论，
// 也不与节点延迟、速度混为一谈。
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/reputation/ip_reputation.dart';

const _whatIsAbuseIpDb =
    'AbuseIPDB 是一个公开的 IP 滥用举报数据库：网站管理员发现某个 IP 发起攻击、扫描、垃圾邮件等行为时会提交举报，'
    'AbuseIPDB 汇总这些举报并给出“滥用置信度”。\n\n'
    '它能告诉你：当前出口 IP 是否被他人举报过、举报有多频繁。共享节点的 IP 往往被许多人使用，'
    '因此可能带有他人留下的举报记录，这会影响部分网站对你的风控判断（例如更多验证码）。\n\n'
    '它不能告诉你：节点快不快、稳不稳定，也不代表你的流量是否安全或隐私是否泄露。分数为 0 不等于“安全”，分数高也不代表“正在被攻击”。';

const _howToConfigure =
    '1. 在 abuseipdb.com 注册免费账号；\n'
    '2. 登录后进入 Account → API，创建一个 API Key；\n'
    '3. 回到本应用：设置 → API 配置 → AbuseIPDB API Key，粘贴保存。\n\n'
    '用途：仅用于向 api.abuseipdb.com 查询当前出口 IP 的举报记录。\n'
    '保存：Key 存放在系统安全存储（Android Keystore 加密）中，不写入普通数据库、日志或任何代码仓库，导出日志时也不会包含。\n'
    '额度：免费账号有每日查询次数限制（以 AbuseIPDB 官网为准）；同一 IP 30 分钟内的重复查询使用本地缓存，不消耗额度。';

class ReputationPanel extends StatelessWidget {
  const ReputationPanel({
    super.key,
    required this.ip,
    required this.report,
    required this.error,
    required this.hasKey,
    required this.loading,
    this.onRetry,
  });
  final String? ip;
  final ReputationReport? report;
  final ReputationException? error;
  final bool hasKey;
  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gaps.card, 12, Gaps.card, Gaps.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Flexible(
                flex: 3,
                child: Text(
                  'IP 信誉 · AbuseIPDB',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const InfoTip(title: 'AbuseIPDB 是什么', message: _whatIsAbuseIpDb),
              const Spacer(),
              if (report != null || error != null)
                Flexible(flex: 2, child: _statusPill()),
            ],
          ),
          const SizedBox(height: 8),
          SwapSwitcher(
            alignment: Alignment.topLeft,
            identity: (
                loading
                    ? 'loading'
                    : report != null
                    ? 'ok${report!.fetchedAt}'
                    : (error?.failure.name ?? (hasKey ? 'idle' : 'nokey'))),
            child: _body(context),
          ),
          const SizedBox(height: 12),
          _disclaimer(),
        ],
      ),
    );
  }

  Widget _statusPill() {
    if (report != null) {
      return StatusPill(
        report!.fromCache ? '查询成功 · 缓存' : '查询成功',
        color: kGood,
        icon: Icons.check_rounded,
      );
    }
    return StatusPill(
      switch (error!.failure) {
        ReputationFailure.noKey => '未配置 Key',
        ReputationFailure.quota => '额度受限',
        ReputationFailure.auth => 'Key 无效',
        ReputationFailure.network => '网络失败',
        ReputationFailure.http => '服务异常',
        ReputationFailure.data => '数据缺失',
      },
      color: error!.failure == ReputationFailure.noKey ? kWarn : kBad,
    );
  }

  Widget _body(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('正在查询 AbuseIPDB…'),
          ],
        ),
      );
    }
    final r = report;
    if (r != null) return _result(context, r);
    final e = error;
    if (e == null) {
      if (!hasKey) return _noKey(context);
      return Text(
        ip == null ? '点击上方“查询”，会先获取出口 IP，再查询它的信誉。' : '尚未查询该 IP 的信誉。',
        style: const TextStyle(color: AppColors.textTertiary, fontSize: 13),
      );
    }
    if (e.failure == ReputationFailure.noKey) return _noKey(context);
    final (title, hint) = switch (e.failure) {
      ReputationFailure.quota => (
        '查询额度已用尽或请求过于频繁',
        '免费账号有每日次数限制。请稍后再试（若服务返回了等待时间，已在下方显示）。',
      ),
      ReputationFailure.auth => (
        'API Key 无效或没有权限',
        '请在 设置 → API 配置 中检查 Key 是否完整、是否已被撤销。',
      ),
      ReputationFailure.network => (
        '网络请求失败',
        '无法连接 api.abuseipdb.com。请检查网络；VPN 开启时也可能是当前节点无法访问该服务。',
      ),
      ReputationFailure.http => ('AbuseIPDB 服务返回异常', '服务端暂时不可用，可稍后重试。'),
      ReputationFailure.data => (
        '返回数据缺失',
        '接口返回的数据不完整，无法给出信誉信息。没有数据时不会显示任何推测值。',
      ),
      ReputationFailure.noKey => ('', ''),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(color: kBad, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(hint, style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
        const SizedBox(height: 4),
        Text(
          '详情：${e.message}',
          style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
        ),
        if (onRetry != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: onRetry, child: const Text('重试')),
          ),
      ],
    );
  }

  Widget _noKey(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '需要你自己的 AbuseIPDB API Key 才能查询。',
        style: TextStyle(fontWeight: FontWeight.w500),
      ),
      const SizedBox(height: 6),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: const Text(
          _howToConfigure,
          style: TextStyle(fontSize: 12, height: 1.55, color: AppColors.textSecondary),
        ),
      ),
    ],
  );

  Widget _result(BuildContext context, ReputationReport r) {
    final score = r.abuseScore;
    final reports = r.totalReports;
    final color = score == null
        ? AppColors.idle
        : score == 0
        ? kGood
        : score < 25
        ? kWarn.withValues(alpha: 0.9)
        : score < 75
        ? kWarn
        : kBad;
    String yn(bool? b) => b == null ? '（未返回）' : (b ? '是' : '否');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _ScoreRing(score: score, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '滥用置信度',
                        style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
                      ),
                      const InfoTip(
                        title: 'Abuse Confidence Score（滥用置信度）',
                        message: '0–100 的分数，由 AbuseIPDB 根据近 90 天举报的数量、举报者可信度和时间远近计算，'
                            '表示“该 IP 存在滥用行为”的置信程度。\n\n'
                            '它是对举报记录的统计，不是对节点质量、速度或安全性的评价。共享 IP 常因他人行为而得分。',
                      ),
                    ],
                  ),
                  Text(
                    score == null ? '（未返回）' : abuseScoreBand(score),
                    style: TextStyle(fontWeight: FontWeight.w600, color: color),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    reports == null
                        ? '举报次数：（未返回）'
                        : reports == 0
                        ? '近 ${ReputationReport.maxAgeDays} 天内：无滥用举报记录'
                        : '近 ${ReputationReport.maxAgeDays} 天内：$reports 次举报，来自 ${r.distinctUsers ?? '?'} 个举报者',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        KvRow('查询的 IP', r.ip),
        KvRow(
          '最近一次举报',
          r.lastReportedAt == null
              ? (reports == 0 ? '无' : '（未返回）')
              : r.lastReportedAt!.toLocal().toString().substring(0, 16),
          info: 'AbuseIPDB 记录的最后一次被举报时间。',
        ),
        KvRow(
          '用途分类',
          r.usageType ?? '（未返回）',
          info: 'AbuseIPDB 对该 IP 的用途分类，例如 Data Center/Web Hosting/Transit（数据中心/托管）、Fixed Line ISP（家庭宽带）等。数据中心 IP 更容易被网站风控识别为代理。',
        ),
        KvRow('ISP / 域名', [r.isp, r.domain].whereType<String>().where((e) => e.isNotEmpty).join(' · ').ifEmpty('（未返回）')),
        KvRow('国家代码', r.countryCode ?? '（未返回）', info: 'AbuseIPDB 记录的国家代码，可能与其他 IP 库不同。'),
        KvRow('Tor 出口', yn(r.isTor), info: '该 IP 是否为已知的 Tor 网络出口节点。'),
        KvRow('白名单', yn(r.isWhitelisted), info: '是否在 AbuseIPDB 白名单中（通常为知名服务的 IP）。为“否”是常态，不代表有问题。'),
        KvRow(
          '数据时间',
          '${r.fetchedAt.toLocal().toString().substring(0, 19)}${r.fromCache ? '（30 分钟内的本地缓存）' : ''}',
        ),
        if (r.quotaRemaining != null)
          KvRow(
            '今日剩余额度',
            '${r.quotaRemaining}${r.quotaLimit != null ? ' / ${r.quotaLimit}' : ''} 次',
            info: '来自接口响应头 X-RateLimit-Remaining / X-RateLimit-Limit。缓存结果显示的是当时的值。',
          ),
      ],
    );
  }

  Widget _disclaimer() => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(Radii.sm),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 14, color: AppColors.textTertiary),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            '信誉分 ≠ 节点质量。它不反映节点延迟、下载/上传速度，也不能单独说明你的隐私或连接是否安全；请勿仅凭这一个分数判断 IP “一定安全”或“一定危险”。',
            style: TextStyle(fontSize: 11, height: 1.5, color: AppColors.textTertiary),
          ),
        ),
      ],
    ),
  );
}

class _ScoreRing extends StatelessWidget {
  const _ScoreRing({required this.score, required this.color});
  final int? score;
  final Color color;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 64,
    child: TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: (score ?? 0) / 100),
      duration: Motion.of(context, Motion.slow),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: score == null ? 0 : v.clamp(0.02, 1.0),
              strokeWidth: 6,
              backgroundColor: AppColors.surfaceHigh,
              color: color,
              strokeCap: StrokeCap.round,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                score == null ? '—' : '$score',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const Text('/100', style: TextStyle(fontSize: 9, color: AppColors.textMuted)),
            ],
          ),
        ],
      ),
    ),
  );
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
