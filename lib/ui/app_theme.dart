import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全 App 仅黑白灰；列表无卡片圆角阴影（对话气泡另行自绘）。
/// 兼容 Flutter 3.10（MaterialState / CardTheme 旧 API）。
ThemeData buildAppTheme() {
  const bg = Color(0xFFFFFFFF);
  const surface = Color(0xFFF7F7F7);
  const ink = Color(0xFF111111);
  const muted = Color(0xFF888888);
  const line = Color(0xFFE5E5E5);

  final base = ColorScheme.light(
    primary: ink,
    onPrimary: bg,
    secondary: ink,
    onSecondary: bg,
    surface: bg,
    onSurface: ink,
    background: bg,
    onBackground: ink,
    error: const Color(0xFFB00020),
    onError: bg,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: base.copyWith(
      surfaceVariant: surface,
      onSurfaceVariant: muted,
      outline: line,
      outlineVariant: line,
    ),
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    dividerColor: line,
    dividerTheme: const DividerThemeData(
      color: line,
      thickness: 0.5,
      space: 0.5,
    ),
    appBarTheme: const AppBarTheme(
      elevation: 0,
      backgroundColor: bg,
      foregroundColor: ink,
      centerTitle: true,
      systemOverlayStyle: SystemUiOverlayStyle.dark,
      titleTextStyle: TextStyle(
        color: ink,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: const CardTheme(
      elevation: 0,
      shadowColor: Colors.transparent,
      margin: EdgeInsets.zero,
      color: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
      dense: true,
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: bg,
      indicatorColor: Colors.transparent,
      labelTextStyle: MaterialStateProperty.resolveWith((s) {
        final selected = s.contains(MaterialState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? ink : muted,
        );
      }),
      iconTheme: MaterialStateProperty.resolveWith((s) {
        final selected = s.contains(MaterialState.selected);
        return IconThemeData(color: selected ? ink : muted, size: 22);
      }),
    ),
    tabBarTheme: const TabBarTheme(
      labelColor: ink,
      unselectedLabelColor: muted,
      indicatorColor: ink,
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
      labelPadding: EdgeInsets.symmetric(horizontal: 14),
      overlayColor: MaterialStatePropertyAll(Colors.transparent),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      backgroundColor: ink,
      foregroundColor: bg,
      shape: CircleBorder(),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ink,
        foregroundColor: bg,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        side: const BorderSide(color: line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: ink),
      ),
      isDense: true,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: ink,
      contentTextStyle: const TextStyle(color: bg),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    dialogTheme: DialogTheme(
      elevation: 0,
      backgroundColor: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: ink),
    switchTheme: SwitchThemeData(
      thumbColor: MaterialStateProperty.resolveWith(
        (s) => s.contains(MaterialState.selected) ? ink : muted,
      ),
      trackColor: MaterialStateProperty.resolveWith(
        (s) => s.contains(MaterialState.selected)
            ? ink.withOpacity(0.35)
            : line,
      ),
    ),
  );
}
