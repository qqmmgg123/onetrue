import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'platform_init.dart';
import 'share/wechat_share.dart';
import 'state/app_store.dart';
import 'ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
  };

  initLocalDatabase();
  try {
    await WeChatShare.instance.init();
  } catch (e) {
    debugPrint('wechat init: $e');
  }
  final store = AppStore();

  runZonedGuarded(() {
    runApp(RentAgentApp(store: store));
  }, (error, stack) {
    debugPrint('Uncaught: $error\n$stack');
  });

  try {
    await store.bootstrap();
  } catch (e, st) {
    debugPrint('bootstrap failed: $e\n$st');
  }
}

class RentAgentApp extends StatelessWidget {
  const RentAgentApp({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(
        title: '缘初',
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [
          Locale('zh', 'CN'),
          Locale('en'),
        ],
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
