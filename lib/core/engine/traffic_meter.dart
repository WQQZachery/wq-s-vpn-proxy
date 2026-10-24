// SPDX-License-Identifier: GPL-3.0-or-later
// 由原生层上报的真实累计字节数计算速度、峰值与会话流量。没有数据时速度为 null（界面显示“暂无数据”）。

import '../models/models.dart';

class SpeedSample {
  const SpeedSample(this.timestampMs, this.downBps, this.upBps);
  final int timestampMs;
  final double downBps;
  final double upBps;
}

class TrafficMeter {
  TrafficMeter({this.maxSamples = 120});
  final int maxSamples;

  TrafficSnapshot? _base;
  TrafficSnapshot? _last;
  final List<SpeedSample> samples = [];
  double peakDownBps = 0;
  double peakUpBps = 0;

  void reset() {
    _base = null;
    _last = null;
    samples.clear();
    peakDownBps = 0;
    peakUpBps = 0;
  }

  /// 加入一个快照；计数器回绕或重置（新值小于旧值）时以新值为新基线。
  SpeedSample? add(TrafficSnapshot s) {
    final last = _last;
    _base ??= s;
    _last = s;
    if (last == null) return null;
    final dt = s.timestampMs - last.timestampMs;
    if (dt <= 0) return null;
    if (s.rxBytes < last.rxBytes || s.txBytes < last.txBytes) {
      _base = s;
      return null;
    }
    final down = (s.rxBytes - last.rxBytes) * 8000 / dt;
    final up = (s.txBytes - last.txBytes) * 8000 / dt;
    final sample = SpeedSample(s.timestampMs, down, up);
    samples.add(sample);
    if (samples.length > maxSamples) samples.removeAt(0);
    if (down > peakDownBps) peakDownBps = down;
    if (up > peakUpBps) peakUpBps = up;
    return sample;
  }

  int get sessionRxBytes =>
      (_last == null || _base == null) ? 0 : _last!.rxBytes - _base!.rxBytes;
  int get sessionTxBytes =>
      (_last == null || _base == null) ? 0 : _last!.txBytes - _base!.txBytes;
  SpeedSample? get latest => samples.isEmpty ? null : samples.last;
  bool get hasData => samples.isNotEmpty;
}

String formatBps(double? bps) {
  if (bps == null) return '暂无数据';
  const units = ['bps', 'Kbps', 'Mbps', 'Gbps'];
  var v = bps;
  var i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
}

String formatBytes(int b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}
