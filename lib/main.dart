// WQ's Proxy VPN（原名 ProxyPilot Mobile）
// Copyright (C) 2026 WQ's Proxy VPN contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});
  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    // 让 VPN 控制器尽早订阅原生事件
    ref.watch(vpnControllerProvider.select((s) => s.state));
    const pages = [
      DashboardPage(),
      ProfilesPage(),
      DiagnosticsPage(),
      SettingsPage(),
    ];
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(index: _index, children: pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.speed_outlined),
            selectedIcon: Icon(Icons.speed),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.dns_outlined),
            selectedIcon: Icon(Icons.dns),
            label: '节点',
          ),
          NavigationDestination(
            icon: Icon(Icons.troubleshoot_outlined),
            selectedIcon: Icon(Icons.troubleshoot),
            label: '检测',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
