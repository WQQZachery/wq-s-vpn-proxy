// WQ's Proxy VPN（原名 ProxyPilot Mobile）
// Copyright (C) 2026 WQ's Proxy VPN contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/ripple_nav.dart';
import 'app/state.dart';
import 'app/theme.dart';
import 'core/storage/app_database.dart';
import 'features/dashboard/dashboard_page.dart';
import 'features/diagnostics/diagnostics_page.dart';
import 'features/profiles/profiles_page.dart';
import 'features/settings/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.open(SecureSecretStore());
  runApp(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const ProxyPilotApp(),
    ),
  );
}

class ProxyPilotApp extends StatelessWidget {
  const ProxyPilotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "WQ's Proxy VPN",
      debugShowCheckedModeBanner: false,
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      locale: const Locale('zh', 'CN'),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  static const destinations = [
    NavDestinationSpec(Icons.speed_outlined, Icons.speed_rounded, '首页'),
    NavDestinationSpec(Icons.dns_outlined, Icons.dns_rounded, '节点'),
    NavDestinationSpec(Icons.troubleshoot_outlined, Icons.troubleshoot_rounded, '检测'),
    NavDestinationSpec(Icons.settings_outlined, Icons.settings_rounded, '设置'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 让 VPN 控制器尽早订阅原生事件
    ref.watch(vpnControllerProvider.select((s) => s.state));
    return RippleNavShell(
      destinations: destinations,
      pageBuilder: (i, active) => switch (i) {
        0 => const DashboardPage(),
        1 => ProfilesPage(active: active),
        2 => const DiagnosticsPage(),
        _ => const SettingsPage(),
      },
    );
  }
}
