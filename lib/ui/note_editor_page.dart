import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' hide Text;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../domain/note_recur.dart';
import '../domain/note_title.dart';
import '../state/app_store.dart';
import 'busy.dart';
import 'format.dart';
import 'note_ai_panel.dart';
import 'note_quill.dart';
import 'voice_input_bar.dart';

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
  bool _loading = true;
  bool _saving = false;
  Note? _existing;
  late String _aiRefKey;
  late bool _aiExpanded;

  bool get _titleRequired =>
      _kind == kNoteKindSchedule || _kind == kNoteKindArticle;

  bool get _aiDefaultExpanded =>
      _kind == kNoteKindNote || _kind == kNoteKindArticle;

  @override
  void initState() {
    super.initState();
    _quill = QuillController.basic();
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
      } else if (_kind == kNoteKindMemo) {
        _remindAt = widget.initialScheduleAt;
      }
    }
    _aiExpanded = _aiDefaultExpanded;
    _load();
  }

  Future<void> _load() async {
    if (widget.noteId == null) {
      setState(() => _loading = false);
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
      _quill.dispose();
      _quill = QuillController(
        document: documentFromBody(n.body, format: n.format),
        selection: const TextSelection.collapsed(offset: 0),
      );
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
        _remindOffsetMin = n.remindOffsetMin > 0
            ? n.remindOffsetMin
            : offsetMinFromRemind(_scheduleAt, _remindAt);
        _remindAt = remindAtFromOffset(_scheduleAt, _remindOffsetMin);
      }
      _listed = n.isListed;
      _cityCtrl.text = n.city;
    }
    setState(() => _loading = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editorFocus.requestFocus();
    });
  }

  @override
  void dispose() {
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
            schedule ? '日程开始时间须晚于现在' : '提醒时间须晚于现在',
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
      ('日程开始时', 0),
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
                onTap: () => Navigator.pop(ctx, -1),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || picked == null) return;
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
    _quill.replaceText(
      index,
      0,
      t,
      TextSelection.collapsed(offset: index + t.length),
    );
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
      'listed': _listed,
      'city': _cityCtrl.text.trim(),
    };
  }

  void _applyNoteOptions(Map<String, dynamic> args) {
    setState(() {
      if (args.containsKey('kind')) {
        final k = '${args['kind']}'.trim();
        if (k.isNotEmpty) {
          _kind = k;
          _aiExpanded = _aiDefaultExpanded;
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
        } else {
          _remindAt = DateTime.tryParse('$raw')?.toLocal();
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
        _remindOffsetMin = m < 0 ? 0 : m;
        if (_kind == kNoteKindSchedule) {
          _remindAt = remindAtFromOffset(_scheduleAt, _remindOffsetMin);
        }
      } else if (_kind == kNoteKindSchedule &&
          args.containsKey('schedule_at')) {
        _remindAt = remindAtFromOffset(_scheduleAt, _remindOffsetMin);
      }
      if (args.containsKey('listed')) {
        final v = args['listed'];
        _listed = v == true || v == 1 || '$v' == 'true';
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
          const SnackBar(content: Text('写点内容再保存')),
        );
        return false;
      }
    }

    if (strict) {
      if (_titleRequired && title.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _kind == kNoteKindSchedule ? '日程必须填写标题' : '文章必须填写标题',
            ),
          ),
        );
        return false;
      }
      if (_kind == kNoteKindSchedule && _scheduleAt == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请设置日程时间')),
        );
        return false;
      }
      if (plain.isEmpty && title.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('写点内容再保存')),
        );
        return false;
      }
    } else if (title.isEmpty) {
      title = suggestNoteTitle(
        title: '',
        body: body,
        fallback: _kind == kNoteKindArticle
            ? '文章'
            : _kind == kNoteKindSchedule
                ? '日程'
                : _kind == kNoteKindMemo
                    ? '备忘'
                    : '随笔',
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
      offset = _remindOffsetMin < 0 ? 0 : _remindOffsetMin;
      remind = schedule == null ? remind : remindAtFromOffset(schedule, offset);
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
    } else if (_kind != kNoteKindMemo) {
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
          );
          if (_listed && _kind == kNoteKindArticle) {
            await store.setNoteListing(
              noteId: id,
              listed: true,
              city: _cityCtrl.text.trim(),
            );
          }
          final created = await store.db.noteById(id);
          if (created != null) _existing = created;
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
          );
          if (_kind == kNoteKindArticle) {
            await store.setNoteListing(
              noteId: _existing!.id,
              listed: _listed,
              city: _cityCtrl.text.trim(),
            );
          }
        }
      }

      // 点保存 / 返回自动保存都弹模态框，避免网络同步时页面「卡住无提示」
      if (!mounted) {
        await task();
      } else {
        await runBusy(context, message: '正在保存…', task: task);
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e')),
        );
      }
      // 返回自动保存失败时仍允许离开，避免卡死在编辑页
      return !strict;
    } finally {
      _saving = false;
    }
  }

  Future<void> _save() async {
    final ok = await _persist(strict: true);
    if (ok && mounted) Navigator.of(context).pop();
  }

  Future<bool> _autoSaveAndLeave() async {
    if (_saving) return false;
    final plain = bodyPlain(_quill);
    final title = _titleCtrl.text.trim();
    // 空草稿直接走，不弹保存框
    if (plain.isEmpty && title.isEmpty && _existing == null) {
      return true;
    }
    await _persist(strict: false);
    return true;
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
          onTap: () {
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
        title: const Text('日程时间'),
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
          replaceWithPlain(_quill, plain);
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
    final needTime = _kind == kNoteKindMemo || _kind == kNoteKindSchedule;
    final cs = Theme.of(context).colorScheme;

    return WillPopScope(
      onWillPop: _autoSaveAndLeave,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_existing == null ? '新笔记' : '编辑笔记'),
          actions: [
            TextButton(onPressed: _save, child: const Text('保存')),
          ],
        ),
        body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _kindChip(kNoteKindNote, '随笔'),
                      _kindChip(kNoteKindArticle, '文章'),
                      _kindChip(kNoteKindMemo, '备忘'),
                      _kindChip(kNoteKindSchedule, '日程'),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _titleCtrl,
                  decoration: InputDecoration(
                    labelText: _titleRequired ? '标题（必填）' : '标题（可选）',
                    hintText: _titleRequired ? '必填标题' : '标题（可选）',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                if (needTime) ...[
                  const SizedBox(height: 4),
                  if (_kind == kNoteKindMemo)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('提醒时间'),
                      subtitle: Text(
                        _remindAt == null ? '未设置' : ymdHm(_remindAt!),
                      ),
                      trailing: TextButton(
                        onPressed: () => _pickDateTime(schedule: false),
                        child: const Text('选择'),
                      ),
                    )
                  else
                    ..._scheduleOptions(),
                ],
                if (_kind == kNoteKindArticle) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('上架到市集'),
                    subtitle: const Text('游客可在市集「文章」浏览'),
                    value: _listed,
                    onChanged: (v) => setState(() => _listed = v),
                  ),
                  TextField(
                    controller: _cityCtrl,
                    decoration: const InputDecoration(
                      labelText: '城市（上架筛选，可空）',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                QuillToolbar.basic(
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
                  showListCheck: false,
                  showIndent: false,
                  showAlignmentButtons: true,
                  showDirection: false,
                  toolbarIconSize: 18,
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
                        readOnly: false,
                        expands: false,
                        minHeight: 150,
                        placeholder: '写点什么…',
                      ),
                    ),
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: NoteMicButton(onText: _insertVoiceText),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: cs.outline),
          if (_aiExpanded)
            Expanded(
              child: NoteAiPanel(
                refKey: _aiRefKey,
                expanded: true,
                onExpandedChanged: (v) => setState(() => _aiExpanded = v),
                getters: _draftGetters,
                setters: _draftSetters,
              ),
            )
          else
            NoteAiPanel(
              refKey: _aiRefKey,
              expanded: false,
              onExpandedChanged: (v) => setState(() => _aiExpanded = v),
              getters: _draftGetters,
              setters: _draftSetters,
            ),
        ],
      ),
    ),
    );
  }
}
