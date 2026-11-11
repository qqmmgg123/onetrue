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

/// 公共语音采集：找 AI / 笔记 AI / 笔记输入框共用。
/// UI 监听 [notifyListeners]；按住结束得到文字后走 [onTranscript]。
class VoiceCapture extends ChangeNotifier {
  VoiceCapture({this.onTranscript, this.onStatus});

  /// 识别出完整一句后的回调（松手发送）。
  void Function(String text)? onTranscript;

  /// 失败/空结果时的短提示（可选）。
  void Function(String message)? onStatus;

  final stt.SpeechToText _speech = stt.SpeechToText();
  final SimpleRecorder _recorder = SimpleRecorder();
  Timer? _ampTimer;

  bool systemAsrOk = false;
  bool listening = false;
  bool transcribing = false;
  String partial = '';
  double soundLevel = 0;
  double peakSound = 0;
  bool engineStarted = false;

  bool _useCloudThisHold = false;
  bool _useVoskThisHold = false;
  bool _forceVoskNextHold = false;
  bool _forceSystemNextHold = false;
  String? _recordPath;
  Completer<void>? _engineReady;
  /// 录音路线（云端/Vosk/系统）已选定并启动，或已失败收尾。
  Completer<void>? _routeReady;
  int _holdSeq = 0;

  bool get shouldUseCloudAsr =>
      AgentSettings.instance.hasCloudAsr &&
      !_forceVoskNextHold &&
      !_forceSystemNextHold;

  String get asrPipelineHint => '百度→Groq→SenseVoice→离线Vosk→系统语音';

  String get statusLine {
    if (transcribing) return '正在转写（$asrPipelineHint）…';
    if (partial.isNotEmpty) return '识别中：$partial';
    if (!listening) return '';
    if (engineStarted || _speech.isListening || _useVoskThisHold) {
      if (_useCloudThisHold) return '正在录音…松手后云端转写';
      if (_useVoskThisHold) return '正在用离线 Vosk 听…';
      return '正在用系统语音听…';
    }
    return '正在打开麦克风…';
  }

  Future<void> init() async {
    await AgentSettings.instance.load();
    await ensureMic(showError: false);
    await _probeSystemAsr();
  }

  Future<bool> ensureMic({bool showError = true}) async {
    var mic = await Permission.microphone.status;
    if (!mic.isGranted) mic = await Permission.microphone.request();
    if (!mic.isGranted && showError) {
      onStatus?.call('请允许麦克风权限');
    }
    return mic.isGranted;
  }

  Future<void> _probeSystemAsr() async {
    try {
      systemAsrOk = await _speech.initialize(
        onError: (e) => debugPrint('speech error: $e'),
        onStatus: (status) => debugPrint('speech status: $status'),
      );
    } catch (e) {
      debugPrint('speech init: $e');
      systemAsrOk = false;
    }
    notifyListeners();
  }

  String unavailableTip() =>
      '没有可用的语音识别。请配置语音 Key，或等离线 Vosk 就绪；也可先用键盘。';

  void _completeRoute() {
    final c = _routeReady;
    if (c != null && !c.isCompleted) c.complete();
  }

  void onHoldStart() {
    if (transcribing) return;
    _holdSeq++;
    final seq = _holdSeq;
    engineStarted = false;
    peakSound = 0;
    _engineReady = Completer<void>();
    _routeReady = Completer<void>();
    _useCloudThisHold = false;
    _useVoskThisHold = false;
    listening = true;
    partial = '';
    soundLevel = 0;
    notifyListeners();
    unawaited(_beginCapture(seq));
  }

  Future<void> onHoldEnd({required bool send}) async {
    if (!listening && !transcribing) {
      await _speech.stop();
      try {
        await _recorder.stop();
      } catch (_) {}
      return;
    }

    // 等路线选好，避免松手时还在 ensureMic 却误走系统语音收尾
    try {
      await _routeReady?.future.timeout(const Duration(seconds: 6));
    } catch (_) {}
    try {
      await _engineReady?.future.timeout(const Duration(seconds: 2));
    } catch (_) {}

    if (!listening && !transcribing) return;

    if (_useCloudThisHold) {
      await _finishCloudHold(send: send);
    } else if (_useVoskThisHold) {
      await _finishVoskHold(send: send);
    } else {
      await _finishSystemHold(send: send);
    }
  }

  void _markEngineReady(bool started) {
    engineStarted = started;
    notifyListeners();
    final c = _engineReady;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> _beginCapture(int seq) async {
    try {
      await AgentSettings.instance.load();
      if (seq != _holdSeq || !listening) {
        _completeRoute();
        return;
      }
      if (!await ensureMic(showError: true)) {
        _markEngineReady(false);
        listening = false;
        notifyListeners();
        onStatus?.call('请允许麦克风权限');
        return;
      }
      if (seq != _holdSeq || !listening) return;

      if (_forceVoskNextHold ||
          (!shouldUseCloudAsr && !_forceSystemNextHold)) {
        if (_forceVoskNextHold || !AgentSettings.instance.hasCloudAsr) {
          final ok = await _ensureVoskReady();
          _forceVoskNextHold = false;
          if (seq != _holdSeq || !listening) return;
          if (ok) {
            _useVoskThisHold = true;
            _completeRoute();
            await _startVoskListen();
            return;
          }
          _forceSystemNextHold = true;
        }
      }

      if (seq != _holdSeq || !listening) return;

      if (shouldUseCloudAsr) {
        _useCloudThisHold = true;
        _completeRoute();
        await _startCloudRecord();
        return;
      }

      if (systemAsrOk || _forceSystemNextHold) {
        _forceSystemNextHold = false;
        _completeRoute();
        await _startSystemListen();
        return;
      }

      _markEngineReady(false);
      listening = false;
      notifyListeners();
      onStatus?.call(unavailableTip());
    } finally {
      _completeRoute();
    }
  }

  Future<bool> _ensureVoskReady() async {
    if (!Platform.isAndroid) return false;
    try {
      partial = '准备离线识别…';
      notifyListeners();
      await VoskAsr.instance.prepare(
        onProgress: (p, tip) {
          partial = tip;
          notifyListeners();
        },
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startVoskListen() async {
    try {
      await VoskAsr.instance.startListening(
        onPartial: (t) {
          if (!listening) return;
          if (!engineStarted) _markEngineReady(true);
          partial = t;
          soundLevel = t.isEmpty ? 0.2 : 0.55;
          if (t.isNotEmpty) peakSound = 0.5;
          notifyListeners();
        },
      );
      _markEngineReady(true);
      peakSound = 0.3;
    } catch (_) {
      _markEngineReady(false);
      listening = false;
      notifyListeners();
      onStatus?.call('无法开始离线识别');
    }
  }

  Future<void> _startCloudRecord() async {
    try {
      final dir = await getTemporaryDirectory();
      _recordPath = p.join(
        dir.path,
        'asr_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      await _recorder.start(_recordPath!);
      _ampTimer?.cancel();
      _ampTimer = Timer.periodic(const Duration(milliseconds: 80), (_) async {
        if (!listening) return;
        try {
          final n = await _recorder.amplitude();
          if (!listening) return;
          if (n > peakSound) peakSound = n;
          if (!engineStarted) _markEngineReady(true);
          soundLevel = n;
          notifyListeners();
        } catch (_) {}
      });
      _markEngineReady(true);
    } catch (_) {
      _markEngineReady(false);
      listening = false;
      notifyListeners();
      onStatus?.call('无法开始录音');
    }
  }

  Future<void> _startSystemListen() async {
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

    if (!listening) {
      _markEngineReady(false);
      return;
    }

    try {
      final listenFuture = _speech.listen(
        onResult: (result) {
          if (!engineStarted) _markEngineReady(true);
          partial = result.recognizedWords;
          notifyListeners();
        },
        onSoundLevelChange: (level) {
          if (!listening) return;
          if (!engineStarted) _markEngineReady(true);
          final n = (level / 8.0).clamp(0.0, 1.0);
          if (n > peakSound) peakSound = n;
          soundLevel = n;
          notifyListeners();
        },
        localeId: localeId,
        listenMode: stt.ListenMode.dictation,
        partialResults: true,
        cancelOnError: true,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 8),
      );

      for (var i = 0; i < 15; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!listening) break;
        if (_speech.isListening) {
          _markEngineReady(true);
          break;
        }
      }
      if (!engineStarted) {
        final ok = await listenFuture.timeout(
          const Duration(milliseconds: 400),
          onTimeout: () => _speech.isListening,
        );
        _markEngineReady(ok || _speech.isListening);
      } else {
        unawaited(listenFuture.catchError((_) => false));
      }
    } catch (_) {
      _markEngineReady(false);
      listening = false;
      notifyListeners();
      onStatus?.call('无法开始系统语音');
    } finally {
      final c = _engineReady;
      if (c != null && !c.isCompleted) c.complete();
    }
  }

  Future<void> _finishVoskHold({required bool send}) async {
    final text = await VoskAsr.instance.stopListening();
    listening = false;
    partial = '';
    soundLevel = 0;
    engineStarted = false;
    _useVoskThisHold = false;
    notifyListeners();
    if (!send) return;
    if (text.isEmpty) {
      _forceSystemNextHold = true;
      onStatus?.call('没听清，请再按住说一次');
      return;
    }
    onTranscript?.call(text);
  }

  Future<void> _finishSystemHold({required bool send}) async {
    if (engineStarted) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    await _speech.stop();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final text = partial.trim();
    listening = false;
    partial = '';
    soundLevel = 0;
    engineStarted = false;
    notifyListeners();
    if (!send) return;
    if (text.isEmpty) {
      onStatus?.call('没听清，请再按住说一次');
      return;
    }
    onTranscript?.call(text);
  }

  Future<void> _finishCloudHold({required bool send}) async {
    _ampTimer?.cancel();
    _ampTimer = null;
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      path = _recordPath;
    }
    path ??= _recordPath;

    listening = false;
    soundLevel = 0;
    engineStarted = false;
    notifyListeners();

    if (!send) {
      if (path != null) {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
      return;
    }

    if (path == null || !File(path).existsSync()) {
      onStatus?.call('没有录到声音，请按住再说一次');
      return;
    }
    if (peakSound < 0.08) {
      try {
        File(path).deleteSync();
      } catch (_) {}
      onStatus?.call('几乎没检测到声音，请靠近麦克风');
      return;
    }

    transcribing = true;
    partial = '正在转写…';
    notifyListeners();
    try {
      final result = await CloudAsr(AgentSettings.instance).transcribeFile(
        File(path),
        onEngine: (name) {
          partial = '正在试 $name…';
          notifyListeners();
        },
      );
      if (result.text.isEmpty) {
        _offerVoskFallback();
        onStatus?.call('没识别出文字，请再按住试一次');
        return;
      }
      onTranscript?.call(result.text);
    } catch (e) {
      _offerVoskFallback();
      onStatus?.call('转写失败，请再按住试一次');
    } finally {
      try {
        File(path).deleteSync();
      } catch (_) {}
      transcribing = false;
      partial = '';
      notifyListeners();
    }
  }

  void _offerVoskFallback() {
    if (Platform.isAndroid) {
      _forceVoskNextHold = true;
      unawaited(VoskAsr.instance.prepare().catchError((_) {}));
    } else if (systemAsrOk) {
      _forceSystemNextHold = true;
    }
  }

  @override
  void dispose() {
    _ampTimer?.cancel();
    unawaited(_speech.stop());
    super.dispose();
  }
}
