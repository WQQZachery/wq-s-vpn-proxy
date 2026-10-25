// SPDX-License-Identifier: GPL-3.0-or-later
// uTLS 指纹规范化。
//
// 依据：sing-box v1.14.3 option/tls.go（OutboundUTLSOptions.Fingerprint 的 enum）
// 与 common/tls/utls_client.go uTLSClientHelloID()。其他值会让内核在
// "initialize outbound[N]: unknown uTLS fingerprint: X" 处直接启动失败，
// 并且由于配置包含所有已启用节点，一个坏节点就会拖垮整次连接。
//
// 注意：这里只处理 uTLS 指纹，与 TLS 证书校验（insecure）无关，
// insecure 仍由 NodeValidator 单独拒绝。

/// sing-box 1.14.3 接受的全部 fingerprint 值（空字符串除外，空值 = 内核默认 chrome）。
const Set<String> singBoxUtlsFingerprints = {
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

enum FingerprintStatus {
  /// 未设置（null / 空白）：不显式启用 uTLS；REALITY 时用内核默认 chrome。
  unset,

  /// 合法值，原样保留（仅去掉首尾空白、统一小写）。
  supported,

  /// Xray 系客户端的 `unsafe`：含义是“不使用 uTLS，使用标准 TLS”。
  /// sing-box 不认识该值，按其语义处理为不启用 uTLS。
  unsafeOptOut,

  /// 其他内核不支持的值：丢弃，按未设置处理，并给出诊断提示。
  unsupported,
}

class FingerprintResolution {
  const FingerprintResolution(this.status, this.value, this.raw);

  final FingerprintStatus status;

  /// 可以写入 sing-box 配置的值；null 表示不写（未设置）。
  final String? value;

  /// 原始输入（用于诊断提示，不含敏感信息）。
  final String? raw;

  bool get changed =>
      status == FingerprintStatus.unsafeOptOut ||
      status == FingerprintStatus.unsupported;

  /// 面向用户的中文诊断；未改动时为 null。
  String? get message => switch (status) {
    FingerprintStatus.unsafeOptOut =>
      'uTLS 指纹 "$raw" 是 Xray 的“不使用 uTLS”写法，sing-box 不支持；'
          '已按标准 TLS 处理（REALITY 节点使用内核默认 chrome 指纹）',
    FingerprintStatus.unsupported =>
      'uTLS 指纹 "$raw" 不被 sing-box 1.14.3 支持，已忽略并使用默认值；'
          '可用值：${singBoxUtlsFingerprints.join('、')}',
    _ => null,
  };
}

FingerprintResolution resolveUtlsFingerprint(String? raw) {
  final v = raw?.trim().toLowerCase() ?? '';
  if (v.isEmpty) return FingerprintResolution(FingerprintStatus.unset, null, raw);
  if (singBoxUtlsFingerprints.contains(v)) {
    return FingerprintResolution(FingerprintStatus.supported, v, raw);
  }
  if (v == 'unsafe' || v == 'none') {
    return FingerprintResolution(FingerprintStatus.unsafeOptOut, null, raw);
  }
  return FingerprintResolution(FingerprintStatus.unsupported, null, raw);
}
