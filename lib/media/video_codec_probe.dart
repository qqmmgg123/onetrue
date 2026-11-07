import 'dart:io';

import 'package:flutter/services.dart';

/// 本地视频编码探测（Android MediaExtractor）。已是 H.264/MP4 可跳过重编。
class VideoCodecProbe {
  VideoCodecProbe._();

  static const _channel = MethodChannel('rent_agent/video_probe');

  static Future<VideoCodecInfo> probe(String path) async {
    if (!Platform.isAndroid) {
      // iOS 暂无原生探测：仅当扩展名像 mp4 时倾向跳过（有 HEVC 风险，仍可能再压）
      final lower = path.toLowerCase();
      final mp4 = lower.endsWith('.mp4') || lower.endsWith('.m4v');
      return VideoCodecInfo(
        videoMime: '',
        audioMime: '',
        width: 0,
        height: 0,
        isAvc: false,
        isHevc: false,
        skipReencode: false,
        mp4Container: mp4,
      );
    }
    try {
      final raw = await _channel.invokeMethod<dynamic>('probe', {'path': path});
      if (raw is! Map) return VideoCodecInfo.unknown;
      final m = Map<String, dynamic>.from(raw);
      return VideoCodecInfo(
        videoMime: '${m['videoMime'] ?? ''}',
        audioMime: '${m['audioMime'] ?? ''}',
        width: (m['width'] as num?)?.toInt() ?? 0,
        height: (m['height'] as num?)?.toInt() ?? 0,
        isAvc: m['isAvc'] == true,
        isHevc: m['isHevc'] == true,
        skipReencode: m['skipReencode'] == true,
        mp4Container: path.toLowerCase().endsWith('.mp4') ||
            path.toLowerCase().endsWith('.m4v'),
      );
    } catch (_) {
      return VideoCodecInfo.unknown;
    }
  }
}

class VideoCodecInfo {
  const VideoCodecInfo({
    required this.videoMime,
    required this.audioMime,
    required this.width,
    required this.height,
    required this.isAvc,
    required this.isHevc,
    required this.skipReencode,
    required this.mp4Container,
  });

  static const unknown = VideoCodecInfo(
    videoMime: '',
    audioMime: '',
    width: 0,
    height: 0,
    isAvc: false,
    isHevc: false,
    skipReencode: false,
    mp4Container: false,
  );

  final String videoMime;
  final String audioMime;
  final int width;
  final int height;
  final bool isAvc;
  final bool isHevc;
  final bool skipReencode;
  final bool mp4Container;
}
