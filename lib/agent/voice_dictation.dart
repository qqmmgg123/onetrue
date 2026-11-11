import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'agent_settings.dart';
import 'cloud_asr.dart';
import 'simple_recorder.dart';
import 'vosk_asr.dart';

/// 笔记编辑器听写：点按切换「开麦」，说话→停顿自动出字，再点关闭。
///
/// 不依赖流式 ASR：用业界常见的 **VAD 分段**（有声段录音 → 静音切开 → 整段转写）。
/// 与 [VoiceCapture]（按住说话发消息）职责分开。
class VoiceDictation extends ChangeNotifier {
  VoiceDictation({this.onTranscript, this.onStatus});

  void Function(String text)? onTranscript;
  void Function(String message)? onStatus;

  final stt.SpeechToText _speech = stt.SpeechToText();
  final SimpleRecorder _recorder = SimpleRecorder();

  bool active = false;
  bool segmentBusy = false;
  bool transcribing = false;
  double soundLevel = 0;
  String hint = '';

  bool _systemOk = false;
  int _gen = 0;
  Timer? _poll;

  /// 音量高于此视为有声。
  static const _speechAmp = 0.11;

  /// 有声之后连续静音多久切一段（毫秒）。
  static const _silenceMs = 1100;

  /// 单段最长，避免超长文件。
  static const _maxSegment = Duration(seconds: 45);

  Future<void> init() async {
    await AgentSettings.instance.load();
    try {
      _systemOk = await _speech.initialize(
        onError: (e) => debugPrint('dictation speech: $e'),
        onStatus: (s) => debugPrint('dictation status: $s'),
      );
    } catch (_) {
      _systemOk = false;
    }
  }

  Future<void> toggle() async {
    if (active) {
      await stop();
    } else {
      await start();
    }
  }

  Future<void> start() async {
    if (active) return;
    await AgentSettings.instance.load();
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      onStatus?.call('请允许麦克风权限');
      return;
    }

    final canCloud = AgentSettings.instance.hasCloudAsr;
    final canVosk = Platform.isAndroid;
    if (!canCloud && !_systemOk && !canVosk) {
      onStatus?.call('没有可用的语音识别');
      return;
    }

    active = true;
    hint = '正在听…说完稍停会出字';
    notifyListeners();
    _gen++;
    final gen = _gen;
    unawaited(_loop(gen));
  }

  Future<void> stop() async {
    _gen++;
    active = false;
    hint = '';
    soundLevel = 0;
    _poll?.cancel();
    _poll = null;
    try {
      await _speech.stop();
    } catch (_) {}
    try {
      await _recorder.stop();
    } catch (_) {}
    try {
      await VoskAsr.instance.stopListening();
    } catch (_) {}
    segmentBusy = false;
    transcribing = false;
    notifyListeners();
  }

  Future<void> _loop(int gen) async {
    while (active && gen == _gen) {
      try {
        if (AgentSettings.instance.hasCloudAsr) {
          await _cloudSegment(gen);
        } else if (_systemOk) {
          await _systemSegment(gen);
        } else if (Platform.isAndroid) {
          await _voskSegment(gen);
        } else {
          onStatus?.call('没有可用的语音识别');
          await stop();
          return;
        }
      } catch (e) {
        debugPrint('dictation segment: $e');
        if (!active || gen != _gen) return;
        onStatus?.call('识别出错，请再试');
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
  }

  /// 云端：录音 + 振幅 VAD，静音切开后整段转写。
  Future<void> _cloudSegment(int gen) async {
    segmentBusy = true;
    notifyListeners();
    final dir = await getTemporaryDirectory();
    final path = p.join(
      dir.path,
      'dict_${DateTime.now().millisecondsSinceEpoch}.m4a',
    );
    await _recorder.start(path);

    var heard = false;
    var silence = 0;
    final started = DateTime.now();
    final tick = Completer<void>();

    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 80), (_) async {
      if (!active || gen != _gen) {
        if (!tick.isCompleted) tick.complete();
        return;
      }
      try {
        final amp = await _recorder.amplitude();
        soundLevel = amp;
        notifyListeners();
        if (amp >= _speechAmp) {
          heard = true;
          silence = 0;
        } else if (heard) {
          silence += 80;
          if (silence >= _silenceMs) {
            if (!tick.isCompleted) tick.complete();
          }
        }
        if (DateTime.now().difference(started) >= _maxSegment) {
          if (!tick.isCompleted) tick.complete();
        }
      } catch (_) {}
    });

    await tick.future;
    _poll?.cancel();
    _poll = null;

    String? file;
    try {
      file = await _recorder.stop();
    } catch (_) {
      file = path;
    }
    file ??= path;
    segmentBusy = false;
    soundLevel = 0;
    notifyListeners();

    if (!active || gen != _gen) {
      _delete(file);
      return;
    }
    if (!heard) {
      // 还没开口：丢掉空段，继续听
      _delete(file);
      return;
    }

    transcribing = true;
    hint = '正在转写…';
    notifyListeners();
    try {
      final result = await CloudAsr(AgentSettings.instance).transcribeFile(
        File(file),
        onEngine: (name) {
          hint = '正在试 $name…';
          notifyListeners();
        },
      );
      final text = result.text.trim();
      if (text.isNotEmpty && active && gen == _gen) {
        onTranscript?.call(text);
      }
    } catch (e) {
      if (active && gen == _gen) {
        onStatus?.call('转写失败，请再说一次');
      }
    } finally {
      _delete(file);
      transcribing = false;
      hint = active ? '正在听…说完稍停会出字' : '';
      notifyListeners();
    }
  }

  /// 系统语音：pauseFor 充当句间停顿，出字后若仍开麦则继续听。
  Future<void> _systemSegment(int gen) async {
    segmentBusy = true;
    hint = '正在听…说完稍停会出字';
    notifyListeners();

    String? localeId;
    try {
      final locales = await _speech.locales();
      for (final l in locales) {
        final id = l.localeId.toLowerCase();
        if (id.startsWith('zh') || id.contains('china')) {
          localeId = l.localeId;
          break;
        }
      }
    } catch (_) {}

    final done = Completer<String>();
    var last = '';

    try {
      await _speech.listen(
        onResult: (r) {
          last = r.recognizedWords.trim();
          soundLevel = last.isEmpty ? 0.2 : 0.55;
          notifyListeners();
          if (r.finalResult && !done.isCompleted) {
            done.complete(last);
          }
        },
        onSoundLevelChange: (level) {
          soundLevel = (level / 8.0).clamp(0.0, 1.0);
          notifyListeners();
        },
        localeId: localeId,
        listenMode: stt.ListenMode.dictation,
        partialResults: true,
        cancelOnError: true,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(milliseconds: 1200),
      );
    } catch (e) {
      segmentBusy = false;
      notifyListeners();
      rethrow;
    }

    String text = '';
    try {
      text = await done.future.timeout(const Duration(seconds: 62));
    } on TimeoutException {
      text = last;
    } finally {
      try {
        await _speech.stop();
      } catch (_) {}
    }

    segmentBusy = false;
    soundLevel = 0;
    notifyListeners();
    if (!active || gen != _gen) return;
    if (text.isNotEmpty) {
      onTranscript?.call(text);
    }
    // 系统引擎停顿结束会话；开麦状态下立刻进入下一段
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  Future<void> _voskSegment(int gen) async {
    segmentBusy = true;
    hint = '正在听（离线）…';
    notifyListeners();
    await VoskAsr.instance.prepare();
    if (!active || gen != _gen) {
      segmentBusy = false;
      return;
    }

    var lastPartial = '';
    var lastChange = DateTime.now();
    final started = DateTime.now();
    final cut = Completer<void>();

    await VoskAsr.instance.startListening(
      onPartial: (t) {
        if (!active || gen != _gen) return;
        if (t.trim() != lastPartial) {
          lastPartial = t.trim();
          lastChange = DateTime.now();
          soundLevel = t.isEmpty ? 0.2 : 0.55;
          notifyListeners();
        }
      },
    );

    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!active || gen != _gen) {
        if (!cut.isCompleted) cut.complete();
        return;
      }
      final quiet = DateTime.now().difference(lastChange);
      if (lastPartial.isNotEmpty && quiet.inMilliseconds >= _silenceMs) {
        if (!cut.isCompleted) cut.complete();
      }
      if (DateTime.now().difference(started) >= _maxSegment) {
        if (!cut.isCompleted) cut.complete();
      }
    });

    await cut.future;
    _poll?.cancel();
    _poll = null;
    final text = (await VoskAsr.instance.stopListening()).trim();
    segmentBusy = false;
    soundLevel = 0;
    notifyListeners();
    if (!active || gen != _gen) return;
    if (text.isNotEmpty) {
      onTranscript?.call(text);
    } else if (lastPartial.isNotEmpty) {
      onTranscript?.call(lastPartial);
    }
  }

  void _delete(String? path) {
    if (path == null) return;
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}
