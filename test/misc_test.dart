import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypilot_mobile/core/engine/traffic_meter.dart';
import 'package:proxypilot_mobile/core/engine/vpn_engine.dart';
import 'package:proxypilot_mobile/core/models/models.dart';
import 'package:proxypilot_mobile/core/networking/probes.dart';
import 'package:proxypilot_mobile/core/reputation/ip_reputation.dart';
import 'package:proxypilot_mobile/core/security/redact.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:proxypilot_mobile/core/storage/app_database.dart';

void main() {
  group('检测错误分类', () {
    test('各类异常', () {
      expect(classifyError(TimeoutException('t')), ProbeErrorKind.timeout);
      expect(
        classifyError(const SocketException('Failed host lookup: x')),
        ProbeErrorKind.dnsError,
      );
      expect(
        classifyError(
          const SocketException(
            'x',
            osError: OSError('Connection refused', 111),
          ),
        ),
        ProbeErrorKind.connectionRefused,
      );
      expect(
        classifyError(
          const SocketException(
            'x',
            osError: OSError('Network is unreachable', 101),
          ),
        ),
        ProbeErrorKind.networkUnreachable,
      );
      expect(
        classifyError(const HandshakeException('CERTIFICATE_VERIFY_FAILED')),
        ProbeErrorKind.certificateError,
      );
      expect(
        classifyError(const HandshakeException('WRONG_VERSION_NUMBER')),
        ProbeErrorKind.tlsError,
      );
      expect(
        classifyError(const HttpException('bad')),
        ProbeErrorKind.protocolError,
      );
      expect(classifyError(StateError('?')), ProbeErrorKind.unknown);
    });

    ProbeResult ok(int code, Map<String, String> headers, {String body = ''}) =>
        ProbeResult(
          kind: 'x',
          target: 't',
          method: 'm',
          status: ProbeStatus.success,
          timestamp: DateTime(2026),
          totalMs: 1,
          httpStatus: code,
          data: {'headers': headers, 'bodySnippet': body},
        );

    test('Cloudflare 结论区分挑战与可达', () {
      expect(
        cloudflareConclusion(
          ok(403, {'cf-mitigated': 'challenge', 'cf-ray': 'abc'}),
        ),
        contains('挑战'),
      );
      expect(
        cloudflareConclusion(ok(200, {'cf-ray': 'abc'})),
        contains('边缘可达'),
      );
      expect(cloudflareConclusion(ok(200, {})), contains('未见 Cloudflare'));
    });

    test('Claude 结论绝不宣称账户可用', () {
      for (final c in [200, 401, 403, 404, 500]) {
        final s = claudeConclusion(ok(c, {}));
        expect(s, anyOf(contains('未检测'), contains('未执行')));
        expect(s, isNot(contains('账户可用：是')));
      }
      expect(claudeConclusion(ok(401, {})), contains('服务有响应'));
    });
  });

  group('API 响应解析', () {
    test('ip.sb', () {
      final r = parseIpSb(
        '{"ip":"1.1.1.1","asn":13335,"asn_organization":"CLOUDFLARENET","isp":"Cloudflare","country":"Australia","city":"Sydney"}',
        DateTime(2026),
      );
      expect(r.ip, '1.1.1.1');
      expect(r.asn, 'AS13335');
      expect(r.org, 'CLOUDFLARENET');
    });
    test('ipinfo', () {
      final r = parseIpInfo(
        '{"ip":"8.8.8.8","org":"AS15169 Google LLC","country":"US","region":"California","city":"Mountain View"}',
        DateTime(2026),
      );
      expect(r.asn, 'AS15169');
      expect(r.org, 'Google LLC');
    });
    test('缺字段报错', () {
      expect(
        () => parseIpSb('{"country":"x"}', DateTime(2026)),
        throwsFormatException,
      );
    });
    test('AbuseIPDB 保留原始字段与定义', () {
      final r = parseAbuseIpDb(
        '{"data":{"ipAddress":"1.2.3.4","abuseConfidenceScore":0,"totalReports":3,"usageType":"Data Center/Web Hosting/Transit","isTor":false}}',
        DateTime(2026),
      );
      expect(
        r.fields.firstWhere((f) => f.key == 'abuseConfidenceScore').value,
        '0',
      );
      expect(
        r.fields.firstWhere((f) => f.key == 'numDistinctUsers').value,
        '（未返回）',
      );
      expect(r.fields.every((f) => f.definition.isNotEmpty), isTrue);
    });
    test('未配置 Key 时返回数据不可用而非编造', () async {
      await expectLater(
        IpReputationService().checkAbuseIpDb('1.2.3.4', ''),
        throwsA(
          isA<ReputationException>().having(
            (e) => e.kind,
            'kind',
            ProbeErrorKind.apiUnavailable,
          ),
        ),
      );
    });
  });

  group('流量统计', () {
    test('速度、峰值、累计', () {
      final m = TrafficMeter();
      expect(
        m.add(
          const TrafficSnapshot(timestampMs: 0, rxBytes: 1000, txBytes: 500),
        ),
        isNull,
      );
      final s1 = m.add(
        const TrafficSnapshot(
          timestampMs: 500,
          rxBytes: 1000 + 62500,
          txBytes: 500 + 6250,
        ),
      )!;
      expect(s1.downBps, 1000000);
      expect(s1.upBps, 100000);
      m.add(
        const TrafficSnapshot(
          timestampMs: 1000,
          rxBytes: 1000 + 62500 + 125000,
          txBytes: 6750,
        ),
      );
      expect(m.peakDownBps, 2000000);
      expect(m.sessionRxBytes, 187500);
      expect(m.sessionTxBytes, 6250);
    });
    test('计数器重置不产生负速度', () {
      final m = TrafficMeter()
        ..add(const TrafficSnapshot(timestampMs: 0, rxBytes: 100, txBytes: 100))
        ..add(
          const TrafficSnapshot(timestampMs: 500, rxBytes: 10, txBytes: 10),
        );
      expect(m.hasData, isFalse);
    });
    test('无数据时显示暂无数据', () {
      expect(formatBps(null), '暂无数据');
      expect(formatBps(1500000), '1.5 Mbps');
      expect(formatBytes(1536), '1.5 KB');
    });
  });

  group('日志脱敏', () {
    test('隐藏订阅 URL、链接、密码与 UUID', () {
      const raw =
          '更新 https://sub.example.com/api/v1/client/subscribe?token=abcdef123 '
          'link vless://b831381d-6324-4d53-ad4f-8cda48b30811@h.com:443 password=hunter2 "uuid":"b831381d-6324-4d53-ad4f-8cda48b30811" Authorization: Bearer xyz.abc';
      final r = redact(raw);
      expect(r, isNot(contains('token=abcdef123')));
      expect(r, isNot(contains('hunter2')));
      expect(r, isNot(contains('b831381d')));
      expect(r, isNot(contains('xyz.abc')));
      expect(r, contains('https://sub.example.com/…'));
    });
  });

  group('Flutter ↔ Kotlin 通道协议', () {
    test('事件解析', () {
      final s = VpnEngine.parseEvent({
        'type': 'state',
        'state': 'started',
        'message': null,
      })!;
      expect(s.state, VpnState.started);
      final t = VpnEngine.parseEvent({
        'type': 'traffic',
        'ts': 1,
        'rx': 2,
        'tx': 3,
      })!;
      expect(t.traffic!.rxBytes, 2);
      expect(VpnEngine.parseEvent('junk'), isNull);
      expect(VpnEngine.parseState('weird'), VpnState.stopped);
    });

    TestWidgetsFlutterBinding.ensureInitialized();
    test('MethodChannel 调用与错误传递（Mock 原生端，仅测 Dart 侧协议）', () async {
      const ch = MethodChannel('proxypilot/vpn');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (c) async {
            calls.add(c.method);
            if (c.method == 'checkConfig')
              return (c.arguments as Map)['config'] == 'bad'
                  ? 'parse error'
                  : null;
            if (c.method == 'prepare') return true;
            if (c.method == 'state') return {'state': 'stopped'};
            if (c.method == 'start')
              throw PlatformException(code: 'start_failed', message: 'x');
            return null;
          });
      final e = VpnEngine();
      expect(await e.checkConfig('bad'), 'parse error');
      expect(await e.checkConfig('{}'), isNull);
      expect(await e.prepare(), isTrue);
      expect((await e.currentState()).$1, VpnState.stopped);
      await expectLater(
        e.start(config: '{}', profileName: 'n'),
        throwsA(isA<PlatformException>()),
      );
      expect(calls, [
        'checkConfig',
        'checkConfig',
        'prepare',
        'state',
        'start',
      ]);
    });
  });

  group('并发限制', () {
    test('同时运行数不超过上限', () async {
      var running = 0, peak = 0;
      final r = await runLimited<int, int>(List.generate(20, (i) => i), 4, (
        i,
      ) async {
        running++;
        peak = running > peak ? running : peak;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        running--;
        return i * 2;
      });
      expect(peak, lessThanOrEqualTo(4));
      expect(r[19], 38);
    });
  });

  group('数据库读写（sqflite ffi + 内存安全存储）', () {
    test('节点凭据不落入 SQLite，订阅 URL 不落入 SQLite', () async {
      sqfliteFfiInit();
      final secrets = MemorySecretStore();
      final dir = await Directory.systemTemp.createTemp('ppdb');
      final db = await AppDatabase.open(
        secrets,
        factory: databaseFactoryFfi,
        path: '${dir.path}/t.db',
      );
      final n = ProxyNode(
        id: 'abcdef0123',
        name: 'n',
        protocol: ProxyProtocol.trojan,
        server: 'a.com',
        port: 443,
        secret: const {'password': 'TOPSECRET'},
        tls: const TlsOptions(enabled: true),
      );
      await db.upsertNode(n);
      await db.upsertSubscription(
        Subscription(
          id: 's1',
          name: 'sub',
          url: 'https://x.com/sub?token=SUBTOKEN',
        ),
      );
      final back = (await db.listNodes()).single;
      expect(back.secret['password'], 'TOPSECRET');
      expect((await db.listSubscriptions()).single.url, contains('SUBTOKEN'));
      await db.recordHealth('abcdef0123', latencyMs: 120, method: 'tcp');
      final h = await db.recordHealth(
        'abcdef0123',
        error: 'timeout',
        method: 'tcp',
      );
      expect(h.testCount, 2);
      expect(h.failureRate, 0.5);
      expect(h.lastSuccessAt, isNotNull);
      await db.addProbe(
        ProbeResult(
          kind: 'https',
          target: 't',
          method: 'm',
          status: ProbeStatus.failure,
          timestamp: DateTime.now(),
          totalMs: 5,
          errorKind: ProbeErrorKind.timeout,
          steps: const [ProbeStep(name: 'DNS 解析', ok: true, durationMs: 3)],
        ),
      );
      expect((await db.listProbes()).single.steps.single.name, 'DNS 解析');
      await db.close();
      final bytes = await File('${dir.path}/t.db').readAsBytes();
      final text = String.fromCharCodes(bytes);
      expect(text.contains('TOPSECRET'), isFalse);
      expect(text.contains('SUBTOKEN'), isFalse);
      await dir.delete(recursive: true);
    });
  });
}
