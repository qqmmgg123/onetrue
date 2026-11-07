import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 离线 Vosk（vosk-model-small-cn）：模型约 42MB，**首次按需下载到本地**，不打进 APK。
class VoskAsr {
  VoskAsr._();
  static final VoskAsr instance = VoskAsr._();

  static const _method = MethodChannel('rent_agent/vosk');
  static const _events = EventChannel('rent_agent/vosk_events');

  static const modelName = 'vosk-model-small-cn-0.22';
  static const modelZipUrl =
      'https://alphacephei.com/vosk/models/vosk-model-small-cn-0.22.zip';

  StreamSubscription? _sub;
  String _lastPartial = '';
  String _lastFinal = '';
  bool _prepared = false;
  bool _listening = false;

  bool get isPrepared => _prepared;
  bool get isListening => _listening;
  String get lastPartial => _lastPartial;

  Future<Directory> _modelRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'vosk_models'));
  }

  Future<String?> modelDirPath() async {
    final root = await _modelRoot();
    final dir = Directory(p.join(root.path, modelName));
    if (await dir.exists() &&
        await File(p.join(dir.path, 'am', 'final.mdl')).exists()) {
      return dir.path;
    }
    return null;
  }

  Future<bool> get isModelOnDisk async => (await modelDirPath()) != null;

  /// 下载并解压模型（已存在则跳过）。[onProgress] 0~1。
  Future<String> ensureModel({void Function(double p, String tip)? onProgress}) async {
    final existing = await modelDirPath();
    if (existing != null) {
      onProgress?.call(1, '模型已就绪');
      return existing;
    }
    if (!Platform.isAndroid) {
      throw StateError('离线 Vosk 目前仅支持 Android');
    }

    final root = await _modelRoot();
    await root.create(recursive: true);
    final zipPath = p.join(root.path, '$modelName.zip');
    onProgress?.call(0.02, '正在下载离线中文模型（约 42MB，仅首次）…');

    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(modelZipUrl));
      final res = await client.send(req).timeout(const Duration(minutes: 10));
      if (res.statusCode >= 400) {
        throw StateError('下载失败 HTTP ${res.statusCode}');
      }
      final total = res.contentLength ?? 0;
      final sink = File(zipPath).openWrite();
      var got = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) {
          onProgress?.call(
            (got / total * 0.85).clamp(0.02, 0.85),
            '下载模型 ${(got / 1024 / 1024).toStringAsFixed(1)}/${(total / 1024 / 1024).toStringAsFixed(1)} MB',
          );
        }
      }
      await sink.close();
    } finally {
      client.close();
    }

    onProgress?.call(0.88, '正在解压模型…');
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    await extractArchiveToDiskAsync(archive, root.path);
    try {
      await File(zipPath).delete();
    } catch (_) {}

    final path = await modelDirPath();
    if (path == null) {
      throw StateError('解压后未找到 $modelName，请检查网络后重试');
    }
    onProgress?.call(1, '离线模型就绪');
    return path;
  }

  Future<void> prepare({void Function(double p, String tip)? onProgress}) async {
    final path = await ensureModel(onProgress: onProgress);
    await _method.invokeMethod('prepare', {'modelPath': path});
    _prepared = true;
  }

  Future<void> startListening({void Function(String partial)? onPartial}) async {
    if (!_prepared) await prepare();
    _lastPartial = '';
    _lastFinal = '';
    await _sub?.cancel();
    _sub = _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final type = '${event['type']}';
      final text = '${event['text'] ?? ''}'.trim();
      if (type == 'partial' && text.isNotEmpty) {
        _lastPartial = text;
        onPartial?.call(text);
      } else if (type == 'result' || type == 'final') {
        if (text.isNotEmpty) _lastFinal = text;
      } else if (type == 'error') {
        debugPrint('vosk error: $text');
      }
    });
    await _method.invokeMethod('start');
    _listening = true;
  }

  Future<String> stopListening() async {
    try {
      await _method.invokeMethod('stop');
    } catch (_) {}
    // 等 onFinalResult 事件
    await Future<void>.delayed(const Duration(milliseconds: 280));
    _listening = false;
    await _sub?.cancel();
    _sub = null;
    final t =
        _lastFinal.trim().isNotEmpty ? _lastFinal.trim() : _lastPartial.trim();
    // Vosk 中文常带空格：「三 零 二」→ 去掉空格更便于本地解析房号
    return t.replaceAll(RegExp(r'\s+'), '');
  }
}
