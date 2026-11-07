import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'agent_settings.dart';

class VisionResult {
  VisionResult({required this.text, required this.source});

  final String text;
  final String source;
}

/// 附图真识图（已去掉硅基 OCR / 百度 OCR）：
/// 1) 智谱 GLM-4V-Flash（免费多模态）
/// 2) DeepSeek 官方 deepseek-flash（复用 LLM_API_KEY，真识图）
class VisionClient {
  VisionClient(this.settings);

  final AgentSettings settings;

  bool get available =>
      settings.hasZhipuVision || settings.hasDeepseekVision;

  Future<VisionResult> understand({
    required File image,
    required String userText,
  }) async {
    final prepared = await Isolate.run(() => _prepareImage(image.path));
    final mime = prepared['mime'] as String;
    final b64 = prepared['b64'] as String;
    final ask = userText.trim().isEmpty
        ? '请读出图中水表/电表的本期读数（只报数字）。'
        : userText.trim();
    final prompt = _vlPrompt(ask);
    final errors = <String>[];

    Future<VisionResult?> tryOpenAi({
      required String baseUrl,
      required String apiKey,
      required String model,
      required String source,
    }) async {
      try {
        final text = await _openaiCompatVision(
          baseUrl: baseUrl,
          apiKey: apiKey,
          model: model,
          mime: mime,
          b64: b64,
          prompt: prompt,
        );
        final cleaned = text.trim();
        if (cleaned.isEmpty) {
          errors.add('$source：空结果');
          return null;
        }
        if (_looksLikeGarbage(cleaned)) {
          errors.add('$source：输出像乱码/重复（已丢弃）');
          return null;
        }
        return VisionResult(text: cleaned, source: source);
      } catch (e) {
        errors.add('$source：${_shortErr(e)}');
        return null;
      }
    }

    if (settings.hasZhipuVision) {
      final r = await tryOpenAi(
        baseUrl: settings.zhipuBaseUrl,
        apiKey: settings.zhipuApiKey,
        model: settings.zhipuVisionModel,
        source: '智谱GLM-4V',
      );
      if (r != null) return r;
    }

    if (settings.hasDeepseekVision) {
      final r = await tryOpenAi(
        baseUrl: settings.deepseekVisionBaseUrl,
        apiKey: settings.apiKey,
        model: settings.deepseekVisionModel,
        source: 'DeepSeek识图',
      );
      if (r != null) return r;
    }

    throw StateError(
      '看图失败（已停用硅基/百度 OCR）。\n'
      '请任选其一：\n'
      '· 免费：env.local 填 ZHIPU_API_KEY（open.bigmodel.cn → glm-4v-flash）\n'
      '· 或确认 LLM_API_KEY 为 DeepSeek，用官方 deepseek-flash 识图\n'
      '${errors.join('\n')}',
    );
  }

  static String _vlPrompt(String ask) => '''
你是房东账本助手的看图模块。用户给了一张表具/票据照片。
请用中文简洁回答，优先给出：
1) 表类型（水表/电表/气表，不确定就写不确定）
2) 本期读数（只写数字；看不清就写「看不清」）
3) 若能看到上期读数也写出
不要编造，不要重复同一句话，不要输出无关校名/广告文字。
用户要求：$ask
''';

  static bool _looksLikeGarbage(String text) {
    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (lines.isEmpty) return true;
    if (lines.length >= 4) {
      final counts = <String, int>{};
      for (final l in lines) {
        final n = (counts[l] = (counts[l] ?? 0) + 1);
        if (n >= 3) return true;
      }
      if (lines.toSet().length <= 2 && lines.length >= 6) return true;
    }
    final compact = text.replaceAll(RegExp(r'\s+'), '');
    for (final token in ['北京科技大学', 'University', 'Q8mm']) {
      if (token.allMatches(compact).length >= 3) return true;
    }
    return false;
  }

  Future<String> _openaiCompatVision({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String mime,
    required String b64,
    required String prompt,
  }) async {
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/chat/completions');
    final body = {
      'model': model,
      'temperature': 0.1,
      'max_tokens': 512,
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:$mime;base64,$b64',
                'detail': 'high',
              },
            },
            {'type': 'text', 'text': prompt},
          ],
        },
      ],
    };
    final res = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 90));
    final raw = utf8.decode(res.bodyBytes);
    if (res.statusCode >= 400) {
      String detail = raw;
      try {
        final j = jsonDecode(raw);
        if (j is Map && j['message'] != null) detail = '${j['message']}';
      } catch (_) {}
      throw StateError('HTTP ${res.statusCode} $detail');
    }
    final json = jsonDecode(raw);
    if (json is! Map) throw StateError('响应无效');
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) throw StateError('无 choices');
    final message = (choices.first as Map)['message'];
    if (message is! Map) throw StateError('无 message');
    final content = message['content'];
    if (content is String) return content.trim();
    if (content is List) {
      final buf = StringBuffer();
      for (final c in content) {
        if (c is Map && c['text'] != null) buf.writeln('${c['text']}');
      }
      return buf.toString().trim();
    }
    throw StateError('无法解析 content');
  }

  static String _shortErr(Object e) {
    var s = '$e'.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length > 140) s = '${s.substring(0, 140)}…';
    return s;
  }

  static Map<String, String> _prepareImage(String path) {
    final raw = File(path).readAsBytesSync();
    if (raw.isEmpty) throw StateError('图片为空');
    final decoded = img.decodeImage(raw);
    if (decoded == null) {
      if (raw.length > 3 * 1024 * 1024) {
        throw StateError('图片过大且无法压缩，请换近景重拍');
      }
      final ext = p.extension(path).toLowerCase();
      final mime = switch (ext) {
        '.png' => 'image/png',
        '.webp' => 'image/webp',
        _ => 'image/jpeg',
      };
      return {'mime': mime, 'b64': base64Encode(raw)};
    }
    var image = decoded;
    const maxSide = 1280;
    if (image.width > maxSide || image.height > maxSide) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxSide)
          : img.copyResize(image, height: maxSide);
    }
    var quality = 75;
    Uint8List jpeg = Uint8List.fromList(img.encodeJpg(image, quality: quality));
    while (jpeg.length > 400 * 1024 && quality > 40) {
      quality -= 10;
      jpeg = Uint8List.fromList(img.encodeJpg(image, quality: quality));
    }
    return {'mime': 'image/jpeg', 'b64': base64Encode(jpeg)};
  }
}
