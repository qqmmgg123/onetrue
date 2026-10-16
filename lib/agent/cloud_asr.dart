import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'agent_settings.dart';

class AsrEndpoint {
  const AsrEndpoint({
    required this.name,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    this.language,
  });

  final String name;
  final String baseUrl;
  final String model;
  final String apiKey;
  final String? language;
}

class AsrCascadeResult {
  const AsrCascadeResult({
    required this.text,
    required this.source,
  });

  final String text;
  final String source;
}

/// OpenAI 兼容 /audio/transcriptions，支持 Groq → SenseVoice 级联。
class CloudAsr {
  CloudAsr(this.settings);

  final AgentSettings settings;

  static const timeout = Duration(seconds: 5);

  bool get available => settings.hasCloudAsr;

  List<AsrEndpoint> _endpoints() {
    final list = <AsrEndpoint>[];
    final groqKey = _sanitizeKey(settings.groqApiKey);
    if (groqKey.isNotEmpty) {
      list.add(
        AsrEndpoint(
          name: 'Groq Whisper',
          baseUrl: settings.groqBaseUrl.trim().isEmpty
              ? 'https://api.groq.com/openai/v1'
              : settings.groqBaseUrl.trim(),
          model: settings.groqAsrModel.trim().isEmpty
              ? 'whisper-large-v3-turbo'
              : settings.groqAsrModel.trim(),
          apiKey: groqKey,
          language: 'zh',
        ),
      );
    }
    final senseKey = _sanitizeKey(settings.effectiveAsrApiKey);
    if (senseKey.isNotEmpty) {
      list.add(
        AsrEndpoint(
          name: 'SenseVoice',
          baseUrl: settings.effectiveAsrBaseUrl,
          model: settings.asrModel.trim().isEmpty
              ? 'FunAudioLLM/SenseVoiceSmall'
              : settings.asrModel.trim(),
          apiKey: senseKey,
        ),
      );
    }
    return list;
  }

  /// 按优先级尝试各云端；全部失败抛出汇总错误。
  Future<AsrCascadeResult> transcribeFile(File file) async {
    final endpoints = _endpoints();
    if (endpoints.isEmpty) {
      throw StateError('未配置 Groq 或硅基流动语音 Key');
    }

    final errors = <String>[];
    for (final ep in endpoints) {
      try {
        final text = await _transcribeOnce(file, ep).timeout(timeout);
        final t = text.trim();
        if (t.isEmpty) {
          errors.add('${ep.name}：结果为空');
          continue;
        }
        return AsrCascadeResult(text: t, source: ep.name);
      } on TimeoutException {
        errors.add('${ep.name}：超过 ${timeout.inSeconds} 秒超时');
      } catch (e) {
        final msg = '$e';
        // 额度/鉴权/限流等一律落到下一家
        errors.add('${ep.name}：$msg');
      }
    }
    throw StateError('云端转写均未成功：\n${errors.join('\n')}');
  }

  Future<String> _transcribeOnce(File file, AsrEndpoint ep) async {
    final base = ep.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/audio/transcriptions');
    final req = http.MultipartRequest('POST', uri);
    req.headers['Authorization'] = 'Bearer ${ep.apiKey}';
    req.fields['model'] = ep.model;
    if (ep.language != null && ep.language!.isNotEmpty) {
      req.fields['language'] = ep.language!;
    }
    req.files.add(
      await http.MultipartFile.fromPath(
        'file',
        file.path,
        filename: file.uri.pathSegments.isNotEmpty
            ? file.uri.pathSegments.last
            : 'audio.m4a',
      ),
    );

    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode >= 400) {
      throw StateError('HTTP ${streamed.statusCode}：$body');
    }
    final json = jsonDecode(body);
    if (json is Map && json['text'] != null) {
      return '${json['text']}';
    }
    throw StateError('转写结果为空：$body');
  }

  static String _sanitizeKey(String raw) {
    var k = raw.trim();
    if ((k.startsWith('"') && k.endsWith('"')) ||
        (k.startsWith("'") && k.endsWith("'"))) {
      k = k.substring(1, k.length - 1).trim();
    }
    if (k.toLowerCase().startsWith('bearer ')) {
      k = k.substring(7).trim();
    }
    return k.replaceAll(RegExp(r'\s+'), '');
  }
}
