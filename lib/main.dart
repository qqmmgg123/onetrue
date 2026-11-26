import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_nav.dart';
import 'config/baked_env.dart';
import 'platform_init.dart';
import 'share/wechat_share.dart';
import 'state/app_store.dart';
import 'ui/app_shell.dart';
import 'ui/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
  };

  if (BakedEnv.hasSupabase) {
    await Supabase.initialize(
      url: BakedEnv.supabaseUrl.trim(),
      anonKey: BakedEnv.supabaseAnonKey.trim(),
    );
  }

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
        title: '醍醐',
        navigatorKey: appNavigatorKey,
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
        theme: buildAppTheme(),
        home: const AppShell(),
      ),
    );
  }
}
