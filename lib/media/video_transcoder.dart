import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Android Media3：强制转成 H.264/AAC；失败返回 null。
class VideoTranscoder {
  VideoTranscoder._();

  static const _method = MethodChannel('rent_agent/video_transcode');
  static const _progress = EventChannel('rent_agent/video_transcode_progress');

  static bool get isSupported => Platform.isAndroid;

  static Future<File?> thumbnail(String videoPath) async {
    if (!isSupported) return null;
    try {
      final dir = await getTemporaryDirectory();
      final out = p.join(
        dir.path,
        'thumb_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      final path = await _method
          .invokeMethod<String>('thumbnail', {'path': videoPath, 'out': out})
          .timeout(const Duration(seconds: 8));
      if (path == null || path.isEmpty) return null;
      final f = File(path);
      return (await f.exists() && await f.length() > 0) ? f : null;
    } catch (_) {
      return null;
    }
  }

  /// 返回转码后的 mp4；[onProgress] 为 0~100。
  static Future<File?> transcodeToAvc(
    String inputPath, {
    int maxHeight = 720,
    void Function(int percent)? onProgress,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    if (!isSupported) return null;
    StreamSubscription? sub;
    try {
      sub = _progress.receiveBroadcastStream().listen((e) {
        final n = (e is num) ? e.toInt() : int.tryParse('$e') ?? 0;
        onProgress?.call(n.clamp(0, 100));
      });
      final dir = await getTemporaryDirectory();
      final out = p.join(
        dir.path,
        'avc_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
      final path = await _method.invokeMethod<String>('transcodeAvc', {
        'input': inputPath,
        'output': out,
        'maxHeight': maxHeight,
      }).timeout(timeout, onTimeout: () {
        // ignore: discarded_futures
        _method.invokeMethod('cancel');
        return null;
      });
      if (path == null || path.isEmpty) return null;
      final f = File(path);
      if (!await f.exists() || await f.length() <= 0) return null;
      onProgress?.call(100);
      return f;
    } catch (_) {
      try {
        await _method.invokeMethod('cancel');
      } catch (_) {}
      return null;
    } finally {
      await sub?.cancel();
    }
  }
}
