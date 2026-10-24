import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypilot_mobile/features/settings/settings_page.dart';

void main() {
  const brand = "WQ's Proxy VPN";
  test('应用内品牌常量', () => expect(appBrandName, brand));

  test('Android 桌面名称资源正确转义撇号', () {
    final xml = File('android/app/src/main/res/values/strings.xml')
        .readAsStringSync();
    expect(
      xml,
      contains(r'''<string name="app_name">WQ\'s Proxy VPN</string>'''),
    );
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(manifest, contains('android:label="@string/app_name"'));
  });

  test('显示版本与 pubspec 一致', () {
    final v = RegExp(
      r'^version:\s*([\d.]+)\+',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);
    expect(appVersion, v);
  });

  test('用户可见代码中不再出现旧品牌名', () {
    final hits = <String>[];
    for (final f in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (l.contains('ProxyPilot') &&
            !l.trimLeft().startsWith('//') &&
            !l.contains('ProxyPilotApp'))
          hits.add('${f.path}:${i + 1}');
      }
    }
    expect(hits, isEmpty);
  });
}
