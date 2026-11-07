import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import 'agent_settings.dart';

/// 百度智能云通用文字识别（与短语音共用 API Key / Secret）。
///
/// 注意：控制台「开通服务」后，还要在对应接口的「应用授权」里勾选本 Key 所属应用。
/// 实测很多账号只授了标准版、未授高精度；因此默认走标准版。
class BaiduOcr {
  BaiduOcr(this.settings);

  final AgentSettings settings;

  static String? _token;
  static DateTime? _tokenExpiry;

  bool get available =>
      _sanitize(settings.baiduAsrApiKey).isNotEmpty &&
      _sanitize(settings.baiduAsrSecretKey).isNotEmpty;

  String get _keyTail {
    final ak = _sanitize(settings.baiduAsrApiKey);
    if (ak.length < 4) return ak;
    return ak.substring(ak.length - 4);
  }

  Future<String> recognizeFile(File file) async {
    if (!available) {
      throw StateError('未配置百度 API Key（与语音识别同一套 BAIDU_ASR_*）');
    }
    final client = http.Client();
    try {
      final token = await _accessToken(client);
      final prepared = await Isolate.run(() => _prepareImage(file.path));
      final imageB64 = prepared['image'] as String;

      // 标准版：你当前 Key 已实测可调通。高精度未授权时会 error 6，作可选增强。
      try {
        return await _postOcr(
          client,
          token: token,
          imageB64: imageB64,
          path: 'rest/2.0/ocr/v1/general_basic',
          label: '标准版',
        );
      } on _OcrApiError catch (e) {
        if (!e.isPermission) {
          throw StateError(_formatError(e));
        }
        // 若标准版反而无权限，再试高精度（少数账号只授了高精度）
        try {
          return await _postOcr(
            client,
            token: token,
            imageB64: imageB64,
            path: 'rest/2.0/ocr/v1/accurate_basic',
            label: '高精度版',
          );
        } on _OcrApiError catch (e2) {
          throw StateError(_permissionHint(e2));
        }
      }
    } finally {
      client.close();
    }
  }

  Future<String> _postOcr(
    http.Client client, {
    required String token,
    required String imageB64,
    required String path,
    required String label,
  }) async {
    final uri = Uri.https('aip.baidubce.com', path, {
      'access_token': token,
    });
    final res = await client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': 'application/json',
          },
          body: {
            'image': imageB64,
            'language_type': 'CHN_ENG',
            'detect_direction': 'true',
          },
        )
        .timeout(const Duration(seconds: 45));
    final body = utf8.decode(res.bodyBytes);
    if (res.statusCode >= 400) {
      throw StateError('OCR HTTP ${res.statusCode}：$body（Key尾号 $_keyTail）');
    }
    final json = jsonDecode(body);
    if (json is! Map) {
      throw StateError('OCR 响应无效：$body（Key尾号 $_keyTail）');
    }
    final err = json['error_code'] ?? json['err_no'];
    if (err != null && err != 0 && '$err' != '0') {
      final msg = '${json['error_msg'] ?? json['err_msg'] ?? body}';
      throw _OcrApiError(code: '$err', message: msg, label: label);
    }
    final words = json['words_result'];
    if (words is! List || words.isEmpty) {
      throw StateError('图片里没有识别到文字');
    }
    final lines = <String>[];
    for (final w in words) {
      if (w is Map && w['words'] != null) {
        final t = '${w['words']}'.trim();
        if (t.isNotEmpty) lines.add(t);
      }
    }
    if (lines.isEmpty) throw StateError('图片里没有识别到文字');
    return lines.join('\n');
  }

  Future<String> _accessToken(http.Client client) async {
    final now = DateTime.now();
    if (_token != null &&
        _tokenExpiry != null &&
        _tokenExpiry!.isAfter(now.add(const Duration(minutes: 2)))) {
      return _token!;
    }
    final apiKey = _sanitize(settings.baiduAsrApiKey);
    final secret = _sanitize(settings.baiduAsrSecretKey);
    final uri = Uri.https('aip.baidubce.com', '/oauth/2.0/token', {
      'grant_type': 'client_credentials',
      'client_id': apiKey,
      'client_secret': secret,
    });
    final res = await client.get(uri).timeout(const Duration(seconds: 20));
    final tokenBody = utf8.decode(res.bodyBytes);
    if (res.statusCode >= 400) {
      throw StateError('百度 token HTTP ${res.statusCode}：$tokenBody');
    }
    final json = jsonDecode(tokenBody);
    if (json is! Map || json['access_token'] == null) {
      throw StateError('百度 token 无效：$tokenBody');
    }
    _token = '${json['access_token']}';
    final secs = (json['expires_in'] as num?)?.toInt() ?? 2592000;
    _tokenExpiry = now.add(Duration(seconds: secs));
    return _token!;
  }

  String _formatError(_OcrApiError e) =>
      'OCR 失败 [${e.label}] ${e.code}：${e.message}（Key尾号 $_keyTail）';

  String _permissionHint(_OcrApiError e) =>
      '百度返回 ${e.code}（${e.label}）：${e.message}（Key尾号 $_keyTail）\n'
      '请打开：文字识别 → 通用文字识别（标准版）→「应用授权」，'
      '勾选 API Key 尾号为 $_keyTail 的那个应用并保存。'
      '（你账号里高精度版尚未授权，App 已改优先用标准版。）';

  static String _sanitize(String raw) =>
      raw.trim().replaceAll(RegExp(r'[\s\u200b\uFEFF]'), '');

  static Map<String, dynamic> _prepareImage(String path) {
    final bytes = File(path).readAsBytesSync();
    if (bytes.isEmpty) throw StateError('图片为空');
    if (bytes.length > 3 * 1024 * 1024) {
      throw StateError('图片过大（超过 3MB），请换一张更清晰的近景图');
    }
    return {'image': base64Encode(bytes)};
  }
}

class _OcrApiError implements Exception {
  _OcrApiError({
    required this.code,
    required this.message,
    required this.label,
  });

  final String code;
  final String message;
  final String label;

  bool get isPermission {
    if (code == '6' || code == '14') return true;
    final m = message.toLowerCase();
    return m.contains('permission') ||
        m.contains('access data') ||
        m.contains('未开通') ||
        m.contains('无权限') ||
        m.contains('没有权限') ||
        m.contains('未授权') ||
        m.contains('鉴权');
  }

  @override
  String toString() => 'OCR 失败 [$label] $code：$message';
}
