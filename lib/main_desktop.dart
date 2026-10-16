import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'state/app_store.dart';
import 'ui/app_shell.dart';

/// 仅 Windows/Linux 桌面调试用：
/// flutter run -d windows -t lib/main_desktop.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final store = AppStore();
  runApp(_DesktopApp(store: store));
  try {
    await store.bootstrap();
  } catch (e, st) {
    debugPrint('bootstrap failed: $e\n$st');
  }
}

class _DesktopApp extends StatelessWidget {
  const _DesktopApp({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(
        title: '收租助手',
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F4B99)),
          useMaterial3: true,
        ),
        home: const AppShell(),
      ),
    );
  }
}
