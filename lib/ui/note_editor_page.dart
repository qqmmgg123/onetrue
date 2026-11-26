import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' hide Text;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../auth/auth_service.dart';
import '../domain/ai_text.dart';
import '../domain/models.dart';
import '../domain/note_recur.dart';
import '../domain/note_title.dart';
import '../media/note_image_upload.dart';
import '../social/social_api.dart';
import '../state/app_store.dart';
import 'busy.dart';
import 'format.dart';
import 'note_ai_panel.dart';
import 'note_quill.dart';
import 'quill_image_embed.dart';
import 'voice_input_bar.dart';
import 'widgets/cover_image.dart';

class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({
    super.key,
    this.noteId,
    this.initialKind,
    this.initialScheduleAt,
  });

  final int? noteId;
  final String? initialKind;
  final DateTime? initialScheduleAt;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  final _titleCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _recurCountCtrl = TextEditingController();
  final _editorFocus = FocusNode();
  final _editorScroll = ScrollController();
  late QuillController _quill;

  String _kind = kNoteKindNote;
  DateTime? _scheduleAt;
  DateTime? _remindAt;
  String _recurFreq = kRecurOnce;
  String? _recurByday;
  DateTime? _recurUntil;
  int? _recurCount;
  /// never | until | count
  String _recurEndMode = 'never';
  int _remindOffsetMin = 0;
  bool _listed = false;
  String _coverUrl = '';
  bool _loading = true;
  bool _saving = false;
  /// 进入页 / 成功保存后的指纹；未改动则跳过落库。
  String? _baselineFingerprint;
  bool _voiceInserting = false;
  final _micKey = GlobalKey<NoteMicButtonState>();
  Note? _existing;
  late String _aiRefKey;
  late bool _aiExpanded;

  bool get _titleRequired =>
      _kind == kNoteKindSchedule || _kind == kNoteKindArticle;

  bool get _aiDefaultExpanded =>
      _kind == kNoteKindNote || _kind == kNoteKindArticle;

  bool _isAdmin = false;
  bool _aiBusy = false;

  /// 笔记 / 备忘 / 日常 / 文章 / 谏言
  String get _kindNoun {
    switch (_kind) {
      case kNoteKindMemo:
        return '备忘';
      case kNoteKindSchedule:
        return '日常';
      case kNoteKindArticle:
        return '文章';
      case kNoteKindAdmonition:
        return '谏言';
      default:
        return '笔记';
    }
  }

  /// 保存 / 添加 / 安排 / 发布 / 推荐
  String get _primaryActionLabel {
    switch (_kind) {
      case kNoteKindMemo:
        return '添加';
      case kNoteKindSchedule:
        return '安排';
      case kNoteKindArticle:
        return '发布';
      case kNoteKindAdmonition:
        return '推荐';
      default:
        return '保存';
    }
  }

  String get _busyMessage {
    switch (_kind) {
      case kNoteKindMemo:
        return '正在添加…';
      case kNoteKindSchedule:
        return '正在安排…';
      case kNoteKindArticle:
        return '正在发布…';
      case kNoteKindAdmonition:
        return '正在推荐…';
      default:
        return '正在保存…';
    }
  }

  String get _kindHint {
    switch (_kind) {
      case kNoteKindMemo:
        return '将笔记添加到备忘';
      case kNoteKindSchedule:
        return '将笔记安排到日常';
      case kNoteKindArticle:
        return '将笔记发布到阅读';
      case kNoteKindAdmonition:
        return '推荐到谏言';
      default:
        return '记录你的念头和思绪';
    }
  }

  @override
  void initState() {
    super.initState();
    _quill = QuillController.basic();
    _quill.addListener(_onQuillDocChanged);
    _titleCtrl.addListener(_onKeyboardSideEdit);
    _aiRefKey = 'draft:${const Uuid().v4()}';
    final ik = widget.initialKind?.trim();
    if (ik != null && ik.isNotEmpty) {
      _kind = ik;
    }
    if (widget.initialScheduleAt != null) {
      _scheduleAt = widget.initialScheduleAt;
      if (_kind == kNoteKindSchedule) {
        _remindOffsetMin = 0;
        _remindAt = remindAtFromOffset(_scheduleAt, _remindOffsetMin);
      }
    }
    _aiExpanded = _aiDefaultExpanded;
    _loadAdmin();
    _load();
  }

  Future<void> _loadAdmin() async {
    try {
      final uid = context.read<AppStore>().user?.id;
      if (uid == null || uid.isEmpty) return;
      final p = await SocialApi.instance.fetchProfile(uid);
      if (!mounted) return;
      setState(() => _isAdmin = p?.isAdmin == true);
    } catch (_) {}
  }

  Future<void> _load() async {
    if (widget.noteId == null) {
      setState(() => _loading = false);
      _captureBaseline();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editorFocus.requestFocus();
      });
      return;
    }
    final n = await context.read<AppStore>().db.noteById(widget.noteId!);
    if (!mounted) return;
    if (n != null) {
      _existing = n;
      _kind = n.kind;
      _aiExpanded = _aiDefaultExpanded;
      _titleCtrl.text = n.title;
      if (n.uuid.isNotEmpty) {
        _aiRefKey = n.uuid;
      }
      _quill.removeListener(_onQuillDocChanged);
      _quill.dispose();
      _quill = QuillController(
        document: documentFromBody(n.body, format: n.format),
        selection: const TextSelection.collapsed(offset: 0),
      );
      _quill.addListener(_onQuillDocChanged);
      _scheduleAt = n.scheduleAt?.toLocal();
      _remindAt = n.remindAt?.toLocal();
      _recurFreq = normalizeRecurFreq(n.recurFreq);
      _recurByday = n.recurByday;
      _recurUntil = n.recurUntil?.toLocal();
      _recurCount = n.recurCount;
      if (_recurCount != null && _recurCount! > 0) {
        _recurEndMode = 'count';
        _recurCountCtrl.text = '${_recurCount!}';
      } else if (_recurUntil != null) {
        _recurEndMode = 'until';
      } else {
        _recurEndMode = 'never';
      }
      if (n.kind == kNoteKindSchedule) {
        if (n.remindOffsetMin < 0) {
          _remindOffsetMin = -1;
          _remindAt = null;
        } else {
          _remindOffsetMin = n.remindOffsetMin > 0
              ? n.remindOffsetMin
              : (n.remindAt == null
                  ? 0
                  : offsetMinFromRemind(_scheduleAt, _remindAt));
          if (_remindOffsetMin < 0) {
            _remindAt = null;
          } else {
            _remindAt = remindAtFromOffset(_scheduleAt, _remindOffsetMin);
          }
        }
      }
      _listed = n.isListed;
      _cityCtrl.text = n.city;
      _coverUrl = n.coverUrl;
    }
    setState(() => _loading = false);
    _captureBaseline();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editorFocus.requestFocus();
    });
  }

  void _captureBaseline() {
    _baselineFingerprint = _contentFingerprint();
  }

  String _contentFingerprint() {
    return jsonEncode({
      'kind': _kind,
      'title': _titleCtrl.text,
      'body': bodyToStorage(_quill),
      'schedule_at': _scheduleAt?.toIso8601String(),
      'remind_at': _remindAt?.toIso8601String(),
      'recur_freq': _recurFreq,
      'recur_byday': _recurByday,
      'recur_until': _recurUntil?.toIso8601String(),
      'recur_count': _recurCount,
      'recur_end': _recurEndMode,
      'remind_offset_min': _remindOffsetMin,
      'listed': _listed,
      'city': _cityCtrl.text.trim(),
      'cover_url': _coverUrl.trim(),
    });
  }

  Future<void> _pickCover() async {
    final uid = AuthService.instance.currentUser?.id ?? '';
    if (uid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录再上传封面')),
      );
      return;
    }
    try {
      final url = await runBusy(
        context,
        message: '上传封面…',
        task: () => pickAndUploadNoteImage(userId: uid, folder: 'covers'),
      );
      if (!mounted || url == null || url.isEmpty) return;
      setState(() => _coverUrl = url);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('封面上传失败：$e')),
      );
    }
  }

  Future<void> _insertBodyImage() async {
    final uid = AuthService.instance.currentUser?.id ?? '';
    if (uid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录再插入图片')),
      );
      return;
    }
    try {
      final url = await runBusy(
        context,
        message: '上传图片…',
        task: () => pickAndUploadNoteImage(userId: uid, folder: 'note-images'),
      );
      if (!mounted || url == null || url.isEmpty) return;
      final index = _quill.selection.baseOffset;
      final i = index < 0 ? _quill.document.length - 1 : index;
      _quill.document.insert(i, BlockEmbed.image(url));
      _quill.document.insert(i + 1, '\n');
      _quill.updateSelection(
        TextSelection.collapsed(offset: i + 2),
        ChangeSource.LOCAL,
      );
      _onKeyboardSideEdit();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('图片上传失败：$e')),
      );
    }
  }

  bool get _isDirty {
    final base = _baselineFingerprint;
    if (base == null) return true;
    return _contentFingerprint() != base;
  }

  void _onQuillDocChanged() => _onKeyboardSideEdit();

  void _onKeyboardSideEdit() {
    // 键盘编辑时自动关掉听写，避免语音与键盘抢输入
    if (_voiceInserting) return;
    _micKey.currentState?.stopIfActive();
  }

  @override
  void dispose() {
    _quill.removeListener(_onQuillDocChanged);
    _titleCtrl.removeListener(_onKeyboardSideEdit);
    _titleCtrl.dispose();
    _cityCtrl.dispose();
    _recurCountCtrl.dispose();
    _editorFocus.dispose();
    _editorScroll.dispose();
    _quill.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime({required bool schedule}) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var initial = (schedule ? _scheduleAt : _remindAt) ?? now.add(const Duration(minutes: 5));
    if (initial.isBefore(now)) {
      initial = now.add(const Duration(minutes: 5));
    }
    final day = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: today,
      lastDate: DateTime(2100),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    final dt = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    if (!dt.isAfter(DateTime.now())) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            schedule ? '日常开始时间须晚于现在' : '提醒时间须晚于现在',
          ),
        ),
      );
      return;
    }
    setState(() {
      if (schedule) {
        _scheduleAt = dt;
        if (_kind == kNoteKindSchedule) {
          if (_recurFreq == kRecurWeekly) {
            _recurByday = weekdayToByDay(dt);
          }
          _remindAt = remindAtFromOffset(dt, _remindOffsetMin);
        }
      } else {
        _remindAt = dt;
      }
    });
  }

  Future<void> _pickRecurUntil() async {
    final initial = _recurUntil ?? _scheduleAt ?? DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: _scheduleAt == null
          ? DateTime(2020)
          : DateTime(_scheduleAt!.year, _scheduleAt!.month, _scheduleAt!.day),
      lastDate: DateTime(2100),
    );
    if (day == null || !mounted) return;
    setState(() {
      _recurUntil = DateTime(day.year, day.month, day.day, 23, 59);
      _recurCount = null;
      _recurEndMode = 'until';
    });
  }

  Future<void> _pickRemindOffset() async {
    const presets = <(String, int)>[
      ('不提醒', -1),
      ('日常开始时', 0),
      ('提前 5 分钟', 5),
      ('提前 10 分钟', 10),
      ('提前 15 分钟', 15),
      ('提前 30 分钟', 30),
      ('提前 1 小时', 60),
      ('提前 1 天', 24 * 60),
    ];
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('提醒')),
              ...presets.map(
                (p) => ListTile(
                  title: Text(p.$1),
                  trailing: _remindOffsetMin == p.$2
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => Navigator.pop(ctx, p.$2),
                ),
              ),
              ListTile(
                title: const Text('自定义…'),
                onTap: () => Navigator.pop(ctx, -2),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || picked == null) return;
    if (picked == -1) {
      setState(() {
        _remindOffsetMin = -1;
        _remindAt = null;
      });
      return;
    }
    if (picked >= 0) {
      setState(() {
        _remindOffsetMin = picked;
        _remindAt = remindAtFromOffset(_scheduleAt, _remindOffsetMin);
      });
      return;
    }
    final custom = await _promptCustomOffset();
    if (custom == null || !mounted) return;
    setState(() {
      _remindOffsetMin = custom;
      _remindAt = remindAtFromOffset(_scheduleAt, _remindOffsetMin);
    });
  }

  Future<int?> _promptCustomOffset() async {
    var unit = 'minute';
    final ctrl = TextEditingController(text: '15');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('自定义提醒'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: ctrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '数值',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'minute', label: Text('分钟')),
                      ButtonSegment(value: 'hour', label: Text('小时')),
                      ButtonSegment(value: 'day', label: Text('天')),
                    ],
                    selected: {unit},
                    onSelectionChanged: (s) => setLocal(() => unit = s.first),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok != true) return null;
    final n = int.tryParse(ctrl.text.trim()) ?? 0;
    if (n < 1) return 0;
    switch (unit) {
      case 'hour':
        return (n.clamp(1, 60)) * 60;
      case 'day':
        return (n.clamp(1, 30)) * 24 * 60;
      default:
        return n.clamp(1, 60);
    }
  }

  void _insertVoiceText(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    final docLen = _quill.document.length;
    final sel = _quill.selection;
    var index = sel.isValid ? sel.baseOffset : docLen - 1;
    if (index < 0) index = 0;
    if (index > docLen - 1) index = docLen - 1;
    _voiceInserting = true;
    try {
      _quill.replaceText(
        index,
        0,
        t,
        TextSelection.collapsed(offset: index + t.length),
      );
    } finally {
      _voiceInserting = false;
    }
    if (mounted) setState(() {});
  }

  Map<String, dynamic> _optionsSnapshot() {
    return {
      'kind': _kind,
      'title': _titleCtrl.text,
      'schedule_at': _scheduleAt?.toIso8601String(),
      'remind_at': _remindAt?.toIso8601String(),
      'recur_freq': _recurFreq,
      'recur_byday': _recurByday,
      'recur_until': _recurUntil?.toIso8601String(),
      'recur_count': _recurCount,
      'recur_end': _recurEndMode,
      'remind_offset_min': _remindOffsetMin,
      'listed': _kind == kNoteKindArticle ||
          _kind == kNoteKindAdmonition ||
          _listed,
      'city': _cityCtrl.text.trim(),
    };
  }

  void _applyNoteOptions(Map<String, dynamic> args) {
    setState(() {
      if (args.containsKey('kind')) {
        final normalized = normalizeNoteKind(
          '${args['kind']}',
          allowAdmonition: _isAdmin,
        );
        if (normalized != null) {
          _kind = normalized;
          if (normalized == kNoteKindArticle ||
              normalized == kNoteKindAdmonition) {
            _listed = true;
          }
          _aiExpanded = _aiDefaultExpanded;
          if (normalized == kNoteKindSchedule && _scheduleAt == null) {
            _scheduleAt = DateTime.now();
          }
        }
      }
      if (args.containsKey('title')) {
        _titleCtrl.text = '${args['title']}';
      }
      if (args.containsKey('schedule_at')) {
        final raw = args['schedule_at'];
        if (raw == null || '$raw'.trim().isEmpty) {
          _scheduleAt = null;
        } else {
          _scheduleAt = DateTime.tryParse('$raw')?.toLocal();
        }
      }
      if (args.containsKey('remind_at')) {
        final raw = args['remind_at'];
        if (raw == null || '$raw'.trim().isEmpty) {
          _remindAt = null;
          if (_kind == kNoteKindMemo) {
            // 备忘清空提醒
          } else if (_kind == kNoteKindSchedule) {
            _remindOffsetMin = -1;
          }
        } else {
          final parsed = sanitizeFutureRemind(DateTime.tryParse('$raw')?.toLocal());
          _remindAt = parsed;
          if (parsed == null && _kind == kNoteKindSchedule) {
            _remindOffsetMin = -1;
          }
        }
      }
      if (args.containsKey('recur_freq')) {
        _recurFreq = normalizeRecurFreq('${args['recur_freq']}');
        if (_recurFreq == kRecurWeekly &&
            _scheduleAt != null &&
            (_recurByday == null || _recurByday!.isEmpty)) {
          _recurByday = weekdayToByDay(_scheduleAt!);
        }
        if (_recurFreq == kRecurOnce) {
          _recurByday = null;
          _recurUntil = null;
          _recurCount = null;
          _recurEndMode = 'never';
        }
      }
      if (args.containsKey('recur_byday')) {
        final b = '${args['recur_byday']}'.trim().toUpperCase();
        _recurByday = b.isEmpty ? null : b;
      }
      final hasUntil = args.containsKey('recur_until');
      final hasCount = args.containsKey('recur_count');
      if (hasUntil) {
        final raw = args['recur_until'];
        if (raw == null || '$raw'.trim().isEmpty) {
          _recurUntil = null;
          if (!hasCount) {
            _recurEndMode = 'never';
            _recurCount = null;
          }
        } else {
          _recurUntil = DateTime.tryParse('$raw')?.toLocal();
          _recurCount = null;
          _recurEndMode = 'until';
        }
      }
      if (hasCount) {
        final raw = args['recur_count'];
        if (raw == null || '$raw'.trim().isEmpty) {
          _recurCount = null;
          _recurCountCtrl.clear();
          if (!hasUntil) {
            _recurEndMode = 'never';
            _recurUntil = null;
          }
        } else {
          final c = raw is int ? raw : int.tryParse('$raw');
          _recurCount = c;
          _recurCountCtrl.text = c == null ? '' : '$c';
          _recurUntil = null;
          _recurEndMode = (c != null && c > 0) ? 'count' : 'never';
        }
      }
      if (args.containsKey('remind_offset_min')) {
        final o = args['remind_offset_min'];
        final m = o is int ? o : int.tryParse('$o') ?? 0;
        // <0：不提醒；否则为提前分钟数
        _remindOffsetMin = m < 0 ? -1 : m;
        if (_kind == kNoteKindSchedule) {
          _remindAt = remindAtFromOffset(_scheduleAt, _remindOffsetMin);
        }
      } else if (_kind == kNoteKindSchedule &&
          args.containsKey('schedule_at')) {
        _remindAt = remindAtFromOffset(_scheduleAt, _remindOffsetMin);
      }
      if (_kind == kNoteKindMemo && _remindAt != null) {
        _remindAt = sanitizeFutureRemind(_remindAt);
      }
      if (_kind == kNoteKindSchedule &&
          _remindAt != null &&
          _remindOffsetMin >= 0) {
        final fixed = sanitizeFutureRemind(_remindAt);
        if (fixed == null) {
          _remindOffsetMin = -1;
          _remindAt = null;
        } else {
          _remindAt = fixed;
        }
      }
      if (args.containsKey('listed')) {
        final v = args['listed'];
        final on = v == true || v == 1 || '$v' == 'true';
        _listed = on;
        if (on &&
            _kind != kNoteKindArticle &&
            _kind != kNoteKindAdmonition) {
          _kind = kNoteKindArticle;
        }
      }
      // 形态为文章/谏言时草稿上下文与保存一致：视为上架
      if (_kind == kNoteKindArticle || _kind == kNoteKindAdmonition) {
        _listed = true;
      }
      if (args.containsKey('city')) {
        _cityCtrl.text = '${args['city']}';
      }
    });
  }

  /// [strict] 为点「保存」：校验失败则提示且不落库。
  /// 返回时 [strict]=false：有内容则尽力保存，空草稿直接丢弃。
  Future<bool> _persist({required bool strict}) async {
    if (_saving) return false;
    final plain = bodyPlain(_quill);
    var title = _titleCtrl.text.trim();
    final body = bodyToStorage(_quill);

    if (plain.isEmpty && title.isEmpty && _existing == null) {
      // 全新空草稿：不落库
      return true;
    }
    if (plain.isEmpty && title.isEmpty && _existing != null) {
      // 已有笔记被清空：严格模式拦，返回仍保存空正文
      if (strict) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('写点内容再$_primaryActionLabel')),
        );
        return false;
      }
    }

    if (strict) {
      if (_titleRequired && title.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _kind == kNoteKindSchedule ? '日常必须填写标题' : '文章必须填写标题',
            ),
          ),
        );
        return false;
      }
      if (_kind == kNoteKindSchedule && _scheduleAt == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请设置日常时间')),
        );
        return false;
      }
      if (plain.isEmpty && title.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('写点内容再$_primaryActionLabel')),
        );
        return false;
      }
    } else if (title.isEmpty) {
      title = suggestNoteTitle(
        title: '',
        body: body,
        fallback: _kindNoun,
      );
    }

    final freq = _kind == kNoteKindSchedule ? _recurFreq : kRecurOnce;
    String? byday;
    DateTime? until;
    int? count;
    var offset = 0;
    DateTime? remind = _remindAt;
    DateTime? schedule = _scheduleAt;

    if (_kind == kNoteKindSchedule) {
      offset = _remindOffsetMin < 0 ? -1 : _remindOffsetMin;
      remind = schedule == null ? null : remindAtFromOffset(schedule, offset);
      if (freq == kRecurWeekly) {
        byday = (_recurByday?.isNotEmpty == true)
            ? _recurByday
            : (schedule != null ? weekdayToByDay(schedule) : 'MO');
      }
      if (isRecurringFreq(freq)) {
        if (_recurEndMode == 'until') {
          until = _recurUntil;
          count = null;
        } else if (_recurEndMode == 'count') {
          count = _recurCount;
          until = null;
        } else {
          until = null;
          count = null;
        }
      }
    } else {
      // 备忘 / 笔记 / 文章：不写提醒时间（备忘不再有提醒 UI）
      schedule = null;
      remind = null;
    }

    final store = context.read<AppStore>();
    _saving = true;
    try {
      Future<void> task() async {
        if (_existing == null) {
          final id = await store.addNote(
            kind: _kind,
            title: title,
            body: body,
            format: kNoteFormatQuill,
            scheduleAt: schedule,
            remindAt: remind,
            recurFreq: freq == kRecurOnce ? '' : freq,
            recurByday: byday,
            recurUntil: until,
            recurCount: count,
            remindOffsetMin: offset,
            city: _cityCtrl.text.trim(),
            coverUrl: _kind == kNoteKindArticle ? _coverUrl.trim() : '',
          );
          final created = await store.db.noteById(id);
          if (created != null) _existing = created;
          // 文章→阅读；谏言→侧栏推荐
          if ((_kind == kNoteKindArticle || _kind == kNoteKindAdmonition) &&
              created != null) {
            await store.setNoteListing(noteId: created.id, listed: true);
            _listed = true;
          }
        } else {
          await store.saveNote(
            id: _existing!.id,
            kind: _kind,
            title: title,
            body: body,
            format: kNoteFormatQuill,
            scheduleAt: schedule,
            clearScheduleAt: schedule == null,
            remindAt: remind,
            clearRemindAt: remind == null,
            recurFreq: freq == kRecurOnce ? '' : freq,
            recurByday: byday,
            clearRecurByday: byday == null,
            recurUntil: until,
            clearRecurUntil: until == null,
            recurCount: count,
            clearRecurCount: count == null,
            remindOffsetMin: offset,
            city: _cityCtrl.text.trim(),
            coverUrl: _kind == kNoteKindArticle ? _coverUrl.trim() : '',
            clearCoverUrl: _kind != kNoteKindArticle,
          );
          if (_kind == kNoteKindArticle || _kind == kNoteKindAdmonition) {
            await store.setNoteListing(noteId: _existing!.id, listed: true);
            _listed = true;
          } else if (_existing!.isListed) {
            await store.setNoteListing(noteId: _existing!.id, listed: false);
            _listed = false;
          }
        }
        if (_kind == kNoteKindArticle) {
          await store.refreshMarketplace();
        }
      }

      if (!mounted) {
        await task();
      } else {
        await runBusy(context, message: _busyMessage, task: task);
      }
      // 采基线前同步 listed，避免文章/谏言保存后仍判脏
      _captureBaseline();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$_primaryActionLabel失败：$e')),
        );
      }
      return false;
    } finally {
      _saving = false;
    }
  }

  Future<void> _save() async {
    if (!_isDirty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final ok = await _persist(strict: true);
    // 成功后一律 pop；跳转到阅读「我的」等深层 Tab 切换暂不做。
    if (ok && mounted) Navigator.of(context).pop();
  }

  /// 离开守卫：空草稿 / 未改动直接走；否则询问是否保存。
  Future<bool> _confirmLeave() async {
    if (_saving) return false;
    final plain = bodyPlain(_quill);
    final title = _titleCtrl.text.trim();
    if (plain.isEmpty && title.isEmpty && _existing == null) {
      return true;
    }
    if (!_isDirty) return true;

    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          content: Text(
            '离开当前$_kindNoun可能丢失\n是否$_primaryActionLabel？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'yes'),
              child: const Text('是'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'no'),
              child: const Text('否'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'back'),
              child: const Text('返回'),
            ),
          ],
        );
      },
    );
    if (choice == 'yes') {
      return await _persist(strict: true);
    }
    if (choice == 'no') return true;
    return false;
  }

  /// 与阅读页 `.reader-cover` / CoverImage 16:9 一致，所见即所得。
  Widget _coverPicker(ColorScheme cs) {
    final url = _coverUrl.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '封面（与发布后阅读页同为 16:9）',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: 6),
        Material(
          color: const Color(0xFFF0F0F0),
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _aiBusy ? null : _pickCover,
            child: url.isEmpty
                ? const AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_photo_alternate_outlined, size: 28),
                          SizedBox(height: 6),
                          Text('上传封面', style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  )
                : Stack(
                    children: [
                      CoverImage(
                        url: url,
                        aspectRatio: 16 / 9,
                        borderRadius: 0,
                      ),
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                backgroundColor: const Color(0x88000000),
                              ),
                              onPressed: _aiBusy ? null : _pickCover,
                              child: const Text('更换'),
                            ),
                            const SizedBox(width: 4),
                            TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                backgroundColor: const Color(0x88000000),
                              ),
                              onPressed: _aiBusy
                                  ? null
                                  : () => setState(() => _coverUrl = ''),
                              child: const Text('清除'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _openArticlePreview() async {
    final title = _titleCtrl.text.trim().isEmpty
        ? suggestNoteTitle(
            title: '',
            body: jsonEncode(_quill.document.toDelta().toJson()),
            fallback: '文章',
          )
        : _titleCtrl.text.trim();
    final previewQuill = QuillController(
      document: Document.fromJson(_quill.document.toDelta().toJson()),
      selection: const TextSelection.collapsed(offset: 0),
    );
    final focus = FocusNode();
    if (!mounted) {
      previewQuill.dispose();
      focus.dispose();
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: const Text('预览（发布后效果）'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              if (_coverUrl.trim().isNotEmpty) ...[
                CoverImage(
                  url: _coverUrl.trim(),
                  aspectRatio: 16 / 9,
                  borderRadius: 10,
                ),
                const SizedBox(height: 14),
              ],
              Text(
                title,
                style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 12),
              QuillEditor(
                controller: previewQuill,
                focusNode: focus,
                scrollController: ScrollController(),
                scrollable: false,
                padding: EdgeInsets.zero,
                autoFocus: false,
                readOnly: true,
                expands: false,
                showCursor: false,
                enableInteractiveSelection: true,
                embedBuilders: kNoteEmbedBuilders,
              ),
            ],
          ),
        ),
      ),
    );
    previewQuill.dispose();
    focus.dispose();
  }

  Widget _kindChip(String kind, String label) {
    final selected = _kind == kind;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected ? const Color(0xFF111111) : const Color(0xFFF0F0F0),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _aiBusy
              ? null
              : () {
            setState(() {
              _kind = kind;
              _aiExpanded = _aiDefaultExpanded;
              if (kind == kNoteKindSchedule && _scheduleAt != null) {
                _remindAt =
                    remindAtFromOffset(_scheduleAt, _remindOffsetMin);
              }
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: selected ? Colors.white : const Color(0xFF111111),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _freqChip(String freq, String label) {
    final selected = _recurFreq == freq;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) {
          setState(() {
            _recurFreq = freq;
            if (freq == kRecurWeekly && _scheduleAt != null) {
              _recurByday ??= weekdayToByDay(_scheduleAt!);
            }
            if (freq == kRecurOnce) {
              _recurEndMode = 'never';
              _recurUntil = null;
              _recurCount = null;
            }
          });
        },
      ),
    );
  }

  List<Widget> _scheduleOptions() {
    return [
      ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: const Text('日常时间'),
        subtitle: Text(_scheduleAt == null ? '未设置' : ymdHm(_scheduleAt!)),
        trailing: TextButton(
          onPressed: () => _pickDateTime(schedule: true),
          child: const Text('选择'),
        ),
      ),
      const SizedBox(height: 4),
      Text('重复', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 4),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _freqChip(kRecurOnce, '一次性'),
            _freqChip(kRecurDaily, '每天'),
            _freqChip(kRecurWeekly, '每周'),
            _freqChip(kRecurMonthly, '每月'),
            _freqChip(kRecurYearly, '每年'),
          ],
        ),
      ),
      if (_recurFreq == kRecurWeekly) ...[
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          children: List.generate(7, (i) {
            final code = kRecurByDayCodes[i];
            const labels = ['一', '二', '三', '四', '五', '六', '日'];
            final selected = (_recurByday ??
                    (_scheduleAt != null
                        ? weekdayToByDay(_scheduleAt!)
                        : 'MO')) ==
                code;
            return ChoiceChip(
              label: Text('周${labels[i]}'),
              selected: selected,
              onSelected: (_) => setState(() => _recurByday = code),
            );
          }),
        ),
      ],
      if (isRecurringFreq(_recurFreq)) ...[
        const SizedBox(height: 8),
        Text('结束', style: Theme.of(context).textTheme.labelLarge),
        RadioListTile<String>(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('永不'),
          value: 'never',
          groupValue: _recurEndMode,
          onChanged: (v) => setState(() {
            _recurEndMode = v!;
            _recurUntil = null;
            _recurCount = null;
          }),
        ),
        RadioListTile<String>(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            _recurUntil == null
                ? '结束日期'
                : '结束日期 · ${ymd(_recurUntil!)}',
          ),
          value: 'until',
          groupValue: _recurEndMode,
          onChanged: (v) async {
            setState(() => _recurEndMode = v!);
            await _pickRecurUntil();
          },
          secondary: TextButton(
            onPressed: _pickRecurUntil,
            child: const Text('选日期'),
          ),
        ),
        RadioListTile<String>(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Row(
            children: [
              const Text('重复次数'),
              const SizedBox(width: 12),
              SizedBox(
                width: 64,
                child: TextField(
                  controller: _recurCountCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '次',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (s) {
                    final c = int.tryParse(s.trim());
                    setState(() {
                      _recurEndMode = 'count';
                      _recurCount = c;
                      _recurUntil = null;
                    });
                  },
                ),
              ),
            ],
          ),
          value: 'count',
          groupValue: _recurEndMode,
          onChanged: (v) => setState(() {
            _recurEndMode = v!;
            _recurUntil = null;
            _recurCount ??= 10;
            _recurCountCtrl.text = '${_recurCount!}';
          }),
        ),
      ],
      ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: const Text('提醒'),
        subtitle: Text(formatRemindOffset(_remindOffsetMin)),
        trailing: TextButton(
          onPressed: _pickRemindOffset,
          child: const Text('选择'),
        ),
      ),
    ];
  }

  NoteDraftGetters get _draftGetters => (
        title: () => _titleCtrl.text,
        plain: () => bodyPlain(_quill),
        deltaJson: () => jsonEncode(_quill.document.toDelta().toJson()),
        optionsJson: () => jsonEncode(_optionsSnapshot()),
      );

  NoteDraftSetters get _draftSetters => (
        setTitle: (t) {
          _titleCtrl.text = t;
          setState(() {});
        },
        replacePlain: (plain) {
          replaceWithPlain(_quill, sanitizeAiPlainText(plain));
          setState(() {});
        },
        appendPlain: (plain) {
          appendWithPlain(_quill, sanitizeAiPlainText(plain));
          setState(() {});
        },
        replaceDelta: (delta) {
          replaceWithDeltaJson(_quill, delta);
          setState(() {});
        },
        applyFormat: (ops) {
          applyDraftFormat(_quill, ops);
          setState(() {});
        },
        setOptions: _applyNoteOptions,
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final cs = Theme.of(context).colorScheme;

    return WillPopScope(
      onWillPop: _confirmLeave,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_existing == null ? '新$_kindNoun' : '编辑$_kindNoun'),
          actions: [
            if (_kind == kNoteKindArticle)
              TextButton(
                onPressed: _aiBusy ? null : _openArticlePreview,
                child: const Text('预览'),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: FilledButton(
                onPressed: _aiBusy ? null : _save,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                child: Text(_primaryActionLabel),
              ),
            ),
          ],
        ),
        body: Column(
        children: [
          Expanded(
            child: AbsorbPointer(
              absorbing: _aiBusy,
              child: Opacity(
                opacity: _aiBusy ? 0.55 : 1,
                child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              children: [
                Text(
                  _kindHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _kindChip(kNoteKindNote, '笔记'),
                      _kindChip(kNoteKindMemo, '备忘'),
                      _kindChip(kNoteKindSchedule, '日常'),
                      _kindChip(kNoteKindArticle, '文章'),
                      if (_isAdmin)
                        _kindChip(kNoteKindAdmonition, '谏言'),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _titleCtrl,
                  readOnly: _aiBusy,
                  decoration: InputDecoration(
                    labelText: _titleRequired ? '标题（必填）' : '标题（可选）',
                    hintText: _titleRequired ? '必填标题' : '标题（可选）',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                if (_kind == kNoteKindArticle) ...[
                  const SizedBox(height: 8),
                  _coverPicker(cs),
                ],
                if (_kind == kNoteKindSchedule) ...[
                  const SizedBox(height: 4),
                  ..._scheduleOptions(),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: QuillToolbar.basic(
                        controller: _quill,
                        multiRowsDisplay: false,
                        showFontFamily: false,
                        showInlineCode: false,
                        showColorButton: false,
                        showBackgroundColorButton: false,
                        showCodeBlock: false,
                        showQuote: false,
                        showLink: false,
                        showSearchButton: false,
                        showSubscript: false,
                        showSuperscript: false,
                        showStrikeThrough: false,
                        showUnderLineButton: false,
                        showListNumbers: true,
                        showListBullets: true,
                        showListCheck: false,
                        showIndent: false,
                        showAlignmentButtons: true,
                        showDirection: false,
                        toolbarIconSize: 18,
                      ),
                    ),
                    IconButton(
                      tooltip: '插入图片',
                      onPressed: _aiBusy ? null : _insertBodyImage,
                      icon: const Icon(Icons.image_outlined, size: 22),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Stack(
                  children: [
                    Container(
                      constraints: const BoxConstraints(minHeight: 160),
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.outline),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      padding: const EdgeInsets.fromLTRB(8, 8, 36, 8),
                      child: QuillEditor(
                        controller: _quill,
                        focusNode: _editorFocus,
                        scrollController: _editorScroll,
                        scrollable: true,
                        padding: EdgeInsets.zero,
                        autoFocus: false,
                        readOnly: _aiBusy,
                        expands: false,
                        minHeight: 150,
                        placeholder: '写点什么…',
                        embedBuilders: kNoteEmbedBuilders,
                      ),
                    ),
                    if (!_aiBusy)
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: NoteMicButton(
                          key: _micKey,
                          onText: _insertVoiceText,
                        ),
                      ),
                  ],
                ),
              ],
            ),
              ),
            ),
          ),
          Divider(height: 1, color: cs.outline),
          if (_aiExpanded)
            Expanded(
              child: NoteAiPanel(
                refKey: _aiRefKey,
                expanded: true,
                onExpandedChanged: (v) => setState(() => _aiExpanded = v),
                onBusyChanged: (v) => setState(() => _aiBusy = v),
                getters: _draftGetters,
                setters: _draftSetters,
              ),
            )
          else
            NoteAiPanel(
              refKey: _aiRefKey,
              expanded: false,
              onExpandedChanged: (v) => setState(() => _aiExpanded = v),
              onBusyChanged: (v) => setState(() => _aiBusy = v),
              getters: _draftGetters,
              setters: _draftSetters,
            ),
        ],
      ),
    ),
    );
  }
}
