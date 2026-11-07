import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:uuid/uuid.dart';

import '../agent/agent_models.dart';
import '../agent/agent_orchestrator.dart';
import '../agent/agent_settings.dart';
import '../agent/agent_tools.dart';
import '../agent/chat_memory.dart';
import '../agent/cloud_asr.dart';
import '../agent/simple_recorder.dart';
import '../agent/vision_client.dart';
import '../agent/vosk_asr.dart';
import '../data/app_database.dart';
import '../state/app_store.dart';
import 'agent_settings_page.dart';
import 'busy.dart';

const _welcomeText = '可以像微信一样随便聊，慢慢把事说清楚就行。\n'
    '例如：\n'
    '· 有个 302 要租给王芳\n'
    '· 房租两千八，每月 10 号收\n'
    '· 302 电表 1180 到 1234\n'
    '· 这个月心情好，302 少收 200\n'
    '· 也可点图片：附上电表照片，再说「帮我读出来录入 201」\n'
    '写操作会先让你确认。点右上角「新对话」可开干净会话。';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const _kActiveSession = 'chat_active_session_id';

  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _uuid = const Uuid();
  final _db = AppDatabase.instance;

  final _messages = <ChatMessage>[];
  final _messageIds = <int?>[];

  String? _sessionId;
  SessionSticky _sticky = SessionSticky();
  ContextUsage? _usage;
  bool _busy = false;
  bool _loading = true;
  AgentOrchestrator? _orch;

  /// true=按住说话；false=键盘输入（类似豆包切换）
  bool _voiceMode = true;
  bool _listening = false;
  bool _transcribing = false;
  String _partialVoice = '';
  final stt.SpeechToText _speech = stt.SpeechToText();
  final SimpleRecorder _recorder = SimpleRecorder();
  Timer? _ampTimer;
  bool _systemAsrOk = false;
  bool _useCloudThisHold = false;
  bool _useVoskThisHold = false;
  /// 云端级联失败后：先强制下一次用离线 Vosk；再失败才系统语音。
  bool _forceVoskNextHold = false;
  bool _forceSystemNextHold = false;
  String? _recordPath;
  bool _engineStarted = false;
  double _soundLevel = 0; // 0~1，用于脉冲条
  double _peakSound = 0;
  Completer<void>? _engineReady;
  /// 待发送的附图（发送时再看图理解）
  File? _pendingImage;

  AgentOrchestrator _ensureOrch(AppStore store) {
    return _orch ??= AgentOrchestrator(AgentToolRunner(store));
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    await AgentSettings.instance.load();
    await _ensureMic();
    await _probeSystemAsr();
  }

  Future<bool> _ensureMic({bool showError = true}) async {
    var mic = await Permission.microphone.status;
    if (!mic.isGranted) mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请允许麦克风权限（设置 → 应用 → 缘初 → 权限）'),
          ),
        );
      }
      return false;
    }
    return true;
  }

  Future<void> _probeSystemAsr() async {
    try {
      _systemAsrOk = await _speech.initialize(
        onError: (e) => debugPrint('speech error: $e'),
        onStatus: (status) => debugPrint('speech status: $status'),
      );
    } catch (e) {
      debugPrint('speech init: $e');
      _systemAsrOk = false;
    }
    if (mounted) setState(() {});
  }

  /// 有云端 Key 时默认走云端级联；失败后可强制 Vosk / 系统语音。
  bool get _shouldUseCloudAsr =>
      AgentSettings.instance.hasCloudAsr &&
      !_forceVoskNextHold &&
      !_forceSystemNextHold;

  String _voiceUnavailableTip() {
    return '没有可用的语音识别。请在 env.local 配置百度/Groq/SenseVoice，'
        '或等离线 Vosk 模型下载后重试；也可先用键盘。';
  }

  String get _asrPipelineHint =>
      '百度→Groq→SenseVoice→离线Vosk→系统语音';

  Future<void> _bootstrap() async {
    await AgentSettings.instance.load();
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_kActiveSession);
    final sessions = await _db.listChatSessions();
    if (id == null || sessions.every((s) => s.id != id)) {
      id = await _createSession(title: '新对话', activate: false);
    }
    await prefs.setString(_kActiveSession, id);
    // 滚动清理：最多保留约 40 个会话、每会话约 250 条；账本数据不动
    await _db.pruneChatStorage(preserveSessionId: id);
    await _loadSession(id);
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<String> _createSession({
    required String title,
    bool activate = true,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now();
    await _db.upsertChatSession(
      ChatSession(
        id: id,
        title: title,
        sticky: SessionSticky(),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await _db.insertChatMessage(
      StoredChatMessage(
        sessionId: id,
        role: ChatRole.assistant,
        text: _welcomeText,
        createdAt: now,
      ),
    );
    if (activate) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kActiveSession, id);
      await _loadSession(id);
      if (mounted) setState(() {});
    }
    return id;
  }

  Future<void> _loadSession(String id) async {
    final session = await _db.getChatSession(id);
    final rows = await _db.listChatMessages(id);
    if (!mounted) return;
    setState(() {
      _sessionId = id;
      _sticky = session?.sticky ?? SessionSticky();
      _messages
        ..clear()
        ..addAll(rows.map((e) => e.toUi()));
      _messageIds
        ..clear()
        ..addAll(rows.map((e) => e.id));
      _usage = null;
    });
    _scrollToEnd();
  }

  Future<void> _newChat() async {
    if (_busy) return;
    await _createSession(title: '新对话');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已开新对话，之前的还在「历史」里')),
    );
  }

  Future<void> _pickSession() async {
    final sessions = await _db.listChatSessions();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text('历史对话', style: Theme.of(ctx).textTheme.titleMedium),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: sessions.length,
                  itemBuilder: (_, i) {
                    final s = sessions[i];
                    final active = s.id == _sessionId;
                    return ListTile(
                      selected: active,
                      title: Text(s.title),
                      subtitle: Text(
                        _formatTime(s.updatedAt),
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                      trailing: active
                          ? const Icon(Icons.check)
                          : IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                if (sessions.length <= 1) return;
                                await _db.deleteChatSession(s.id);
                                if (s.id == _sessionId) {
                                  final rest = await _db.listChatSessions();
                                  if (rest.isEmpty) {
                                    await _createSession(title: '新对话');
                                  } else {
                                    final prefs =
                                        await SharedPreferences.getInstance();
                                    await prefs.setString(
                                      _kActiveSession,
                                      rest.first.id,
                                    );
                                    await _loadSession(rest.first.id);
                                  }
                                }
                                if (ctx.mounted) Navigator.pop(ctx);
                              },
                            ),
                      onTap: () async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setString(_kActiveSession, s.id);
                        await _loadSession(s.id);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatTime(DateTime t) {
    final l = t.toLocal();
    return '${l.month}/${l.day} ${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _ampTimer?.cancel();
    _speech.stop();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _markEngineReady(bool started) {
    _engineStarted = started;
    if (mounted) setState(() {});
    final c = _engineReady;
    if (c != null && !c.isCompleted) c.complete();
  }

  void _onHoldStart() {
    if (_busy || _transcribing) return;
    _engineStarted = false;
    _peakSound = 0;
    _engineReady = Completer<void>();
    setState(() {
      _listening = true;
      _partialVoice = '';
      _soundLevel = 0;
    });
    unawaited(_beginCapture());
  }

  Future<void> _beginCapture() async {
    await AgentSettings.instance.load();
    if (!await _ensureMic(showError: true)) {
      _markEngineReady(false);
      if (mounted) setState(() => _listening = false);
      return;
    }

    _useCloudThisHold = false;
    _useVoskThisHold = false;

    if (_forceVoskNextHold ||
        (!_shouldUseCloudAsr && !_forceSystemNextHold)) {
      // 强制 Vosk，或没有云端 Key 时优先试离线
      if (_forceVoskNextHold || !AgentSettings.instance.hasCloudAsr) {
        final ok = await _ensureVoskReady();
        _forceVoskNextHold = false;
        if (ok) {
          _useVoskThisHold = true;
          await _startVoskListen();
          return;
        }
        // 离线失败则继续尝试系统语音
        _forceSystemNextHold = true;
      }
    }

    if (_shouldUseCloudAsr) {
      _useCloudThisHold = true;
      await _startCloudRecord();
      return;
    }

    if (_systemAsrOk || _forceSystemNextHold) {
      _forceSystemNextHold = false;
      await _startSystemListen();
      return;
    }

    _markEngineReady(false);
    if (mounted) {
      setState(() => _listening = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_voiceUnavailableTip()),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<bool> _ensureVoskReady() async {
    if (!Platform.isAndroid) return false;
    try {
      if (mounted) {
        setState(() => _partialVoice = '准备离线识别…');
      }
      await VoskAsr.instance.prepare(
        onProgress: (p, tip) {
          if (!mounted) return;
          setState(() => _partialVoice = tip);
        },
      );
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('离线模型未就绪：$e'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
      return false;
    }
  }

  Future<void> _startVoskListen() async {
    try {
      await VoskAsr.instance.startListening(
        onPartial: (t) {
          if (!mounted || !_listening) return;
          if (!_engineStarted) _markEngineReady(true);
          setState(() {
            _partialVoice = t;
            _soundLevel = t.isEmpty ? 0.2 : 0.55;
            if (t.isNotEmpty) _peakSound = 0.5;
          });
        },
      );
      _markEngineReady(true);
      _peakSound = 0.3;
    } catch (e) {
      _markEngineReady(false);
      if (mounted) {
        setState(() => _listening = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法开始离线识别：$e')),
        );
      }
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
        if (!mounted || !_listening) return;
        try {
          final n = await _recorder.amplitude();
          if (!mounted || !_listening) return;
          if (n > _peakSound) _peakSound = n;
          if (!_engineStarted) _markEngineReady(true);
          setState(() => _soundLevel = n);
        } catch (_) {}
      });
      _markEngineReady(true);
    } catch (e) {
      _markEngineReady(false);
      if (mounted) {
        setState(() => _listening = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法开始录音：$e')),
        );
      }
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

    if (!mounted || !_listening) {
      _markEngineReady(false);
      return;
    }

    try {
      final listenFuture = _speech.listen(
        onResult: (result) {
          if (!mounted) return;
          if (!_engineStarted) _markEngineReady(true);
          setState(() => _partialVoice = result.recognizedWords);
        },
        onSoundLevelChange: (level) {
          if (!mounted || !_listening) return;
          if (!_engineStarted) _markEngineReady(true);
          final n = (level / 8.0).clamp(0.0, 1.0);
          if (n > _peakSound) _peakSound = n;
          setState(() => _soundLevel = n);
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
        if (!mounted || !_listening) break;
        if (_speech.isListening) {
          _markEngineReady(true);
          break;
        }
      }
      if (!_engineStarted) {
        final ok = await listenFuture.timeout(
          const Duration(milliseconds: 400),
          onTimeout: () => _speech.isListening,
        );
        _markEngineReady(ok || _speech.isListening);
      } else {
        unawaited(listenFuture.catchError((_) => false));
      }
    } catch (e) {
      _markEngineReady(false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法开始录音：$e')),
        );
      }
    } finally {
      final c = _engineReady;
      if (c != null && !c.isCompleted) c.complete();
    }
  }

  Future<void> _onHoldEnd({required bool send}) async {
    if (!_listening && !_transcribing) {
      await _speech.stop();
      try {
        await _recorder.stop();
      } catch (_) {}
      return;
    }

    try {
      await _engineReady?.future.timeout(const Duration(seconds: 2));
    } catch (_) {}

    if (_useCloudThisHold) {
      await _finishCloudHold(send: send);
    } else if (_useVoskThisHold) {
      await _finishVoskHold(send: send);
    } else {
      await _finishSystemHold(send: send);
    }
  }

  Future<void> _finishVoskHold({required bool send}) async {
    final text = await VoskAsr.instance.stopListening();
    if (!mounted) return;
    setState(() {
      _listening = false;
      _partialVoice = '';
      _soundLevel = 0;
      _engineStarted = false;
      _useVoskThisHold = false;
    });
    if (!send) return;
    if (text.isEmpty) {
      _forceSystemNextHold = true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('离线未识别出文字。请再按住说一次（将试系统语音），或用键盘'),
        ),
      );
      return;
    }
    _input.text = text;
    await _send();
  }

  Future<void> _finishSystemHold({required bool send}) async {
    if (_engineStarted) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    await _speech.stop();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final text = _partialVoice.trim();
    final hadEngine = _engineStarted;
    final peak = _peakSound;
    if (!mounted) return;
    setState(() {
      _listening = false;
      _partialVoice = '';
      _soundLevel = 0;
      _engineStarted = false;
    });
    if (!send) return;
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            !hadEngine
                ? '系统语音没开起来。建议改用云端语音（对话设置里开）'
                : peak < 0.12
                    ? '几乎没检测到声音'
                    : '有声音但没识别出文字，可改用云端语音或键盘',
          ),
        ),
      );
      return;
    }
    _input.text = text;
    await _send();
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

    if (!mounted) return;
    setState(() {
      _listening = false;
      _soundLevel = 0;
      _engineStarted = false;
    });

    if (!send) {
      if (path != null) {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
      return;
    }

    if (path == null || !File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有录到声音，请按住再说一次')),
      );
      return;
    }
    if (_peakSound < 0.08) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('几乎没检测到声音，请靠近麦克风大声说')),
      );
      try {
        File(path).deleteSync();
      } catch (_) {}
      return;
    }

    setState(() {
      _transcribing = true;
      _partialVoice = '正在转写…';
    });
    try {
      final result = await CloudAsr(AgentSettings.instance).transcribeFile(
        File(path),
        onEngine: (name) {
          if (!mounted) return;
          setState(() => _partialVoice = '正在试 $name…');
        },
      );
      if (!mounted) return;
      if (result.text.isEmpty) {
        _offerVoskFallback('云端没有识别出文字');
        return;
      }
      _input.text = result.text;
      await _send();
    } catch (e) {
      if (!mounted) return;
      _offerVoskFallback('云端级联未成功：$e');
    } finally {
      try {
        File(path).deleteSync();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _transcribing = false;
          _partialVoice = '';
        });
      }
    }
  }

  /// 不阻塞转写结束：先提示再按住，模型在后台预热。
  void _offerVoskFallback(String reason) {
    if (!mounted) return;
    final short = reason.length > 120 ? '${reason.substring(0, 120)}…' : reason;
    if (Platform.isAndroid) {
      _forceVoskNextHold = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$short\n请再按住说一次（离线识别）；模型会在后台准备'),
          duration: const Duration(seconds: 5),
        ),
      );
      unawaited(VoskAsr.instance.prepare().catchError((_) {}));
      return;
    }
    if (_systemAsrOk) {
      _forceSystemNextHold = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$short\n请再按住说一次（将用系统语音）'),
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$short\n请用键盘输入。'),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  Widget _voicePulse(BuildContext context) {
    final level = _soundLevel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
            Text(
            _transcribing
                ? '正在转写（$_asrPipelineHint）…'
                : _partialVoice.isEmpty
                    ? ((_engineStarted ||
                            _speech.isListening ||
                            _useVoskThisHold)
                        ? (_useCloudThisHold
                            ? '正在录音…松手后云端转写'
                            : (_useVoskThisHold
                                ? '正在用离线 Vosk 听…'
                                : '正在用系统语音听…'))
                        : '正在打开麦克风…')
                    : '识别中：$_partialVoice',
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Row(
            children: List.generate(12, (i) {
              final threshold = (i + 1) / 12;
              final active = level >= threshold * 0.85;
              final h = 6.0 + (active ? level * 18 : level * 4);
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 60),
                    height: h.clamp(4, 24),
                    decoration: BoxDecoration(
                      color: active
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context)
                              .colorScheme
                              .outlineVariant
                              .withOpacity(0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Future<void> _attachImage() async {
    if (_busy || _transcribing || _sessionId == null) return;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选图'),
              subtitle: const Text('作为附件；发送时按你的说明看图做事'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final x = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1280,
      imageQuality: 70,
    );
    if (x == null) return;
    if (!mounted) return;
    setState(() {
      _pendingImage = File(x.path);
      // 保持当前语音/键盘模式；默认仍是按住说话
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _voiceMode
              ? '已附上图片。按住说话说明要求，松开发送（如：读出水表录入 401）'
              : '已附上图片。写上要求后点发送（如：读出水表录入 401）',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _send() async {
    final typed = _input.text.trim();
    final image = _pendingImage;
    if ((typed.isEmpty && image == null) || _busy || _sessionId == null) {
      return;
    }
    final store = context.read<AppStore>();
    final orch = _ensureOrch(store);
    await AgentSettings.instance.load();

    var textForAgent = typed;
    var textForBubble = typed;
    if (image != null) {
      final vision = VisionClient(AgentSettings.instance);
      if (!vision.available) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '附图识图需要：免费智谱 ZHIPU_API_KEY（open.bigmodel.cn），'
              '或 DeepSeek LLM_API_KEY（高级·付费，官方 deepseek-flash）。'
              '填好后重新打包。',
            ),
            duration: Duration(seconds: 6),
          ),
        );
        return;
      }
      try {
        final result = await runBusy(
          context,
          message: '正在识图…',
          task: () => vision.understand(
                image: image,
                userText: typed.isEmpty
                    ? '请读出图中电表/水表等读数或关键金额'
                    : typed,
              ),
        );
        final ask = typed.isEmpty ? '请根据附图理解执行合适操作' : typed;
        textForAgent =
            '$ask\n\n【附图理解 · ${result.source}】\n${result.text}\n'
            '请根据附图理解执行用户要求；写操作仍须先提议确认。';
        textForBubble = '$ask\n\n📷 已附图（${result.source}）\n${result.text}';
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('看图失败：$e'),
            duration: const Duration(seconds: 6),
          ),
        );
        return;
      }
    }

    final sessionId = _sessionId!;
    final userMsg = ChatMessage(role: ChatRole.user, text: textForBubble);
    final prior = List<ChatMessage>.from(_messages);

    setState(() {
      _messages.add(userMsg);
      _messageIds.add(null);
      _input.clear();
      _pendingImage = null;
      _busy = true;
    });
    _scrollToEnd();

    final userRowId = await _db.insertChatMessage(
      StoredChatMessage(
        sessionId: sessionId,
        role: ChatRole.user,
        text: textForBubble,
        createdAt: DateTime.now(),
      ),
    );
    if (mounted) {
      setState(() => _messageIds[_messageIds.length - 1] = userRowId);
    }

    // 首条用户话当作标题
    if (prior.length <= 1) {
      final titleSeed = typed.isNotEmpty ? typed : textForBubble;
      final title =
          titleSeed.length > 18 ? '${titleSeed.substring(0, 18)}…' : titleSeed;
      await _db.updateChatSessionTitle(sessionId, title);
    }

    try {
      final turn = await orch.handleTurn(
        userText: textForAgent,
        priorMessages: prior,
        sticky: _sticky,
      );
      if (!mounted) return;

      await _db.updateChatSessionSticky(sessionId, turn.sticky);
      await _db.touchChatSession(sessionId);

      final assistant = ChatMessage(
        role: ChatRole.assistant,
        text: turn.reply.text,
        pending: turn.reply.pending,
      );
      final aid = await _db.insertChatMessage(
        StoredChatMessage(
          sessionId: sessionId,
          role: ChatRole.assistant,
          text: assistant.text,
          pending: assistant.pending,
          createdAt: DateTime.now(),
        ),
      );

      setState(() {
        _sticky = turn.sticky;
        _usage = turn.usage;
        _messages.add(assistant);
        _messageIds.add(aid);
      });
    } catch (e) {
      if (!mounted) return;
      final err = ChatMessage(role: ChatRole.assistant, text: '出错了：$e');
      final aid = await _db.insertChatMessage(
        StoredChatMessage(
          sessionId: sessionId,
          role: ChatRole.assistant,
          text: err.text,
          createdAt: DateTime.now(),
        ),
      );
      setState(() {
        _messages.add(err);
        _messageIds.add(aid);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
      _scrollToEnd();
    }
  }

  Future<void> _confirm(int index, PendingAction action) async {
    final store = context.read<AppStore>();
    final orch = _ensureOrch(store);
    final msgId = index < _messageIds.length ? _messageIds[index] : null;
    setState(() => _busy = true);
    try {
      await runBusy(
        context,
        message: '正在执行…',
        task: () async {
          final result = await orch.confirm(action);
          if (!mounted) return;
          if (msgId != null) {
            await _db.updateChatMessageConfirmation(
              id: msgId,
              confirmed: true,
            );
          }
          // 任意写操作确认后清掉意图/租约草稿槽，只保留房号与摘要，避免后续话被「登记租约」劫持
          if (writeTools.contains(action.tool)) {
            _sticky = SessionSticky(
              propertyName: _sticky.propertyName,
              roomLabel: _sticky.roomLabel,
              summary: _sticky.summary,
            );
            await _db.updateChatSessionSticky(_sessionId!, _sticky);
          }
          final follow = ChatMessage(role: ChatRole.assistant, text: result);
          final aid = await _db.insertChatMessage(
            StoredChatMessage(
              sessionId: _sessionId!,
              role: ChatRole.assistant,
              text: follow.text,
              createdAt: DateTime.now(),
            ),
          );
          if (!mounted) return;
          setState(() {
            _messages[index] = ChatMessage(
              role: ChatRole.assistant,
              text: _messages[index].text,
              pending: action,
              confirmed: true,
            );
            _messages.add(follow);
            _messageIds.add(aid);
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      final err = ChatMessage(role: ChatRole.assistant, text: '执行失败：$e');
      final aid = await _db.insertChatMessage(
        StoredChatMessage(
          sessionId: _sessionId!,
          role: ChatRole.assistant,
          text: err.text,
          createdAt: DateTime.now(),
        ),
      );
      setState(() {
        _messages.add(err);
        _messageIds.add(aid);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
      _scrollToEnd();
    }
  }

  Future<void> _cancel(int index, PendingAction action) async {
    final msgId = index < _messageIds.length ? _messageIds[index] : null;
    if (msgId != null) {
      await _db.updateChatMessageConfirmation(id: msgId, confirmed: false);
    }
    const follow = ChatMessage(
      role: ChatRole.assistant,
      text: '已取消，没有改动数据。',
    );
    final aid = await _db.insertChatMessage(
      StoredChatMessage(
        sessionId: _sessionId!,
        role: ChatRole.assistant,
        text: follow.text,
        createdAt: DateTime.now(),
      ),
    );
    setState(() {
      _messages[index] = ChatMessage(
        role: ChatRole.assistant,
        text: _messages[index].text,
        pending: action,
        confirmed: false,
      );
      _messages.add(follow);
      _messageIds.add(aid);
    });
  }

  void _scrollToEnd() {
    // reverse:true 时 offset 0 就是最新消息，无需滚到底
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      if (_scroll.offset != 0) {
        _scroll.jumpTo(0);
      }
    });
  }

  Widget _usageBar(BuildContext context) {
    final u = _usage;
    final pct = u?.percent ?? 0;
    final color = pct >= 85
        ? Theme.of(context).colorScheme.error
        : pct >= 60
            ? Colors.orange.shade800
            : Theme.of(context).colorScheme.onSurfaceVariant;
    final stickyHint = _sticky.isEmpty
        ? ''
        : ' · 已记${[
            if (_sticky.roomLabel != null) _sticky.roomLabel!,
            if (_sticky.tenantName != null) _sticky.tenantName!,
          ].join('/')}';
    return Material(
      color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.65),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    u == null
                        ? '闲聊记账 · 可开新对话清上下文'
                        : '记忆约 $pct%（${u.usedTokens}/${u.windowTokens}）'
                            '${u.droppedMessages > 0 ? ' · 早先已摘要' : ''}'
                            '$stickyHint',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: color,
                        ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (u != null) ...[
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: (u.ratio).clamp(0.0, 1.0),
                        minHeight: 3,
                        color: color,
                        backgroundColor:
                            Theme.of(context).colorScheme.surfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: '历史对话',
              onPressed: _busy ? null : _pickSession,
              icon: const Icon(Icons.history),
            ),
            IconButton(
              tooltip: '新对话',
              onPressed: _busy ? null : _newChat,
              icon: const Icon(Icons.add_comment_outlined),
            ),
            IconButton(
              tooltip: 'Agent 设置',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AgentSettingsPage(),
                  ),
                );
              },
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        _usageBar(context),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            // 从下往上堆：打开即见最新，避免首屏空白要往下拉
            reverse: true,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            itemCount: _messages.length + (_busy ? 1 : 0),
            itemBuilder: (context, i) {
              if (_busy && i == 0) {
                return const Padding(
                  padding: EdgeInsets.all(12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('思考中…'),
                  ),
                );
              }
              final msgIndex =
                  _messages.length - 1 - (i - (_busy ? 1 : 0));
              final m = _messages[msgIndex];
              final isUser = m.role == ChatRole.user;
              return Align(
                alignment:
                    isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.86,
                  ),
                  decoration: BoxDecoration(
                    color: isUser
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.text),
                      if (m.pending != null && m.confirmed == null) ...[
                        const SizedBox(height: 10),
                        Text(
                          m.pending!.summary,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FilledButton(
                              onPressed: _busy
                                  ? null
                                  : () => _confirm(msgIndex, m.pending!),
                              child: const Text('确认执行'),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _cancel(msgIndex, m.pending!),
                              child: const Text('取消'),
                            ),
                          ],
                        ),
                      ],
                      if (m.confirmed == true)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '已确认',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      if (m.confirmed == false)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '已取消',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const Divider(height: 1),
        if (_listening || _transcribing) _voicePulse(context),
        if (_pendingImage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    _pendingImage!,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _voiceMode
                        ? '已附图 · 按住说话说明要求后松开'
                        : '已附图 · 写上要求后点发送',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                IconButton(
                  tooltip: '去掉图片',
                  onPressed: _busy
                      ? null
                      : () => setState(() => _pendingImage = null),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: _voiceMode
                      ? GestureDetector(
                          // 长按手势：按下约 0.3s 起效，反馈稳定（小米上比 Listener 可靠）
                          onLongPressStart: (_) => _onHoldStart(),
                          onLongPressEnd: (_) => _onHoldEnd(send: true),
                          onLongPressCancel: () => _onHoldEnd(send: false),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            height: 48,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: _listening
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceVariant,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant,
                              ),
                            ),
                            child: Text(
                              _listening ? '松开发送…' : '按住说话',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(
                                    color: _listening
                                        ? Theme.of(context)
                                            .colorScheme
                                            .onPrimary
                                        : null,
                                  ),
                            ),
                          ),
                        )
                      : TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            hintText: '随便说，比如：302 要租给王芳…',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                ),
                const SizedBox(width: 2),
                IconButton(
                  tooltip: '附图（看图做事）',
                  onPressed: _busy || _transcribing ? null : _attachImage,
                  icon: Icon(
                    _pendingImage == null
                        ? Icons.image_outlined
                        : Icons.image,
                  ),
                ),
                IconButton(
                  tooltip: _voiceMode ? '切换键盘' : '切换语音',
                  onPressed: _busy || _transcribing
                      ? null
                      : () async {
                          final toVoice = !_voiceMode;
                          setState(() {
                            _voiceMode = toVoice;
                            if (_listening) {
                              _speech.stop();
                              _listening = false;
                              _partialVoice = '';
                            }
                          });
                          if (toVoice) {
                            await AgentSettings.instance.load();
                            await _ensureMic(showError: true);
                            if (!AgentSettings.instance.hasCloudAsr &&
                                !_systemAsrOk &&
                                mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(_voiceUnavailableTip()),
                                  duration: const Duration(seconds: 5),
                                ),
                              );
                            }
                          }
                        },
                  icon: Icon(
                    _voiceMode ? Icons.keyboard_alt_outlined : Icons.mic_none,
                  ),
                ),
                if (!_voiceMode)
                  FilledButton(
                    onPressed: _busy ? null : _send,
                    child: const Text('发送'),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
