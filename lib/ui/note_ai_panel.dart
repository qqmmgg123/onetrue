import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../agent/agent_models.dart';
import '../agent/agent_settings.dart';
import '../agent/chat_memory.dart';
import '../agent/llm_providers.dart';
import '../agent/vision_client.dart';
import '../agent/voice_capture.dart';
import '../data/app_database.dart';
import 'busy.dart';
import 'voice_input_bar.dart';

typedef NoteDraftGetters = ({
  String Function() title,
  String Function() plain,
  String Function() deltaJson,
  String Function() optionsJson,
});

typedef NoteDraftSetters = ({
  void Function(String title) setTitle,
  void Function(String plain) replacePlain,
  void Function(List<dynamic> delta) replaceDelta,
  void Function(Map<String, dynamic> ops) applyFormat,
  void Function(Map<String, dynamic> options) setOptions,
});

/// 笔记页下半区：只改当前草稿的 AI（与「找 AI」会话分离存储）。
class NoteAiPanel extends StatefulWidget {
  const NoteAiPanel({
    super.key,
    required this.getters,
    required this.setters,
    required this.refKey,
    required this.expanded,
    required this.onExpandedChanged,
  });

  final NoteDraftGetters getters;
  final NoteDraftSetters setters;

  /// 笔记 uuid 或 `draft:…`，用于会话隔离。
  final String refKey;
  final bool expanded;
  final ValueChanged<bool> onExpandedChanged;

  @override
  State<NoteAiPanel> createState() => _NoteAiPanelState();
}

class _NoteAiPanelState extends State<NoteAiPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _db = AppDatabase.instance;
  final _uuid = const Uuid();
  late final VoiceCapture _voice;

  final _messages = <ChatMessage>[];
  final _messageIds = <int?>[];
  String? _sessionId;
  bool _busy = false;
  bool _loading = true;
  bool _voiceMode = true;
  File? _pendingImage;

  static const _welcome =
      '我可以帮你改上方这篇：润色、排版、改形态/提醒/重复/上架…\n'
      '点右上角可开新对话；历史只属于这篇笔记。';

  static const _system = '''
你是「醍醐」笔记编辑助手。上方是用户正在写的草稿及其选项。
职责：改写/排版正文，以及改当前这篇的形态与选项；不要改其他笔记。
可用工具（立刻改草稿，无需确认）：
- set_title：改标题
- replace_draft / replace_delta：替换正文
- apply_format：套格式
- set_note_options：改形态与选项。字段：kind(note|memo|schedule|article)、schedule_at、remind_at(备忘绝对提醒，空串清空)、recur_freq(once|daily|weekly|monthly|yearly)、recur_byday(如MO)、recur_until(结束日，与count互斥)、recur_count(次数)、remind_offset_min(日程提前分钟，0=开始时)、listed(文章上架)、city
重复结束：永不=不传until/count或都空；结束日用recur_until；次数用recur_count。
回复尽量短。
''';

  static final _tools = [
    {
      'type': 'function',
      'function': {
        'name': 'set_title',
        'description': '设置笔记标题',
        'parameters': {
          'type': 'object',
          'properties': {'title': {'type': 'string'}},
          'required': ['title'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'replace_draft',
        'description': '用纯文本替换整篇正文',
        'parameters': {
          'type': 'object',
          'properties': {'plain': {'type': 'string'}},
          'required': ['plain'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'replace_delta',
        'description': '用 Quill Delta JSON 替换整篇正文',
        'parameters': {
          'type': 'object',
          'properties': {
            'delta': {'type': 'array', 'items': {'type': 'object'}},
          },
          'required': ['delta'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'apply_format',
        'description': '对选区或整篇应用富文本格式',
        'parameters': {
          'type': 'object',
          'properties': {
            'bold': {'type': 'boolean'},
            'header': {'type': 'integer'},
            'list': {
              'type': 'string',
              'enum': ['ordered', 'bullet', 'none'],
            },
            'align': {
              'type': 'string',
              'enum': ['left', 'center', 'right'],
            },
            'size': {
              'type': 'string',
              'enum': ['small', 'large', 'huge'],
            },
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'set_note_options',
        'description': '改当前草稿形态与日程/备忘/文章选项',
        'parameters': {
          'type': 'object',
          'properties': {
            'kind': {'type': 'string'},
            'title': {'type': 'string'},
            'schedule_at': {'type': 'string'},
            'remind_at': {'type': 'string'},
            'recur_freq': {'type': 'string'},
            'recur_byday': {'type': 'string'},
            'recur_until': {'type': 'string'},
            'recur_count': {'type': 'integer'},
            'remind_offset_min': {'type': 'integer'},
            'listed': {'type': 'boolean'},
            'city': {'type': 'string'},
          },
        },
      },
    },
  ];

  String get _prefsKey => 'note_ai_session_${widget.refKey}';

  @override
  void initState() {
    super.initState();
    _voice = VoiceCapture(
      onTranscript: _onVoiceText,
      onStatus: (msg) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
        );
      },
    );
    _voice.addListener(_onVoiceTick);
    _voice.init();
    _bootstrap();
  }

  @override
  void didUpdateWidget(covariant NoteAiPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refKey != widget.refKey) {
      _bootstrap();
    }
  }

  void _onVoiceTick() {
    if (mounted) setState(() {});
  }

  void _onVoiceText(String text) {
    _input.text = text;
    _send();
  }

  Future<void> _bootstrap() async {
    setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_prefsKey);
    final sessions = await _db.listChatSessions(
      kind: kChatKindNote,
      refKey: widget.refKey,
    );
    if (id == null || sessions.every((s) => s.id != id)) {
      id = await _createSession(activate: false);
    }
    await prefs.setString(_prefsKey, id);
    await _db.pruneChatStorage(
      preserveSessionId: id,
      kind: kChatKindNote,
      refKey: widget.refKey,
      maxSessions: 20,
      maxMessagesPerSession: 120,
    );
    await _loadSession(id);
    if (mounted) setState(() => _loading = false);
  }

  Future<String> _createSession({bool activate = true}) async {
    final id = _uuid.v4();
    final now = DateTime.now();
    await _db.upsertChatSession(
      ChatSession(
        id: id,
        title: '笔记对话',
        sticky: SessionSticky(),
        createdAt: now,
        updatedAt: now,
        kind: kChatKindNote,
        refKey: widget.refKey,
      ),
    );
    await _db.insertChatMessage(
      StoredChatMessage(
        sessionId: id,
        role: ChatRole.assistant,
        text: _welcome,
        createdAt: now,
      ),
    );
    if (activate) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, id);
      await _loadSession(id);
    }
    return id;
  }

  Future<void> _loadSession(String id) async {
    final rows = await _db.listChatMessages(id);
    if (!mounted) return;
    setState(() {
      _sessionId = id;
      _messages
        ..clear()
        ..addAll(rows.map((e) => e.toUi()));
      _messageIds
        ..clear()
        ..addAll(rows.map((e) => e.id));
    });
  }

  Future<void> _newChat() async {
    if (_busy) return;
    await _createSession();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已开新对话（仅本篇笔记）')),
    );
  }

  Future<void> _pickSession() async {
    var sessions = await _db.listChatSessions(
      kind: kChatKindNote,
      refKey: widget.refKey,
    );
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setSheet) {
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '本篇笔记的对话',
                            style: Theme.of(ctx).textTheme.titleMedium,
                          ),
                        ),
                        TextButton(
                          onPressed: sessions.isEmpty
                              ? null
                              : () async {
                                  final ok = await showDialog<bool>(
                                    context: ctx,
                                    builder: (d) => AlertDialog(
                                      title: const Text('清除本篇全部对话？'),
                                      content: const Text(
                                        '只清这篇笔记下的 AI 聊天，不影响找 AI 和笔记正文。',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(d, false),
                                          child: const Text('取消'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(d, true),
                                          child: const Text('清除'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok != true) return;
                                  await _db.deleteAllChatSessions(
                                    kind: kChatKindNote,
                                    refKey: widget.refKey,
                                  );
                                  await _createSession();
                                  sessions = await _db.listChatSessions(
                                    kind: kChatKindNote,
                                    refKey: widget.refKey,
                                  );
                                  if (ctx.mounted) setSheet(() {});
                                },
                          child: const Text('清除全部'),
                        ),
                      ],
                    ),
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
                          trailing: active
                              ? const Icon(Icons.check)
                              : IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    if (sessions.length <= 1) return;
                                    await _db.deleteChatSession(s.id);
                                    if (s.id == _sessionId) {
                                      await _createSession();
                                    }
                                    sessions = await _db.listChatSessions(
                                      kind: kChatKindNote,
                                      refKey: widget.refKey,
                                    );
                                    if (ctx.mounted) setSheet(() {});
                                  },
                                ),
                          onTap: () async {
                            final prefs =
                                await SharedPreferences.getInstance();
                            await prefs.setString(_prefsKey, s.id);
                            await _loadSession(s.id);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _attachImage() async {
    if (_busy || _voice.transcribing) return;
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
    if (x == null || !mounted) return;
    setState(() => _pendingImage = File(x.path));
  }

  Future<void> _send() async {
    final typed = _input.text.trim();
    final image = _pendingImage;
    if ((typed.isEmpty && image == null) ||
        _busy ||
        _sessionId == null) {
      return;
    }

    var textForAgent = typed;
    var textForBubble = typed;
    if (image != null) {
      await AgentSettings.instance.load();
      final vision = VisionClient(AgentSettings.instance);
      if (!vision.available) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('附图识图需要配置视觉模型 Key')),
        );
        return;
      }
      try {
        final result = await runBusy(
          context,
          message: '正在识图…',
          task: () => vision.understand(
                image: image,
                userText: typed.isEmpty ? '请理解图中文字或内容，用于改笔记' : typed,
              ),
        );
        final ask = typed.isEmpty ? '请根据附图帮助改这篇笔记' : typed;
        textForAgent =
            '$ask\n\n【附图理解 · ${result.source}】\n${result.text}';
        textForBubble = '$ask\n\n📷 ${result.text}';
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('看图失败：$e')),
        );
        return;
      }
    }

    final sessionId = _sessionId!;
    setState(() {
      _messages.add(ChatMessage(role: ChatRole.user, text: textForBubble));
      _messageIds.add(null);
      _input.clear();
      _pendingImage = null;
      _busy = true;
    });

    await _db.insertChatMessage(
      StoredChatMessage(
        sessionId: sessionId,
        role: ChatRole.user,
        text: textForBubble,
        createdAt: DateTime.now(),
      ),
    );
    await _db.touchChatSession(sessionId);

    try {
      await AgentSettings.instance.load();
      final endpoints = AgentSettings.instance.resolveEndpoints();
      if (endpoints.isEmpty) {
        throw StateError('未配置对话模型');
      }

      final draftCtx = StringBuffer()
        ..writeln('当前标题：${widget.getters.title()}')
        ..writeln('当前选项：${widget.getters.optionsJson()}')
        ..writeln('当前正文：')
        ..writeln(widget.getters.plain());

      Map<String, dynamic>? message;
      Object? lastErr;
      for (final ep in endpoints) {
        try {
          message = await _chatOnce(
            ep: ep,
            draftCtx: draftCtx.toString(),
            user: textForAgent,
          );
          break;
        } catch (e) {
          lastErr = e;
        }
      }
      if (message == null) throw lastErr ?? StateError('模型不可用');

      final content = (message['content'] as String?)?.trim() ?? '';
      final rawTools = message['tool_calls'] as List<dynamic>? ?? const [];
      final applied = <String>[];
      for (final t in rawTools) {
        final fn = (t as Map)['function'] as Map<String, dynamic>?;
        if (fn == null) continue;
        final name = fn['name'] as String? ?? '';
        Map<String, dynamic> args = {};
        final argsRaw = fn['arguments'];
        if (argsRaw is String && argsRaw.isNotEmpty) {
          args = Map<String, dynamic>.from(jsonDecode(argsRaw) as Map);
        } else if (argsRaw is Map) {
          args = Map<String, dynamic>.from(argsRaw);
        }
        final tip = _runTool(name, args);
        if (tip != null) applied.add(tip);
      }

      final reply = StringBuffer();
      if (content.isNotEmpty) reply.writeln(content);
      if (applied.isNotEmpty) {
        if (reply.isNotEmpty) reply.writeln();
        reply.writeln(applied.join('\n'));
      }
      if (reply.isEmpty) reply.write('已处理。');

      final text = reply.toString().trim();
      final aid = await _db.insertChatMessage(
        StoredChatMessage(
          sessionId: sessionId,
          role: ChatRole.assistant,
          text: text,
          createdAt: DateTime.now(),
        ),
      );
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(role: ChatRole.assistant, text: text));
        _messageIds.add(aid);
      });
    } catch (e) {
      final text = '没改成功：$e';
      final aid = await _db.insertChatMessage(
        StoredChatMessage(
          sessionId: sessionId,
          role: ChatRole.assistant,
          text: text,
          createdAt: DateTime.now(),
        ),
      );
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(role: ChatRole.assistant, text: text));
        _messageIds.add(aid);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _runTool(String name, Map<String, dynamic> args) {
    switch (name) {
      case 'set_title':
        widget.setters.setTitle('${args['title'] ?? ''}'.trim());
        return '已改标题。';
      case 'replace_draft':
        widget.setters.replacePlain('${args['plain'] ?? ''}');
        return '已替换正文。';
      case 'replace_delta':
        final d = args['delta'];
        if (d is List) {
          widget.setters.replaceDelta(d);
          return '已按富文本替换正文。';
        }
        return 'replace_delta 无效。';
      case 'apply_format':
        widget.setters.applyFormat(args);
        return '已套用格式。';
      case 'set_note_options':
        widget.setters.setOptions(args);
        return '已更新笔记选项。';
      default:
        return '未知工具：$name';
    }
  }

  Future<Map<String, dynamic>> _chatOnce({
    required LlmEndpoint ep,
    required String draftCtx,
    required String user,
  }) async {
    final base = ep.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/chat/completions');
    final model = ep.model == 'default' ? '' : ep.model;
    final history = <Map<String, String>>[];
    for (final m in _messages) {
      if (m.role == ChatRole.system) continue;
      history.add({
        'role': m.role == ChatRole.user ? 'user' : 'assistant',
        'content': m.text,
      });
    }
    // 去掉刚加入的本轮 user（下面单独加带附图理解的 text）
    if (history.isNotEmpty && history.last['role'] == 'user') {
      history.removeLast();
    }
    final body = <String, dynamic>{
      if (model.isNotEmpty) 'model': model,
      'temperature': 0.2,
      'messages': [
        {'role': 'system', 'content': _system},
        {'role': 'system', 'content': draftCtx},
        ...history,
        {'role': 'user', 'content': user},
      ],
      'tools': _tools,
      'tool_choice': 'auto',
    };
    final res = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${ep.apiKey}',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode >= 400) {
      throw StateError('HTTP ${res.statusCode}：${res.body}');
    }
    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final choices = json['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      throw StateError('模型没有返回内容');
    }
    return (choices.first as Map)['message'] as Map<String, dynamic>;
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoiceTick);
    _voice.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const panelBg = Color(0xFFE8E8E8);
    return Material(
      color: panelBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => widget.onExpandedChanged(!widget.expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'AI 助手',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111111),
                      ),
                    ),
                  ),
                  if (widget.expanded) ...[
                    IconButton(
                      tooltip: '历史',
                      onPressed: _busy ? null : _pickSession,
                      icon: const Icon(Icons.history, size: 20),
                    ),
                    IconButton(
                      tooltip: '新对话',
                      onPressed: _busy ? null : _newChat,
                      icon: const Icon(Icons.add_comment_outlined, size: 20),
                    ),
                  ],
                  Icon(
                    widget.expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    color: const Color(0xFF666666),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          if (widget.expanded) ...[
            const Divider(height: 1, color: Color(0xFFD0D0D0)),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      itemCount: _messages.length + (_busy ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (_busy && i == 0) {
                          return const Padding(
                            padding: EdgeInsets.all(8),
                            child: Text(
                              '思考中…',
                              style: TextStyle(
                                fontSize: 14,
                                color: Color(0xFF666666),
                              ),
                            ),
                          );
                        }
                        final idx =
                            _messages.length - 1 - (i - (_busy ? 1 : 0));
                        final m = _messages[idx];
                        final mine = m.role == ChatRole.user;
                        return Align(
                          alignment: mine
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width * 0.78,
                            ),
                            decoration: BoxDecoration(
                              color: mine
                                  ? const Color(0xFF111111)
                                  : const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              m.text,
                              style: TextStyle(
                                fontSize: 14,
                                height: 1.4,
                                decoration: TextDecoration.none,
                                color: mine
                                    ? Colors.white
                                    : const Color(0xFF111111),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            ListenableBuilder(
              listenable: _voice,
              builder: (_, __) => VoiceInputBar(
                voice: _voice,
                voiceMode: _voiceMode,
                onToggleVoiceMode: () async {
                  setState(() => _voiceMode = !_voiceMode);
                  if (_voiceMode) await _voice.ensureMic(showError: true);
                },
                input: _input,
                onSend: _send,
                onAttachImage: _attachImage,
                busy: _busy,
                pendingImage: _pendingImage,
                onClearImage: () => setState(() => _pendingImage = null),
                hintText: '让 AI 改上方笔记…',
                darkChrome: true,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
