// SPDX-License-Identifier: GPL-3.0-or-later
// 主动测速引擎：真实数据传输测量延迟、下载、上传。所有数值来自实测；拿不到的信息（如服务器负载、丢包率）
// 一律标注“不可用”，不编造。
//
// 测试服务器来源：
//   1. M-Lab（Measurement Lab）ndt7 —— 开放的互联网测量平台，有公开的使用条款与隐私政策，
//      通过官方定位服务 locate.measurementlab.net 返回附近的若干台服务器（含所在城市/国家，真实字段）。
//      注意：M-Lab 会公开发布测量数据（含客户端 IP），界面中已向用户说明。
//   2. Cloudflare（speed.cloudflare.com 使用的 __down / __up 端点）—— 任播网络，没有固定“位置”；
//      仅能从响应头 colo 得知本次命中的数据中心代码。该端点未单独发布 API 条款，作为备选。
//
// 服务器选择：对所有候选做轻量级 HTTP 往返延迟探测（keep-alive，排除首个含握手的请求），
// 选中位延迟最低且可达者。不使用地理距离作为质量依据。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'throughput.dart';

enum SpeedPhase {
  idle,
  preparing,
  selecting,
  latency,
  download,
  upload,
  done,
  failed,
  cancelled,
}

extension SpeedPhaseX on SpeedPhase {
  String get label => switch (this) {
    SpeedPhase.idle => '准备就绪',
    SpeedPhase.preparing => '准备中',
    SpeedPhase.selecting => '寻找测试服务器',
    SpeedPhase.latency => '测量延迟',
    SpeedPhase.download => '下载测速',
    SpeedPhase.upload => '上传测速',
    SpeedPhase.done => '完成',
    SpeedPhase.failed => '测试失败',
    SpeedPhase.cancelled => '已取消',
  };
}

enum SpeedProvider { mlab, cloudflare }

class SpeedServer {
  SpeedServer({
    required this.provider,
    required this.id,
    required this.name,
    required this.host,
    this.location,
    this.downloadUrl,
    this.uploadUrl,
  });
  final SpeedProvider provider;
  final String id;
  final String name;
  final String host;

  /// 真实可得的位置描述；拿不到时为 null（界面显示“位置未知”）。
  String? location;
  final String? downloadUrl; // ndt7 wss 地址（含一次性令牌）
  final String? uploadUrl;

  String get providerLabel => switch (provider) {
    SpeedProvider.mlab => 'M-Lab ndt7',
    SpeedProvider.cloudflare => 'Cloudflare',
  };
}

class ServerCandidate {
  ServerCandidate(this.server, {this.latency, this.error});
  final SpeedServer server;
  final LatencyStats? latency;
  final String? error;
  bool get reachable => latency != null;
}

class SpeedSample {
  const SpeedSample(this.tMs, this.bps);
  final int tMs;
  final double bps;
}

/// 推送给 UI 的进度快照。raw 字段均为真实测量值。
class SpeedProgress {
  const SpeedProgress({
    required this.phase,
    this.server,
    this.candidates = const [],
    this.rawBps = 0,
    this.phaseProgress = 0,
    this.latency,
    this.downloadBps,
    this.uploadBps,
    this.downloadBytes = 0,
    this.uploadBytes = 0,
    this.downloadSamples = const [],
    this.uploadSamples = const [],
    this.message,
    this.startedAt,
    this.downloadWarm = true,
    this.uploadWarm = true,
  });
  final SpeedPhase phase;
  final SpeedServer? server;
  final List<ServerCandidate> candidates;
  final double rawBps; // 当前阶段的瞬时真实速度
  final double phaseProgress; // 0..1（按时间）
  final LatencyStats? latency;
  final double? downloadBps; // 最终结果（排除预热）
  final double? uploadBps;
  final int downloadBytes;
  final int uploadBytes;
  final List<SpeedSample> downloadSamples;
  final List<SpeedSample> uploadSamples;
  final String? message;
  final DateTime? startedAt;
  final bool downloadWarm;
  final bool uploadWarm;

  SpeedProgress copyWith({
    SpeedPhase? phase,
    SpeedServer? server,
    List<ServerCandidate>? candidates,
    double? rawBps,
    double? phaseProgress,
    LatencyStats? latency,
    double? downloadBps,
    double? uploadBps,
    int? downloadBytes,
    int? uploadBytes,
    List<SpeedSample>? downloadSamples,
    List<SpeedSample>? uploadSamples,
    String? message,
    DateTime? startedAt,
    bool? downloadWarm,
    bool? uploadWarm,
  }) => SpeedProgress(
    phase: phase ?? this.phase,
    server: server ?? this.server,
    candidates: candidates ?? this.candidates,
    rawBps: rawBps ?? this.rawBps,
    phaseProgress: phaseProgress ?? this.phaseProgress,
    latency: latency ?? this.latency,
    downloadBps: downloadBps ?? this.downloadBps,
    uploadBps: uploadBps ?? this.uploadBps,
    downloadBytes: downloadBytes ?? this.downloadBytes,
    uploadBytes: uploadBytes ?? this.uploadBytes,
    downloadSamples: downloadSamples ?? this.downloadSamples,
    uploadSamples: uploadSamples ?? this.uploadSamples,
    message: message ?? this.message,
    startedAt: startedAt ?? this.startedAt,
    downloadWarm: downloadWarm ?? this.downloadWarm,
    uploadWarm: uploadWarm ?? this.uploadWarm,
  );
}

class SpeedTestCancelled implements Exception {
  const SpeedTestCancelled();
}

class SpeedTestException implements Exception {
  SpeedTestException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SpeedTestConfig {
  const SpeedTestConfig({
    this.phaseDuration = const Duration(seconds: 10),
    this.warmup = const Duration(seconds: 2),
    this.streams = 4,
    this.latencySamples = 20,
    this.probeSamples = 5,
    this.connectTimeout = const Duration(seconds: 8),
    this.stallTimeout = const Duration(seconds: 6),
    this.sampleInterval = const Duration(milliseconds: 200),
  });
  final Duration phaseDuration;
  final Duration warmup;
  final int streams;
  final int latencySamples;
  final int probeSamples;
  final Duration connectTimeout;

  /// 连续这么久没有任何数据即判定为中断。
  final Duration stallTimeout;
  final Duration sampleInterval;
}

const _ndtProtocol = 'net.measurementlab.ndt.v7';
const _userAgent = 'WQsProxyVPN/1.1.1 speedtest';

/// 一次测速会话。调用 [run] 开始，[cancel] 取消；进度通过 [progress] 推送。
class SpeedTestSession {
  SpeedTestSession({
    this.config = const SpeedTestConfig(),
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final SpeedTestConfig config;
  final HttpClient Function() _clientFactory;
  final _ctrl = StreamController<SpeedProgress>.broadcast();
  final List<HttpClient> _clients = [];
  final List<WebSocket> _sockets = [];
  bool _cancelled = false;
  SpeedProgress _p = const SpeedProgress(phase: SpeedPhase.idle);

  Stream<SpeedProgress> get progress => _ctrl.stream;
  SpeedProgress get current => _p;

  void _emit(SpeedProgress p) {
    _p = p;
    if (!_ctrl.isClosed) _ctrl.add(p);
  }

  void _check() {
    if (_cancelled) throw const SpeedTestCancelled();
  }

  HttpClient _client() {
    final c = _clientFactory()
      ..connectionTimeout = config.connectTimeout
      ..idleTimeout = const Duration(seconds: 15)
      ..userAgent = _userAgent;
    _clients.add(c);
    return c;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _closeAll();
  }

  void _closeAll() {
    for (final c in _clients) {
      c.close(force: true);
    }
    _clients.clear();
    for (final s in _sockets) {
      s.close();
    }
    _sockets.clear();
  }

  Future<void> dispose() async {
    cancel();
    await _ctrl.close();
  }

  // ---------------- 服务器发现与选择 ----------------

  /// 获取候选：M-Lab 定位服务（最多 4 台）+ Cloudflare 任播。
  Future<List<SpeedServer>> discover() async {
    final out = <SpeedServer>[];
    try {
      out.addAll(await _locateMlab());
    } catch (_) {
      // M-Lab 不可达时仍可用 Cloudflare
    }
    out.add(
      SpeedServer(
        provider: SpeedProvider.cloudflare,
        id: 'cloudflare',
        name: 'Cloudflare 任播网络',
        host: 'speed.cloudflare.com',
      ),
    );
    return out;
  }

  Future<List<SpeedServer>> _locateMlab() async {
    final c = _client();
    final req = await c
        .getUrl(Uri.parse('https://locate.measurementlab.net/v2/nearest/ndt/ndt7'))
        .timeout(config.connectTimeout);
    final resp = await req.close().timeout(config.connectTimeout);
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw SpeedTestException('M-Lab 定位服务 HTTP ${resp.statusCode}');
    }
    return parseMlabLocate(body);
  }

  /// 对每个候选做轻量延迟探测（并发），返回带结果的候选列表（按延迟排序，不可达在后）。
  Future<List<ServerCandidate>> probeCandidates(List<SpeedServer> servers) async {
    final res = await Future.wait(
      servers.map((s) async {
        try {
          final st = await _httpRtt(s, config.probeSamples);
          if (st == null) return ServerCandidate(s, error: '无响应');
          return ServerCandidate(s, latency: st);
        } on SpeedTestCancelled {
          rethrow;
        } catch (e) {
          return ServerCandidate(s, error: _short(e));
        }
      }),
    );
    res.sort((a, b) {
      if (a.reachable != b.reachable) return a.reachable ? -1 : 1;
      if (!a.reachable) return 0;
      return selectionScore(a).compareTo(selectionScore(b));
    });
    return res;
  }

  /// HTTP 往返延迟：同一 keep-alive 连接上连续请求，首个请求（含 DNS/TCP/TLS 握手）不计入。
  /// Cloudflare 会在 Server-Timing 中给出服务端处理耗时，予以扣除；M-Lab 请求 “/” 的处理耗时可忽略。
  Future<LatencyStats?> _httpRtt(
    SpeedServer s,
    int n, {
    void Function(List<double>)? onSample,
  }) async {
    final c = _client()..maxConnectionsPerHost = 1;
    final uri = s.provider == SpeedProvider.cloudflare
        ? Uri.https(s.host, '/__down', {'bytes': '0'})
        : Uri.https(s.host, '/');
    final samples = <double>[];
    var attempts = 0;
    try {
      for (var i = 0; i <= n; i++) {
        _check();
        final sw = Stopwatch()..start();
        try {
          final req = await c.getUrl(uri).timeout(config.connectTimeout);
          req.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
          final resp = await req.close().timeout(config.connectTimeout);
          await resp.drain<void>().timeout(config.connectTimeout);
          final ms = sw.elapsedMicroseconds / 1000.0;
          if (resp.statusCode >= 400) {
            throw SpeedTestException('服务器返回 HTTP ${resp.statusCode}');
          }
          if (s.provider == SpeedProvider.cloudflare) {
            final colo = resp.headers.value('colo');
            if (colo != null && colo.isNotEmpty) {
              s.location = '数据中心 $colo（任播，按 IATA 代码）';
            }
          }
          if (i == 0) continue; // 预热（建连）
          attempts++;
          final server = serverProcessingMs(resp.headers['server-timing']);
          samples.add(math.max(0.1, ms - server));
          onSample?.call(samples);
        } on SpeedTestCancelled {
          rethrow;
        } catch (e) {
          if (_cancelled) throw const SpeedTestCancelled();
          if (i == 0) rethrow; // 连不上
          attempts++;
        }
      }
    } finally {
      c.close(force: true);
      _clients.remove(c);
    }
    return LatencyStats.of(samples, attempts);
  }

  // ---------------- 主流程 ----------------

  /// 运行完整测试。[preferred] 为用户手动选择的服务器（null 表示自动选择）。
  Future<SpeedProgress> run({
    SpeedServer? preferred,
    List<ServerCandidate>? knownCandidates,
  }) async {
    final started = DateTime.now();
    try {
      _emit(SpeedProgress(phase: SpeedPhase.preparing, startedAt: started));
      _check();

      // 1. 选服务器
      _emit(_p.copyWith(phase: SpeedPhase.selecting));
      var candidates = knownCandidates;
      SpeedServer server;
      if (preferred != null) {
        server = preferred;
      } else {
        candidates ??= await probeCandidates(await discover());
        _check();
        final best = candidates.where((c) => c.reachable).firstOrNull;
        if (best == null) {
          throw SpeedTestException('没有可达的测试服务器（${candidates.map((c) => '${c.server.name}：${c.error}').join('；')}）');
        }
        server = best.server;
      }
      _emit(_p.copyWith(server: server, candidates: candidates ?? const []));

      // 2. 延迟与抖动
      _emit(_p.copyWith(phase: SpeedPhase.latency, phaseProgress: 0));
      final lat = await _httpRtt(
        server,
        config.latencySamples,
        onSample: (s) => _emit(
          _p.copyWith(
            latency: LatencyStats.of(s, s.length),
            phaseProgress: s.length / config.latencySamples,
          ),
        ),
      );
      if (lat == null) throw SpeedTestException('延迟测量失败：服务器无响应');
      _emit(_p.copyWith(latency: lat, phaseProgress: 1));

      // 3. 下载
      _emit(_p.copyWith(phase: SpeedPhase.download, phaseProgress: 0, rawBps: 0));
      final down = server.provider == SpeedProvider.mlab
          ? await _ndtDownload(server)
          : await _cfDownload(server);
      _emit(
        _p.copyWith(
          downloadBps: down.resultBps(),
          downloadBytes: down.totalBytes,
          downloadWarm: down.warmedUp,
          rawBps: 0,
        ),
      );

      // 4. 上传
      _emit(_p.copyWith(phase: SpeedPhase.upload, phaseProgress: 0, rawBps: 0));
      final up = server.provider == SpeedProvider.mlab
          ? await _ndtUpload(server)
          : await _cfUpload(server);
      _emit(
        _p.copyWith(
          uploadBps: up.resultBps(),
          uploadBytes: up.totalBytes,
          uploadWarm: up.warmedUp,
          rawBps: 0,
        ),
      );
      _emit(_p.copyWith(phase: SpeedPhase.done, phaseProgress: 1));
    } on SpeedTestCancelled {
      _emit(_p.copyWith(phase: SpeedPhase.cancelled, rawBps: 0, message: '测试已取消'));
    } catch (e) {
      if (_cancelled) {
        _emit(_p.copyWith(phase: SpeedPhase.cancelled, rawBps: 0, message: '测试已取消'));
      } else {
        _emit(_p.copyWith(phase: SpeedPhase.failed, rawBps: 0, message: _short(e)));
      }
    } finally {
      _closeAll();
    }
    return _p;
  }

  /// 按固定节奏采样 meter，推送瞬时速度与时间进度；检测停顿与总时长。
  Future<void> _sampleLoop(
    ThroughputMeter meter,
    Stopwatch sw,
    bool upload,
    Future<void> done,
  ) async {
    final samples = <SpeedSample>[];
    var lastBytes = 0;
    var lastChange = 0;
    var finished = false;
    unawaited(
      done.then<void>((_) {}, onError: (Object _) {}).whenComplete(
        () => finished = true,
      ),
    );
    final total = config.phaseDuration.inMilliseconds;
    while (!finished && !_cancelled) {
      await Future<void>.delayed(config.sampleInterval);
      final t = sw.elapsedMilliseconds;
      meter.record(t);
      if (meter.totalBytes != lastBytes) {
        lastBytes = meter.totalBytes;
        lastChange = t;
      } else if (t - lastChange > config.stallTimeout.inMilliseconds) {
        throw SpeedTestException(
          meter.totalBytes == 0 ? '连接后未收到任何数据（可能被拦截或服务器繁忙）' : '数据传输中断超过 ${config.stallTimeout.inSeconds} 秒',
        );
      }
      final bps = meter.instantBps();
      samples.add(SpeedSample(t, bps));
      if (samples.length > 120) samples.removeAt(0);
      _emit(
        _p.copyWith(
          rawBps: bps,
          phaseProgress: math.min(1, t / total),
          downloadSamples: upload ? null : List.unmodifiable(samples),
          uploadSamples: upload ? List.unmodifiable(samples) : null,
          downloadBytes: upload ? null : meter.totalBytes,
          uploadBytes: upload ? meter.totalBytes : null,
        ),
      );
    }
  }

  ThroughputMeter _meter() => ThroughputMeter(
    warmupMs: config.warmup.inMilliseconds,
    limitMs: config.phaseDuration.inMilliseconds,
  );

  // ---------------- Cloudflare ----------------

  Future<ThroughputMeter> _cfDownload(SpeedServer s) async {
    final meter = _meter();
    final sw = Stopwatch()..start();
    final deadline = config.phaseDuration;
    Future<void> stream() async {
      final c = _client();
      while (sw.elapsed < deadline && !_cancelled) {
        final req = await c
            .getUrl(Uri.https(s.host, '/__down', {'bytes': '${25 * 1000 * 1000}'}))
            .timeout(config.connectTimeout);
        final resp = await req.close().timeout(config.connectTimeout);
        if (resp.statusCode != 200) {
          throw SpeedTestException('下载端点返回 HTTP ${resp.statusCode}${resp.statusCode == 429 ? '（请求过于频繁，被限流）' : ''}');
        }
        await for (final chunk in resp) {
          meter.add(sw.elapsedMilliseconds, chunk.length);
          if (sw.elapsed >= deadline || _cancelled) break;
        }
      }
    }

    await _runStreams(meter, sw, false, stream);
    return meter;
  }

  Future<ThroughputMeter> _cfUpload(SpeedServer s) async {
    final meter = _meter();
    final sw = Stopwatch()..start();
    final deadline = config.phaseDuration;
    // 复用同一块随机数据（不可压缩），避免每次请求分配内存
    final rnd = math.Random();
    final pool = Uint8List(8 * 1024 * 1024);
    for (var i = 0; i < pool.length; i += 4) {
      final v = rnd.nextInt(1 << 32);
      pool[i] = v & 0xff;
      pool[i + 1] = (v >> 8) & 0xff;
      pool[i + 2] = (v >> 16) & 0xff;
      pool[i + 3] = (v >> 24) & 0xff;
    }
    Future<void> stream() async {
      final c = _client();
      var size = 256 * 1024;
      while (sw.elapsed < deadline && !_cancelled) {
        final t0 = sw.elapsedMilliseconds;
        final req = await c
            .postUrl(Uri.https(s.host, '/__up'))
            .timeout(config.connectTimeout);
        req.contentLength = size;
        req.headers.contentType = ContentType.binary;
        req.add(Uint8List.sublistView(pool, 0, size));
        final resp = await req.close().timeout(
          deadline + config.stallTimeout,
        );
        await resp.drain<void>();
        if (resp.statusCode != 200) {
          throw SpeedTestException('上传端点返回 HTTP ${resp.statusCode}${resp.statusCode == 429 ? '（请求过于频繁，被限流）' : ''}');
        }
        // 只在服务器确认收到整个请求体后才计入字节（不按本地写缓冲计数，避免高估）
        meter.add(sw.elapsedMilliseconds, size);
        final took = sw.elapsedMilliseconds - t0;
        if (took < 800 && size < pool.length) size = math.min(size * 2, pool.length);
      }
    }

    await _runStreams(meter, sw, true, stream);
    return meter;
  }

  Future<void> _runStreams(
    ThroughputMeter meter,
    Stopwatch sw,
    bool upload,
    Future<void> Function() stream,
  ) async {
    final before = _clients.length;
    final work = Future.wait(
      List.generate(config.streams, (_) => stream()),
      eagerError: true,
    );
    final done = Completer<void>();
    unawaited(work.then((_) {
      if (!done.isCompleted) done.complete();
    }, onError: (Object e) {
      if (!done.isCompleted) done.completeError(e);
    }));
    // 到时后最多再等 1.5 秒让请求收尾，然后强制关闭本阶段连接，避免拖慢下一阶段
    final grace = Timer(config.phaseDuration + const Duration(milliseconds: 1500), () {
      if (!done.isCompleted) done.complete();
    });
    try {
      await Future.wait([_sampleLoop(meter, sw, upload, done.future), done.future], eagerError: true);
    } finally {
      grace.cancel();
      final phaseClients = _clients.sublist(before);
      for (final c in phaseClients) {
        c.close(force: true);
        _clients.remove(c);
      }
    }
    meter.record(sw.elapsedMilliseconds);
    _check();
  }

  // ---------------- M-Lab ndt7 ----------------

  Future<WebSocket> _ws(String url) async {
    final c = _client();
    final ws = await WebSocket.connect(
      url,
      protocols: const [_ndtProtocol],
      customClient: c,
    ).timeout(config.connectTimeout);
    _sockets.add(ws);
    return ws;
  }

  Future<ThroughputMeter> _ndtDownload(SpeedServer s) async {
    final url = s.downloadUrl;
    if (url == null) throw SpeedTestException('服务器缺少下载地址');
    final meter = _meter();
    final ws = await _ws(url);
    final sw = Stopwatch()..start();
    final done = Completer<void>();
    final sub = ws.listen(
      (m) {
        if (m is List<int>) meter.add(sw.elapsedMilliseconds, m.length);
        // 文本消息是服务器的测量报告，这里不需要
        if (sw.elapsed >= config.phaseDuration + const Duration(seconds: 1)) {
          ws.close();
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      cancelOnError: true,
    );
    try {
      await Future.wait([_sampleLoop(meter, sw, false, done.future), done.future], eagerError: true);
    } finally {
      await sub.cancel();
      unawaited(ws.close());
    }
    meter.record(sw.elapsedMilliseconds);
    _check();
    if (meter.totalBytes == 0) throw SpeedTestException('下载未收到数据');
    return meter;
  }

  Future<ThroughputMeter> _ndtUpload(SpeedServer s) async {
    final url = s.uploadUrl;
    if (url == null) throw SpeedTestException('服务器缺少上传地址');
    // 上传字节以服务器测量报告中的 TCPInfo.BytesReceived 为准（服务器实际收到的量），
    // 而不是本地写入量；本地只用于限制在途数据，避免无限排队占用内存。
    final meter = _meter();
    final ws = await _ws(url);
    final sw = Stopwatch()..start();
    var serverReceived = 0;
    var sent = 0;
    final done = Completer<void>();
    final sub = ws.listen(
      (m) {
        if (m is String) {
          final r = parseNdtBytesReceived(m);
          if (r != null && r > serverReceived) {
            meter.add(sw.elapsedMilliseconds, r - serverReceived);
            serverReceived = r;
          }
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      cancelOnError: true,
    );
    final rnd = math.Random();
    var msg = Uint8List(1 << 13);
    void fill(Uint8List b) {
      for (var i = 0; i < b.length; i++) {
        b[i] = rnd.nextInt(256);
      }
    }

    fill(msg);
    const maxInFlight = 4 * 1024 * 1024;
    Future<void> sender() async {
      while (!done.isCompleted && !_cancelled && sw.elapsed < config.phaseDuration) {
        if (sent - serverReceived > maxInFlight) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          continue;
        }
        ws.add(msg);
        sent += msg.length;
        // ndt7 规范：消息大小随已发送量增长，最大 1 MiB
        if (msg.length < (1 << 20) && sent >= 16 * msg.length) {
          msg = Uint8List(msg.length * 2);
          fill(msg);
        }
        await Future<void>.delayed(Duration.zero);
      }
      await ws.close(WebSocketStatus.normalClosure);
    }

    try {
      await Future.wait(
        [sender(), _sampleLoop(meter, sw, true, done.future), done.future],
        eagerError: true,
      );
    } finally {
      await sub.cancel();
      unawaited(ws.close());
    }
    meter.record(sw.elapsedMilliseconds);
    _check();
    if (meter.totalBytes == 0) throw SpeedTestException('上传未得到服务器确认的数据量');
    return meter;
  }
}

// ---------------- 解析工具（可单测） ----------------

/// 服务器选择评分（越低越好）：以实测中位延迟为主，加上丢失探测的惩罚。
/// Cloudflare 端点会对频繁的大流量请求返回 HTTP 429 限流（开发中已实际遇到），测量稳定性不如专用测量平台，
/// 因此对其延迟乘以 1.25 的系数——只有明显更快时才会被自动选中。不使用地理距离。
double selectionScore(ServerCandidate c) {
  final l = c.latency;
  if (l == null) return double.infinity;
  var score = l.medianMs + l.jitterMs * 0.5 + l.failures * 50;
  if (c.server.provider == SpeedProvider.cloudflare) score *= 1.25;
  return score;
}

List<SpeedServer> parseMlabLocate(String body) {
  final j = jsonDecode(body);
  final results = (j is Map ? j['results'] : null) as List?;
  if (results == null || results.isEmpty) {
    throw SpeedTestException('M-Lab 定位服务未返回服务器');
  }
  final out = <SpeedServer>[];
  for (final r in results.whereType<Map>()) {
    final host = (r['hostname'] ?? r['machine']) as String?;
    final urls = (r['urls'] as Map?)?.cast<String, dynamic>();
    final down = urls?['wss:///ndt/v7/download'] as String?;
    final up = urls?['wss:///ndt/v7/upload'] as String?;
    if (host == null || down == null || up == null) continue;
    final loc = (r['location'] as Map?)?.cast<String, dynamic>();
    final city = loc?['city'] as String?;
    final country = loc?['country'] as String?;
    final where = [city, country].whereType<String>().where((e) => e.isNotEmpty).join(', ');
    out.add(
      SpeedServer(
        provider: SpeedProvider.mlab,
        id: host,
        name: 'M-Lab ${_siteCode(host)}',
        host: host,
        location: where.isEmpty ? null : where,
        downloadUrl: down,
        uploadUrl: up,
      ),
    );
  }
  if (out.isEmpty) throw SpeedTestException('M-Lab 返回的数据缺少必要字段');
  return out;
}

String _siteCode(String host) {
  // ndt-mlab1-pdx01.mlab-oti... → pdx01；autojoin 主机 → 取第二段
  final first = host.split('.').first;
  final parts = first.split('-');
  if (parts.length >= 3 && parts[1].startsWith('mlab')) return parts[2];
  return parts.length >= 2 ? parts[1] : first;
}

/// 从 Server-Timing 头中取服务端处理耗时（ms）。只认 Cloudflare 测速端点使用的
/// cfRequestDuration；其它条目（如 cfL4 的 RTT 统计）不是处理时间，不扣除。
double serverProcessingMs(List<String>? headers) {
  if (headers == null) return 0;
  for (final h in headers) {
    for (final part in h.split(',')) {
      final p = part.trim();
      if (p.startsWith('cfRequestDuration')) {
        final m = RegExp(r'dur=([0-9.]+)').firstMatch(p);
        if (m != null) return double.tryParse(m.group(1)!) ?? 0;
      }
    }
  }
  return 0;
}

/// 解析 ndt7 上传阶段服务器测量报告中的 TCPInfo.BytesReceived。
int? parseNdtBytesReceived(String json) {
  try {
    final j = jsonDecode(json);
    if (j is! Map) return null;
    final tcp = j['TCPInfo'];
    if (tcp is Map && tcp['BytesReceived'] is num) {
      return (tcp['BytesReceived'] as num).toInt();
    }
  } catch (_) {}
  return null;
}

String _short(Object e) {
  if (e is SpeedTestException) return e.message;
  final s = '$e';
  if (e is TimeoutException) return '连接超时';
  if (s.contains('Failed host lookup')) return 'DNS 解析失败（可能无网络）';
  if (s.contains('Connection refused')) return '连接被拒绝';
  if (s.contains('Network is unreachable')) return '网络不可达';
  if (s.contains('HandshakeException') || s.contains('CERTIFICATE')) {
    return 'TLS 握手失败';
  }
  return s.length > 120 ? '${s.substring(0, 120)}…' : s;
}
