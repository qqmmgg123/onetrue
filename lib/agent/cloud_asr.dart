import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import 'agent_settings.dart';

class AsrEndpoint {
  const AsrEndpoint({
    required this.name,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    this.language,
    this.prompt,
  });

  final String name;
  final String baseUrl;
  final String model;
  final String apiKey;
  final String? language;
  final String? prompt;
}

class AsrCascadeResult {
  const AsrCascadeResult({
    required this.text,
    required this.source,
  });

  final String text;
  final String source;
}

/// 云端 ASR 级联：百度 → Groq Whisper → SenseVoice。
/// 每家严格限时；超时会关掉 HTTP 连接，避免长录音卡死。
class CloudAsr {
  CloudAsr(this.settings);

  final AgentSettings settings;

  /// 每家等待上限（含上传）。超时立刻换下一家。
  static const perEngineTimeout = Duration(seconds: 3);

  /// 百度短语音要整段 base64，过大时编码会卡住 UI，直接跳过。
  static const baiduMaxBytes = 480 * 1024;

  bool get available => settings.hasCloudAsr;

  /// [onEngine] 便于界面显示「正在试百度…」
  Future<AsrCascadeResult> transcribeFile(
    File file, {
    void Function(String engine)? onEngine,
  }) async {
    final errors = <String>[];
    final len = await file.length();

    if (settings.hasBaiduAsr) {
      if (len > baiduMaxBytes) {
        errors.add('百度智能云：录音偏长，跳过改试下一家');
      } else {
        onEngine?.call('百度智能云');
        try {
          final text = await _raceEngine(
            (client) => _baiduTranscribe(file, client),
            '百度智能云',
          );
          final t = text.trim();
          if (t.isNotEmpty) {
            return AsrCascadeResult(text: t, source: '百度智能云');
          }
          errors.add('百度智能云：结果为空，已试下一家');
        } catch (e) {
          errors.add(_formatEngineError('百度智能云', e));
        }
      }
    }

    for (final ep in _openaiEndpoints()) {
      onEngine?.call(ep.name);
      try {
        final text = await _raceEngine(
          (client) => _transcribeOnce(file, ep, client),
          ep.name,
        );
        final t = text.trim();
        if (t.isEmpty) {
          errors.add('${ep.name}：结果为空，已试下一家');
          continue;
        }
        return AsrCascadeResult(text: t, source: ep.name);
      } catch (e) {
        errors.add(_formatEngineError(ep.name, e));
      }
    }

    if (errors.isEmpty) {
      throw StateError('未配置百度 / Groq / SenseVoice 语音 Key');
    }
    throw StateError(errors.join('\n'));
  }

  /// 限时 + 超时关闭 Client，打断卡住的上传/下载。
  Future<String> _raceEngine(
    Future<String> Function(http.Client client) run,
    String name,
  ) async {
    final client = http.Client();
    try {
      return await run(client).timeout(perEngineTimeout);
    } on TimeoutException {
      throw TimeoutException('$name 超过 ${perEngineTimeout.inSeconds} 秒');
    } finally {
      client.close();
    }
  }

  String _formatEngineError(String name, Object e) {
    if (e is TimeoutException) {
      return '$name：超过 ${perEngineTimeout.inSeconds} 秒，已试下一家';
    }
    return '$name：${_shortError(e)}，已试下一家';
  }

  List<AsrEndpoint> _openaiEndpoints() {
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
          prompt: '以下是简体中文普通话。房租、电费、水费、抄表、账期。',
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

  static String? _baiduToken;
  static DateTime? _baiduTokenExpiry;

  Future<String> _baiduAccessToken(http.Client client) async {
    final now = DateTime.now();
    if (_baiduToken != null &&
        _baiduTokenExpiry != null &&
        _baiduTokenExpiry!.isAfter(now.add(const Duration(minutes: 2)))) {
      return _baiduToken!;
    }
    final apiKey = _sanitizeKey(settings.baiduAsrApiKey);
    final secret = _sanitizeKey(settings.baiduAsrSecretKey);
    final uri = Uri.https('aip.baidubce.com', '/oauth/2.0/token', {
      'grant_type': 'client_credentials',
      'client_id': apiKey,
      'client_secret': secret,
    });
    final res = await client.get(uri);
    final tokenBody = _utf8Body(res);
    if (res.statusCode >= 400) {
      throw StateError('token HTTP ${res.statusCode}：$tokenBody');
    }
    final json = jsonDecode(tokenBody);
    if (json is! Map || json['access_token'] == null) {
      throw StateError('token 无效：$tokenBody');
    }
    _baiduToken = '${json['access_token']}';
    final secs = (json['expires_in'] as num?)?.toInt() ?? 2592000;
    _baiduTokenExpiry = now.add(Duration(seconds: secs));
    return _baiduToken!;
  }

  Future<String> _baiduTranscribe(File file, http.Client client) async {
    final token = await _baiduAccessToken(client);
    // 大文件 base64 放到后台 isolate，避免卡住 UI / 拖死 timeout
    final prepared = await Isolate.run(() => _prepareBaiduPayload(file.path));
    final body = jsonEncode({
      'format': prepared['format'],
      'rate': 16000,
      'channel': 1,
      'cuid': 'rent_agent_android',
      'token': token,
      'speech': prepared['speech'],
      'len': prepared['len'],
      'dev_pid': 1537,
    });
    final res = await client.post(
      Uri.parse('https://vop.baidu.com/server_api'),
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
      },
      body: body,
      encoding: utf8,
    );
    final bodyText = _utf8Body(res);
    if (res.statusCode >= 400) {
      throw StateError('HTTP ${res.statusCode}：$bodyText');
    }
    final json = jsonDecode(bodyText);
    if (json is! Map) throw StateError('响应无效：$bodyText');
    final err = json['err_no'];
    if (err != null && err != 0) {
      throw StateError('err_no=$err ${json['err_msg']}');
    }
    final result = json['result'];
    if (result is List && result.isNotEmpty) {
      return _preferSimplified('${result.first}', null);
    }
    throw StateError('转写结果为空：$bodyText');
  }

  /// 在 isolate 里读文件+base64，避免主线程卡死。
  static Map<String, dynamic> _prepareBaiduPayload(String path) {
    final bytes = File(path).readAsBytesSync();
    if (bytes.isEmpty) throw StateError('录音文件为空');
    final name = path.toLowerCase();
    var format = 'm4a';
    if (name.endsWith('.wav')) {
      format = 'wav';
    } else if (name.endsWith('.pcm')) {
      format = 'pcm';
    } else if (name.endsWith('.amr')) {
      format = 'amr';
    } else if (name.endsWith('.mp3')) {
      format = 'mp3';
    }
    return {
      'format': format,
      'speech': base64Encode(bytes),
      'len': bytes.length,
    };
  }

  static String _utf8Body(http.Response res) {
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  static String _shortError(Object e) {
    var s = '$e'.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.startsWith('Bad state: ')) s = s.substring('Bad state: '.length);
    if (s.length > 180) s = '${s.substring(0, 180)}…';
    return s;
  }

  Future<String> _transcribeOnce(
    File file,
    AsrEndpoint ep,
    http.Client client,
  ) async {
    final base = ep.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/audio/transcriptions');
    final req = http.MultipartRequest('POST', uri);
    req.headers['Authorization'] = 'Bearer ${ep.apiKey}';
    req.fields['model'] = ep.model;
    if (ep.language != null && ep.language!.isNotEmpty) {
      req.fields['language'] = ep.language!;
    }
    if (ep.prompt != null && ep.prompt!.isNotEmpty) {
      req.fields['prompt'] = ep.prompt!;
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

    final streamed = await client.send(req);
    final raw = await streamed.stream.toBytes();
    final body = utf8.decode(raw, allowMalformed: true);
    if (streamed.statusCode >= 400) {
      throw StateError('HTTP ${streamed.statusCode}：$body');
    }
    final json = jsonDecode(body);
    if (json is Map && json['text'] != null) {
      return _preferSimplified('${json['text']}', ep.prompt);
    }
    throw StateError('转写结果为空：$body');
  }

  static String _preferSimplified(String text, String? prompt) {
    var t = text.trim();
    final p = prompt?.trim();
    if (p != null && p.isNotEmpty && t.startsWith(p)) {
      t = t.substring(p.length).trim();
    }
    final buf = StringBuffer();
    for (final ch in t.runes) {
      final s = String.fromCharCode(ch);
      buf.write(_t2s[s] ?? s);
    }
    return buf.toString();
  }

  static const _t2s = {
    '們': '们', '這': '这', '來': '来', '個': '个', '為': '为', '時': '时',
    '對': '对', '說': '说', '過': '过', '還': '还', '會': '会', '發': '发',
    '長': '长', '門': '门', '車': '车', '電': '电', '錢': '钱', '帳': '账',
    '賬': '账', '開': '开', '關': '关', '問': '问', '話': '话', '請': '请',
    '後': '后', '從': '从', '裡': '里', '裏': '里', '麼': '么', '點': '点',
    '與': '与', '於': '于', '應': '应', '當': '当', '經': '经', '現': '现',
    '實': '实', '業': '业', '書': '书', '學': '学', '習': '习', '機': '机',
    '氣': '气', '無': '无', '東': '东', '風': '风', '馬': '马', '見': '见',
    '親': '亲', '頭': '头', '體': '体', '國': '国', '種': '种', '進': '进',
    '運': '运', '選': '选', '連': '连', '遠': '远', '邊': '边', '達': '达',
    '嗎': '吗', '幾': '几', '數': '数', '據': '据', '記': '记', '錄': '录',
    '價': '价', '費': '费', '總': '总', '結': '结', '給': '给', '讓': '让',
    '認': '认', '識': '识', '誤': '误', '該': '该', '誰': '谁',
    '隻': '只', '臺': '台', '麵': '面', '乾': '干', '鬆': '松',
    '準': '准', '備': '备', '單': '单', '張': '张', '條': '条', '號': '号',
    '間': '间', '塊': '块', '萬': '万', '億': '亿',
    '兩': '两', '歲': '岁', '鐘': '钟', '錶': '表', '讀': '读', '寫': '写',
    '聽': '听', '語': '语', '詞': '词', '樣': '样', '並': '并',
  };

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
