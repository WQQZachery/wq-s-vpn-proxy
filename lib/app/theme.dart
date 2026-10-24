// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

const kAccent = Color(0xFF4F8CFF);
const kGood = Color(0xFF3DDC97);
const kWarn = Color(0xFFFFB547);
const kBad = Color(0xFFFF5C6C);

/// 默认深色主题；浅色主题可通过同样的 ColorScheme.fromSeed(brightness: light) 后续添加。
ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kAccent,
    brightness: Brightness.dark,
    surface: const Color(0xFF11141B),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF0B0D12),
    cardTheme: CardThemeData(
      color: const Color(0xFF161A23),
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Color(0xFF11141B),
      height: 64,
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(color: Colors.white70),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

void showSnack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}
