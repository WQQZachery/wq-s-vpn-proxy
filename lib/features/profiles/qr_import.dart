// SPDX-License-Identifier: GPL-3.0-or-later
// R3：二维码扫码 / 相册图片识别导入。
// 识别出的文本不做任何特殊处理，统一交给 NodesNotifier.importText（ShareLinkParser
// + NodeValidator + 去重），因此不会绕过现有安全校验。
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/theme.dart';

enum QrPayloadKind {
  /// 节点分享链接 / Base64 订阅内容 / sing-box JSON → 走 importText
  nodes,

  /// 纯 http(s) 地址 → 当作订阅 URL，走“添加订阅”
  subscriptionUrl,

  /// 无法识别（例如普通网址以外的文本、空内容）
  unknown,
}

class QrPayload {
  const QrPayload(this.kind, this.text, {this.count = 0});
  final QrPayloadKind kind;

  /// 交给导入流程的文本（多个二维码时逐行合并、去重）。
  final String text;

  /// 识别到的有效二维码数量。
  final int count;
}

const _nodeSchemes = {
  'ss',
  'vmess',
  'vless',
  'trojan',
  'hysteria2',
  'hy2',
  'tuic',
  'socks',
  'socks5',
};

/// 把一次扫描/识别得到的所有二维码文本归类。纯函数，便于测试。
QrPayload classifyQrPayload(Iterable<String?> raws) {
  final seen = <String>{};
  final values = <String>[];
  for (final r in raws) {
    final v = r?.trim() ?? '';
    if (v.isNotEmpty && seen.add(v)) values.add(v);
  }
  if (values.isEmpty) return const QrPayload(QrPayloadKind.unknown, '');

  bool isHttp(String v) {
    final u = Uri.tryParse(v);
    return u != null &&
        (u.scheme == 'http' || u.scheme == 'https') &&
        u.host.isNotEmpty &&
        !v.contains('\n');
  }

  if (values.length == 1 && isHttp(values.single)) {
    return QrPayload(
      QrPayloadKind.subscriptionUrl,
      values.single,
      count: 1,
    );
  }

  bool looksLikeNodes(String v) {
    final t = v.trimLeft();
    if (t.startsWith('{')) return true;
    final lines = t.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty);
    if (lines.any((l) {
      final i = l.indexOf('://');
      return i > 0 && _nodeSchemes.contains(l.substring(0, i).trim().toLowerCase());
    })) {
      return true;
    }
    // Base64 订阅内容
    return !t.contains(' ') && RegExp(r'^[A-Za-z0-9+/=_\-\s]{16,}$').hasMatch(t);
  }

  final nodes = values.where(looksLikeNodes).toList();
  if (nodes.isEmpty) return const QrPayload(QrPayloadKind.unknown, '');
  return QrPayload(QrPayloadKind.nodes, nodes.join('\n'), count: nodes.length);
}

/// 相机扫码页。识别到第一个可用结果后返回 [QrPayload]；用户返回则为 null。
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _ctl = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;
  String? _hint;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture c) {
    if (_done) return;
    final p = classifyQrPayload(c.barcodes.map((b) => b.rawValue));
    if (p.kind == QrPayloadKind.unknown) {
      setState(() => _hint = '这个二维码不是节点或订阅，请换一个');
      return;
    }
    _done = true;
    Navigator.of(context).pop(p);
  }

  Future<void> _fromGallery() async {
    final p = await pickQrFromGallery(context, controller: _ctl);
    if (!mounted || p == null) return;
    if (p.kind == QrPayloadKind.unknown) {
      setState(() => _hint = '图片中没有可识别的节点二维码');
      return;
    }
    _done = true;
    Navigator.of(context).pop(p);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫码导入'),
        actions: [
          IconButton(
            tooltip: '闪光灯',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _ctl.toggleTorch(),
          ),
          IconButton(
            tooltip: '从相册选择',
            icon: const Icon(Icons.photo_library_outlined),
            onPressed: _fromGallery,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _ctl,
            onDetect: _onDetect,
            errorBuilder: (c, e) => _ScanError(
              error: e,
              onGallery: _fromGallery,
            ),
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: kAccent, width: 2),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Text(
              _hint ?? '将节点或订阅二维码放入框内',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanError extends StatelessWidget {
  const _ScanError({required this.error, required this.onGallery});
  final MobileScannerException error;
  final VoidCallback onGallery;

  @override
  Widget build(BuildContext context) {
    final msg = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        '没有相机权限。可以在系统设置中授予，或改用相册图片识别。',
      MobileScannerErrorCode.unsupported => '此设备没有可用的相机。',
      _ => '相机启动失败：${error.errorCode.name}',
    };
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, color: Colors.white54, size: 48),
              const SizedBox(height: 12),
              Text(msg, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onGallery,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('从相册选择'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 从相册选一张图片并识别其中的二维码。Android 13+ 使用系统照片选择器，无需存储权限。
/// 用户取消返回 null；识别失败返回 kind=unknown。
Future<QrPayload?> pickQrFromGallery(
  BuildContext context, {
  MobileScannerController? controller,
}) async {
  final XFile? f;
  try {
    f = await ImagePicker().pickImage(source: ImageSource.gallery);
  } catch (e) {
    if (context.mounted) showSnack(context, '无法打开相册：$e');
    return null;
  }
  if (f == null) return null;
  final ctl = controller ?? MobileScannerController(autoStart: false);
  try {
    final cap = await ctl.analyzeImage(
      f.path,
      formats: const [BarcodeFormat.qrCode],
    );
    return classifyQrPayload(cap?.barcodes.map((b) => b.rawValue) ?? const []);
  } catch (_) {
    return const QrPayload(QrPayloadKind.unknown, '');
  } finally {
    if (controller == null) await ctl.dispose();
  }
}
