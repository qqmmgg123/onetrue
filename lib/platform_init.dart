import 'package:flutter/foundation.dart';

/// 移动端用 sqflite 官方插件，不要在这里 import sqflite_common_ffi。
/// （ffi 包一旦被编进 APK，部分 Android 机会启动即闪退）
void initLocalDatabase() {
  // Windows/Linux 桌面若需要本地库，请用 lib/main_desktop.dart 入口。
  if (kIsWeb) return;
}

bool get notificationsSupported {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return true;
    default:
      return false;
  }
}
