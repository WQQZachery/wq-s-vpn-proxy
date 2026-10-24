// SPDX-License-Identifier: GPL-3.0-or-later
// SQLite 存储：只保存非敏感字段；敏感凭据通过 [SecretStore]（Android Keystore 支持的安全存储）引用。

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/models.dart';

abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  SecureSecretStore() : _s = const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// 仅用于单元测试。
class MemorySecretStore implements SecretStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

class AppDatabase {
  AppDatabase(this._db, this._secrets);
  final Database _db;
  final SecretStore _secrets;

  static const schemaVersion = 1;

  static Future<AppDatabase> open(
    SecretStore secrets, {
    DatabaseFactory? factory,
    String? path,
  }) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), 'proxypilot.db');
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (db, v) async {
          await db.execute(
            '''CREATE TABLE nodes(
            id TEXT PRIMARY KEY, name TEXT NOT NULL, protocol TEXT NOT NULL, server TEXT NOT NULL,
            port INTEGER NOT NULL, options TEXT NOT NULL, tls TEXT NOT NULL, transport TEXT NOT NULL,
            enabled INTEGER NOT NULL, source TEXT NOT NULL, subscription_id TEXT, created_at INTEGER NOT NULL)''',
          );
          await db.execute(
            'CREATE INDEX idx_nodes_sub ON nodes(subscription_id)',
          );
          await db.execute(
            '''CREATE TABLE subscriptions(
            id TEXT PRIMARY KEY, name TEXT NOT NULL, updated_at INTEGER, node_count INTEGER, last_error TEXT)''',
          );
          await db.execute(
            '''CREATE TABLE node_health(
            node_id TEXT PRIMARY KEY, last_latency_ms INTEGER, last_test_at INTEGER, last_success_at INTEGER,
            test_count INTEGER NOT NULL DEFAULT 0, fail_count INTEGER NOT NULL DEFAULT 0, last_error TEXT, method TEXT)''',
          );
          await db.execute(
            '''CREATE TABLE probe_history(
            id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, target TEXT NOT NULL, method TEXT NOT NULL,
            status TEXT NOT NULL, ts INTEGER NOT NULL, total_ms INTEGER NOT NULL, error_kind TEXT NOT NULL,
            error_message TEXT, http_status INTEGER, steps TEXT NOT NULL, data TEXT NOT NULL, conclusion TEXT)''',
          );
          await db.execute(
            'CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT NOT NULL)',
          );
        },
      ),
    );
    return AppDatabase(db, secrets);
  }

  Future<void> close() => _db.close();

  String _nodeKey(String id) => 'node.$id';
  String _subKey(String id) => 'sub.$id';

  // ---------- 节点 ----------
  Future<List<ProxyNode>> listNodes() async {
    final rows = await _db.query('nodes', orderBy: 'created_at ASC');
    final out = <ProxyNode>[];
    for (final r in rows) {
      final raw = await _secrets.read(_nodeKey(r['id'] as String));
      final secret = raw == null
          ? <String, String>{}
          : (jsonDecode(raw) as Map).cast<String, String>();
      out.add(ProxyNode.fromDbRow(r, secret));
    }
    return out;
  }

  Future<void> upsertNode(ProxyNode n) async {
    await _secrets.write(_nodeKey(n.id), jsonEncode(n.secret));
    await _db.insert(
      'nodes',
      n.toDbRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteNode(String id) async {
    await _db.delete('nodes', where: 'id = ?', whereArgs: [id]);
    await _db.delete('node_health', where: 'node_id = ?', whereArgs: [id]);
    await _secrets.delete(_nodeKey(id));
  }

  /// 用订阅最新结果替换该订阅下的节点（事务内完成）。
  Future<void> replaceSubscriptionNodes(
    String subId,
    List<ProxyNode> nodes,
  ) async {
    final old = await _db.query(
      'nodes',
      columns: ['id'],
      where: 'subscription_id = ?',
      whereArgs: [subId],
    );
    for (final r in old) {
      await _secrets.delete(_nodeKey(r['id'] as String));
    }
    for (final n in nodes) {
      await _secrets.write(_nodeKey(n.id), jsonEncode(n.secret));
    }
    await _db.transaction((txn) async {
      for (final r in old) {
        await txn.delete(
          'node_health',
          where: 'node_id = ?',
          whereArgs: [r['id']],
        );
      }
      await txn.delete(
        'nodes',
        where: 'subscription_id = ?',
        whereArgs: [subId],
      );
      for (final n in nodes) {
        await txn.insert('nodes', n.toDbRow());
      }
    });
  }

  // ---------- 订阅 ----------
  Future<List<Subscription>> listSubscriptions() async {
    final rows = await _db.query('subscriptions');
    return [
      for (final r in rows)
        Subscription.fromDbRow(
          r,
          await _secrets.read(_subKey(r['id'] as String)) ?? '',
        ),
    ];
  }

  Future<void> upsertSubscription(Subscription s) async {
    await _secrets.write(_subKey(s.id), s.url);
    await _db.insert(
      'subscriptions',
      s.toDbRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteSubscription(String id) async {
    await replaceSubscriptionNodes(id, const []);
    await _db.delete('subscriptions', where: 'id = ?', whereArgs: [id]);
    await _secrets.delete(_subKey(id));
  }

  // ---------- 节点健康 ----------
  Future<Map<String, NodeHealth>> listHealth() async {
    final rows = await _db.query('node_health');
    DateTime? dt(Object? v) =>
        v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
    return {
      for (final r in rows)
        r['node_id'] as String: NodeHealth(
          nodeId: r['node_id'] as String,
          lastLatencyMs: r['last_latency_ms'] as int?,
          lastTestAt: dt(r['last_test_at']),
          lastSuccessAt: dt(r['last_success_at']),
          testCount: r['test_count'] as int,
          failCount: r['fail_count'] as int,
          lastError: r['last_error'] as String?,
          method: r['method'] as String?,
        ),
    };
  }

  Future<NodeHealth> recordHealth(
    String nodeId, {
    int? latencyMs,
    String? error,
    required String method,
  }) async {
    final now = DateTime.now();
    final prev = (await listHealth())[nodeId];
    final h = NodeHealth(
      nodeId: nodeId,
      lastLatencyMs: error == null ? latencyMs : null,
      lastTestAt: now,
      lastSuccessAt: error == null ? now : prev?.lastSuccessAt,
      testCount: (prev?.testCount ?? 0) + 1,
      failCount: (prev?.failCount ?? 0) + (error == null ? 0 : 1),
      lastError: error,
      method: method,
    );
    await _db.insert('node_health', {
      'node_id': nodeId,
      'last_latency_ms': h.lastLatencyMs,
      'last_test_at': now.millisecondsSinceEpoch,
      'last_success_at': h.lastSuccessAt?.millisecondsSinceEpoch,
      'test_count': h.testCount,
      'fail_count': h.failCount,
      'last_error': error,
      'method': method,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return h;
  }

  // ---------- 检测历史 ----------
  Future<void> addProbe(ProbeResult r) async {
    await _db.insert('probe_history', {
      'kind': r.kind,
      'target': r.target,
      'method': r.method,
      'status': r.status.name,
      'ts': r.timestamp.millisecondsSinceEpoch,
      'total_ms': r.totalMs,
      'error_kind': r.errorKind.name,
      'error_message': r.errorMessage,
      'http_status': r.httpStatus,
      'steps': jsonEncode(r.steps.map((s) => s.toJson()).toList()),
      'data': jsonEncode(r.data),
      'conclusion': r.conclusion,
    });
  }

  Future<List<ProbeResult>> listProbes({int limit = 100}) async {
    final rows = await _db.query(
      'probe_history',
      orderBy: 'ts DESC',
      limit: limit,
    );
    return [
      for (final r in rows)
        ProbeResult(
          kind: r['kind'] as String,
          target: r['target'] as String,
          method: r['method'] as String,
          status: ProbeStatus.values.byName(r['status'] as String),
          timestamp: DateTime.fromMillisecondsSinceEpoch(r['ts'] as int),
          totalMs: r['total_ms'] as int,
          errorKind: ProbeErrorKind.values.byName(r['error_kind'] as String),
          errorMessage: r['error_message'] as String?,
          httpStatus: r['http_status'] as int?,
          steps: ((jsonDecode(r['steps'] as String) as List).cast<Map>())
              .map((m) => ProbeStep.fromJson(m.cast<String, dynamic>()))
              .toList(),
          data: (jsonDecode(r['data'] as String) as Map)
              .cast<String, dynamic>(),
          conclusion: r['conclusion'] as String?,
        ),
    ];
  }

  /// 按保留天数清理检测历史。
  Future<int> pruneProbes(Duration keep) => _db.delete(
    'probe_history',
    where: 'ts < ?',
    whereArgs: [DateTime.now().subtract(keep).millisecondsSinceEpoch],
  );

  Future<void> clearProbes() => _db.delete('probe_history');

  // ---------- KV 设置 ----------
  Future<String?> getKv(String k) async {
    final r = await _db.query('kv', where: 'k = ?', whereArgs: [k]);
    return r.isEmpty ? null : r.first['v'] as String;
  }

  Future<void> setKv(String k, String v) => _db.insert('kv', {
    'k': k,
    'v': v,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  /// API Key 等敏感设置放安全存储。
  Future<String?> getSecretSetting(String k) => _secrets.read('setting.$k');
  Future<void> setSecretSetting(String k, String v) => v.isEmpty
      ? _secrets.delete('setting.$k')
      : _secrets.write('setting.$k', v);
}
