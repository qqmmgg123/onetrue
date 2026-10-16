import 'package:flutter/services.dart';

/// 用平台通道录音，避免引入 record 插件（其依赖在国内网络容易卡住）。
class SimpleRecorder {
  static const _channel = MethodChannel('rent_agent/recorder');

  Future<void> start(String path) async {
    await _channel.invokeMethod('start', {'path': path});
  }

  Future<String?> stop() async {
    final r = await _channel.invokeMethod<String>('stop');
    return r;
  }

  /// 当前音量约 0~1（由振幅估算），录音中周期性可读。
  Future<double> amplitude() async {
    final r = await _channel.invokeMethod<num>('amplitude');
    return (r ?? 0).toDouble().clamp(0.0, 1.0);
  }
}
