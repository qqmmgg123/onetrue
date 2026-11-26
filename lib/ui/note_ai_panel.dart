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
import '../domain/ai_text.dart';
import '../domain/draft_span_edit.dart';
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
  void Function(String plain) appendPlain,
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
    this.onBusyChanged,
  });

  final NoteDraftGetters getters;
  final NoteDraftSetters setters;

  /// 笔记 uuid 或 `draft:…`，用于会话隔离。
  final String refKey;
  final bool expanded;
  final ValueChanged<bool> onExpandedChanged;
  final ValueChanged<bool>? onBusyChanged;

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
- set_title：改标题（写文章/生成内容时若需要标题，必须同一轮再调用 replace_draft 写入完整正文，禁止只改标题）
- replace_draft：用「纯文本」整篇替换正文。参数名必须是 plain。写全新文章/大段重写时用。
- append_draft：在现有正文末尾追加纯文本（plain 仅为要追加的内容）。
- edit_span：按原文片段局部增删改。参数：action(replace|delete|insert_after|insert_before)、find(原文句子/段落，尽量照抄)、text(新内容；delete 可不传)、all(可选)。用户说「在某句后面加/删掉某句/把某段改成…」时必须用本工具。
- replace_delta：仅在用户明确要求保留/设置富文本结构且要整篇重写时使用
- apply_format：套格式
- set_note_options：改形态与选项。字段：kind(note|memo|schedule|article|admonition)、schedule_at、remind_at、recur_freq、recur_byday、recur_until、recur_count、remind_offset_min、listed、city
硬性规则：
1) 写全新全文 → replace_draft；文末追加 → append_draft；局部增删改 → edit_span。
2) 局部修改禁止用 replace_draft 只写那一句（会覆盖全文）。
3) edit_span 的 find 必须能在当前正文里匹配到。
4) 用户一句话里有多处「前面写/后面写/删掉/改成」时：同一轮必须按顺序多次调用 edit_span（或合并为更少次仍覆盖全部改动），禁止只做第一处就结束。
5) 同一锚点连续「后面写」多次：优先一次 insert_after，text 按用户顺序拼在一起；若分多次，后一次的 find 用上一处刚插入的文字。
6) 没有成功调用写入类工具之前，禁止说「已写入/已追加/已删除/已完成」。
7) 用户说「把正文贴到对话里」时：写在回复里，禁止改草稿工具。
8) 工具成功后不要复述大段正文；一句话即可。
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
        'description':
            '用纯文本整篇替换正文。必须传 plain（完整正文）。写全新文章时用；追加内容请用 append_draft。',
        'parameters': {
          'type': 'object',
          'properties': {
            'plain': {
              'type': 'string',
              'description': '完整正文纯文本，段落之间用换行分隔',
            },
          },
          'required': ['plain'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'append_draft',
        'description':
            '在现有正文末尾追加纯文本。plain 只含要追加的内容。用户要求「最后加一句/追加」时必须用本工具。',
        'parameters': {
          'type': 'object',
          'properties': {
            'plain': {
              'type': 'string',
              'description': '仅追加的纯文本',
            },
          },
          'required': ['plain'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'edit_span',
        'description':
            '按原文片段局部编辑：replace 改写、delete 删除、insert_after 在某句后插入、insert_before 在某句前插入。find 须能匹配当前正文。用户要求多处局部修改时，同一轮可多次调用本工具（按顺序）。',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': [
                'replace',
                'delete',
                'insert_after',
                'insert_before',
              ],
            },
            'find': {
              'type': 'string',
              'description': '原文中的定位片段（句子或段落，尽量照抄）',
            },
            'text': {
              'type': 'string',
              'description': 'replace/insert 的新内容；delete 时可省略',
            },
            'all': {
              'type': 'boolean',
              'description': 'true 时修改全部匹配处，默认只改第一处',
            },
          },
          'required': ['action', 'find'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'replace_delta',
        'description': '用 Quill Delta JSON 整篇替换正文（不要用于追加一句）',
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
    widget.onBusyChanged?.call(true);

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

      // 改类型 / 写备忘·文章·日常：先切形态
      final inferredKind = inferKindFromUserText(textForAgent);
      final applied = <String>[];
      if (inferredKind != null) {
        try {
          final opts = jsonDecode(widget.getters.optionsJson());
          final kind = opts is Map ? '${opts['kind'] ?? ''}' : '';
          if (kind != inferredKind) {
            widget.setters.setOptions({'kind': inferredKind});
            applied.add('已更新笔记选项');
          }
        } catch (_) {
          widget.setters.setOptions({'kind': inferredKind});
          applied.add('已更新笔记选项');
        }
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

      var content = (message['content'] as String?)?.trim() ?? '';
      final wantAppend = looksLikeAppendRequest(textForAgent);
      String? applyOneTool(
        String name,
        Map<String, dynamic> args, {
        String rawArgs = '',
      }) {
        var n = name;
        var a = args;
        if (wantAppend &&
            (n == 'replace_draft' || n == 'replace_delta')) {
          var plain = pickDraftPlain(a, rawArgs: rawArgs);
          if (plain.isEmpty && a['delta'] is List) {
            final buf = StringBuffer();
            for (final op in a['delta'] as List) {
              if (op is Map && op['insert'] is String) {
                buf.write(op['insert']);
              }
            }
            plain = sanitizeAiPlainText(buf.toString());
          }
          n = 'append_draft';
          a = {'plain': plain};
        }
        return _runTool(n, a, rawArgs: rawArgs);
      }

      void applyParsedCalls(
        List<({String name, Map<String, dynamic> args, String rawArgs})> parsed,
      ) {
        final coalesced = coalesceEditSpanCalls([
          for (final c in parsed) (name: c.name, args: c.args),
        ]);
        // coalesce 后 rawArgs 仅对非合并项有意义；edit_span 不依赖 rawArgs
        var i = 0;
        for (final c in coalesced) {
          String raw = '';
          if (i < parsed.length &&
              parsed[i].name == c.name &&
              c.name != 'edit_span') {
            raw = parsed[i].rawArgs;
          }
          i++;
          final tip = applyOneTool(c.name, c.args, rawArgs: raw);
          if (tip != null) applied.add(tip);
        }
      }

      void applyMessageToolsRemapped(Map<String, dynamic> msg) {
        final rawTools = msg['tool_calls'] as List<dynamic>? ?? const [];
        final parsed =
            <({String name, Map<String, dynamic> args, String rawArgs})>[];
        for (final t in rawTools) {
          final fn = (t as Map)['function'] as Map<String, dynamic>?;
          if (fn == null) continue;
          final name = fn['name'] as String? ?? '';
          final argsRaw = fn['arguments'];
          final args = parseToolArgsMap(argsRaw);
          final rawStr = argsRaw is String ? argsRaw : '';
          parsed.add((name: name, args: args, rawArgs: rawStr));
        }
        if (parsed.isNotEmpty) {
          applyParsedCalls(parsed);
          return;
        }
        final pseudo = extractPseudoToolCalls('${msg['content'] ?? ''}');
        if (pseudo.calls.isNotEmpty) {
          applyParsedCalls([
            for (final c in pseudo.calls)
              (name: c.name, args: c.args, rawArgs: ''),
          ]);
          content = pseudo.cleaned;
        }
      }

      final plainBeforeTools = widget.getters.plain();
      applyMessageToolsRemapped(message);

      // 模型漏插 / 误用 insert_before：按用户话术从改前正文确定性重放
      void repairSpanFromUserText(String plainBefore) {
        final intents = extractSpanEditIntents(textForAgent);
        if (intents.isEmpty) return;
        final missing =
            missingSpanInsertTexts(widget.getters.plain(), intents);
        if (missing.isEmpty) return;
        final repaired = applySpanEditsSequential(plainBefore, intents);
        if (repaired.tips.isEmpty) return;
        widget.setters.replacePlain(repaired.plain);
        applied.removeWhere(tipIsSpanEdit);
        applied.addAll(repaired.tips);
      }

      repairSpanFromUserText(plainBeforeTools);

      bool tipIsWrite(String t) =>
          t.contains('已写入正文') ||
          t.contains('富文本写入') ||
          t.contains('已追加正文') ||
          t.contains('已删除指定片段') ||
          t.contains('已改写指定片段') ||
          t.contains('已在指定句');
      var wroteBody = applied.any(tipIsWrite);
      final draftEmpty = widget.getters.plain().trim().isEmpty;
      final wantWrite = !wantAppend &&
          (looksLikeWriteRequest(textForAgent) ||
              (draftEmpty && applied.any((t) => t.contains('已改标题'))));
      if (wantWrite && !wroteBody) {
        Map<String, dynamic>? retryMsg;
        Object? retryErr;
        const retryUser =
            '上一次没有真正调用 replace_draft 把完整正文写入编辑器。请立刻调用 replace_draft，在 plain 参数写入完整文章正文（纯文本、多段落）。禁止只改标题，禁止只回复「已写入正文」。';
        final retryCtx = StringBuffer()
          ..writeln('当前标题：${widget.getters.title()}')
          ..writeln('当前选项：${widget.getters.optionsJson()}')
          ..writeln('当前正文：')
          ..writeln(widget.getters.plain());
        for (final ep in endpoints) {
          try {
            retryMsg = await _chatOnce(
              ep: ep,
              draftCtx: retryCtx.toString(),
              user: retryUser,
              priorTurns: [
                {'role': 'user', 'content': textForAgent},
                {
                  'role': 'assistant',
                  'content': applied.isNotEmpty
                      ? applied.join('；')
                      : (content.isNotEmpty ? content : '（未写入正文）'),
                },
              ],
              forceReplaceDraft: true,
            );
            break;
          } catch (e) {
            retryErr = e;
          }
        }
        if (retryMsg != null) {
          content = (retryMsg['content'] as String?)?.trim() ?? content;
          applyMessageToolsRemapped(retryMsg);
          wroteBody = applied.any(tipIsWrite);
        } else if (retryErr != null && !wroteBody) {
          content = '没能写入正文，请再试一次。';
        }
      }

      if (wantAppend && !wroteBody) {
        Map<String, dynamic>? retryMsg;
        const retryUser =
            '用户要求在文末追加文字。请调用 append_draft，plain 仅为要追加的那一句/那段；禁止用 replace_draft 覆盖全文。';
        final retryCtx = StringBuffer()
          ..writeln('当前标题：${widget.getters.title()}')
          ..writeln('当前选项：${widget.getters.optionsJson()}')
          ..writeln('当前正文：')
          ..writeln(widget.getters.plain());
        for (final ep in endpoints) {
          try {
            retryMsg = await _chatOnce(
              ep: ep,
              draftCtx: retryCtx.toString(),
              user: retryUser,
              priorTurns: [
                {'role': 'user', 'content': textForAgent},
                {
                  'role': 'assistant',
                  'content': applied.isNotEmpty
                      ? applied.join('；')
                      : (content.isNotEmpty ? content : '（未追加）'),
                },
              ],
              forceReplaceDraft: true,
            );
            break;
          } catch (_) {}
        }
        if (retryMsg != null) {
          content = (retryMsg['content'] as String?)?.trim() ?? content;
          applyMessageToolsRemapped(retryMsg);
          wroteBody = applied.any(tipIsWrite);
        }
      }

      // 多处局部编辑：模型常只做第一处 —— 按估算次数补全
      final spanIntents = extractSpanEditIntents(textForAgent);
      final expectedSpan = spanIntents.isNotEmpty
          ? spanIntents.length
          : countLikelySpanEditOps(textForAgent);
      var spanDone = applied.where(tipIsSpanEdit).length;
      final spanComplete = spanIntents.isNotEmpty &&
          missingSpanInsertTexts(widget.getters.plain(), spanIntents).isEmpty;
      if (!spanComplete && expectedSpan >= 2 && spanDone < expectedSpan) {
        Future<Map<String, dynamic>?> spanRetry(String retryUser) async {
          Map<String, dynamic>? retryMsg;
          final retryCtx = StringBuffer()
            ..writeln('当前标题：${widget.getters.title()}')
            ..writeln('当前选项：${widget.getters.optionsJson()}')
            ..writeln('当前正文：')
            ..writeln(widget.getters.plain());
          for (final ep in endpoints) {
            try {
              retryMsg = await _chatOnce(
                ep: ep,
                draftCtx: retryCtx.toString(),
                user: retryUser,
                priorTurns: [
                  {'role': 'user', 'content': textForAgent},
                  {
                    'role': 'assistant',
                    'content': applied.isNotEmpty
                        ? applied.join('；')
                        : (content.isNotEmpty ? content : '（未完成全部局部修改）'),
                  },
                ],
              );
              break;
            } catch (_) {}
          }
          return retryMsg;
        }

        final first = await spanRetry(
          '用户原话要求约 $expectedSpan 处局部修改，目前只完成了 $spanDone 处。'
          '请立刻对其余步骤继续调用 edit_span（同一轮可多次，按用户顺序）。'
          '同一锚点连续「后面写」请合并为一次 insert_after（text 按顺序拼接），'
          '或后一次 find 用上一处刚插入的文字。禁止只回复文字不调工具。',
        );
        if (first != null) {
          content = (first['content'] as String?)?.trim() ?? content;
          final before = widget.getters.plain();
          applyMessageToolsRemapped(first);
          repairSpanFromUserText(before);
          wroteBody = applied.any(tipIsWrite);
          spanDone = applied.where(tipIsSpanEdit).length;
        }
        if (spanDone < expectedSpan) {
          final second = await spanRetry(
            '仍未做完。用户原话：$textForAgent\n请把剩余局部修改全部用 edit_span 做完（可多次调用）。',
          );
          if (second != null) {
            content = (second['content'] as String?)?.trim() ?? content;
            final before = widget.getters.plain();
            applyMessageToolsRemapped(second);
            repairSpanFromUserText(before);
            wroteBody = applied.any(tipIsWrite);
          }
        }
      }

      // 多轮后仍缺插入文：再以最初正文做一次确定性补全
      if (spanIntents.isNotEmpty &&
          missingSpanInsertTexts(widget.getters.plain(), spanIntents)
              .isNotEmpty) {
        repairSpanFromUserText(plainBeforeTools);
      }

      if (!wroteBody &&
          RegExp(r'已写入正文|已写入|正文已更新|已追加|已删除|已改写').hasMatch(content)) {
        content = '';
      }

      final reply = StringBuffer();
      if (content.isNotEmpty) reply.writeln(content);
      if (applied.isNotEmpty) {
        if (reply.isNotEmpty) reply.writeln();
        reply.writeln(applied.join('\n'));
      }
      if (reply.isEmpty) {
        reply.write(wroteBody ? '已写入正文' : '已处理。');
      } else if (wantWrite && !wroteBody) {
        reply.writeln();
        reply.write('未能写入正文，请再试一次或换个说法。');
      }

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
      if (mounted) {
        setState(() => _busy = false);
        widget.onBusyChanged?.call(false);
      } else {
        widget.onBusyChanged?.call(false);
      }
    }
  }

  String? _runTool(
    String name,
    Map<String, dynamic> args, {
    String rawArgs = '',
  }) {
    switch (name) {
      case 'set_title':
        widget.setters.setTitle('${args['title'] ?? ''}'.trim());
        return '已改标题';
      case 'append_draft':
        final append = pickDraftPlain(args, rawArgs: rawArgs);
        if (append.isEmpty) return '追加内容为空，未改动';
        widget.setters.appendPlain(append);
        return '已追加正文';
      case 'edit_span':
        final result = applySpanEdit(widget.getters.plain(), args);
        if (!result.ok) return result.error ?? '局部编辑失败';
        widget.setters.replacePlain(result.next ?? '');
        return result.tip ?? '已局部编辑';
      case 'replace_draft':
        final plain = pickDraftPlain(args, rawArgs: rawArgs);
        if (plain.isEmpty) return '正文为空，未改动';
        widget.setters.replacePlain(plain);
        return '已写入正文';
      case 'replace_delta':
        final d = args['delta'];
        if (d is List) {
          widget.setters.replaceDelta(d);
          return '已按富文本写入正文';
        }
        return 'replace_delta 无效';
      case 'apply_format':
        widget.setters.applyFormat(args);
        return '已套用格式';
      case 'set_note_options':
        // kind 中文别名在编辑页 _applyNoteOptions → normalizeNoteKind 处理
        if (args.containsKey('kind')) {
          final n = normalizeNoteKind('${args['kind']}', allowAdmonition: true);
          if (n == null) {
            return '未识别的类型「${args['kind']}」';
          }
          final next = Map<String, dynamic>.from(args);
          next['kind'] = n;
          widget.setters.setOptions(next);
          return '已更新笔记选项';
        }
        widget.setters.setOptions(args);
        return '已更新笔记选项';
      default:
        return '未知工具：$name';
    }
  }

  Future<Map<String, dynamic>> _chatOnce({
    required LlmEndpoint ep,
    required String draftCtx,
    required String user,
    List<Map<String, String>> priorTurns = const [],
    bool forceReplaceDraft = false,
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
        ...priorTurns,
        {'role': 'user', 'content': user},
      ],
      'tools': _tools,
      'tool_choice': forceReplaceDraft
          ? {
              'type': 'function',
              'function': {'name': 'replace_draft'},
            }
          : 'auto',
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
    const panelBg = Color(0xFFF7F7F8);
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
                                  ? const Color(0xFFECECF0)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFFEBEBEB),
                              ),
                            ),
                            child: Text(
                              m.text,
                              style: const TextStyle(
                                fontSize: 14,
                                height: 1.4,
                                decoration: TextDecoration.none,
                                color: Color(0xFF1A1A1A),
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
                  final toVoice = !_voiceMode;
                  setState(() => _voiceMode = toVoice);
                  if (!toVoice) {
                    // 切到键盘：停掉按住识别，避免与输入冲突
                    if (_voice.listening) {
                      await _voice.onHoldEnd(send: false);
                    }
                  } else {
                    await _voice.ensureMic(showError: true);
                  }
                },
                input: _input,
                onSend: _send,
                onAttachImage: _attachImage,
                busy: _busy,
                pendingImage: _pendingImage,
                onClearImage: () => setState(() => _pendingImage = null),
                hintText: '让 AI 改上方笔记…',
                darkChrome: false,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
