import '../domain/ai_text.dart';
import '../domain/models.dart';
import '../domain/note_recur.dart';
import '../state/app_store.dart';
import 'agent_models.dart';

const writeTools = {
  'create_note',
  'update_note',
  'convert_note_kind',
  'merge_notes_to_article',
  'publish_note',
  'unpublish_note',
};

/// 游客只下发只读 tools，避免模型提议写操作。
List<Map<String, dynamic>> toolSchemasFor({required bool landlord}) {
  if (landlord) return toolSchemas;
  return toolSchemas.where((t) {
    final fn = t['function'];
    if (fn is! Map) return false;
    final name = '${fn['name']}';
    return !writeTools.contains(name);
  }).toList();
}

/// OpenAI-compatible tools schema（发给大模型用）。
final List<Map<String, dynamic>> toolSchemas = [
  {
    'type': 'function',
    'function': {
      'name': 'list_notes',
      'description': '列出笔记本内容（随笔/备忘/日程/文章）',
      'parameters': {
        'type': 'object',
        'properties': {
          'kind': {
            'type': 'string',
            'description': 'note|memo|schedule|article，空=全部',
          },
        },
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'create_note',
      'description':
          '新建一条笔记。kind: note随笔/memo备忘/schedule日程/article文章。'
          '写文章时 title+body 都要有实质内容；body 用纯文本（不要 Markdown/代码块/JSON）。'
          '日程可设 recur_freq(once|daily|weekly|monthly|yearly)、recur_byday、'
          'recur_until/recur_count（结束，互斥）、remind_offset_min（提前分钟，-1=不提醒）。'
          'remind_at 仅备忘；禁止设为当前时间之前；不提醒则不传或空串。',
      'parameters': {
        'type': 'object',
        'properties': {
          'kind': {'type': 'string'},
          'title': {'type': 'string'},
          'body': {'type': 'string'},
          'schedule_at': {
            'type': 'string',
            'description': 'ISO8601 日程时间',
          },
          'remind_at': {
            'type': 'string',
            'description': 'ISO8601 备忘提醒；空或不传=不提醒；须晚于现在',
          },
          'recur_freq': {'type': 'string'},
          'recur_byday': {'type': 'string'},
          'recur_until': {'type': 'string'},
          'recur_count': {'type': 'integer'},
          'remind_offset_min': {'type': 'integer'},
        },
        'required': ['body'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'update_note',
      'description': '按 note_id 或标题关键词改笔记正文/标题/时间/重复/提醒',
      'parameters': {
        'type': 'object',
        'properties': {
          'note_id': {'type': 'integer'},
          'title_query': {'type': 'string', 'description': '用标题或正文开头匹配'},
          'title': {'type': 'string'},
          'body': {'type': 'string'},
          'schedule_at': {'type': 'string'},
          'remind_at': {'type': 'string'},
          'recur_freq': {'type': 'string'},
          'recur_byday': {'type': 'string'},
          'recur_until': {'type': 'string'},
          'recur_count': {'type': 'integer'},
          'remind_offset_min': {'type': 'integer'},
        },
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'convert_note_kind',
      'description': '把一篇笔记改成另一种形态（随笔/备忘/日程/文章），不自动上架',
      'parameters': {
        'type': 'object',
        'properties': {
          'note_id': {'type': 'integer'},
          'title_query': {'type': 'string'},
          'new_kind': {'type': 'string'},
          'schedule_at': {'type': 'string'},
          'remind_at': {'type': 'string'},
          'recur_freq': {'type': 'string'},
          'recur_byday': {'type': 'string'},
          'recur_until': {'type': 'string'},
          'recur_count': {'type': 'integer'},
          'remind_offset_min': {'type': 'integer'},
        },
        'required': ['new_kind'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'merge_notes_to_article',
      'description':
          '把一篇或多篇笔记整理成一篇新文章；默认保留原文。body 填整理后的正文',
      'parameters': {
        'type': 'object',
        'properties': {
          'note_ids': {
            'type': 'array',
            'items': {'type': 'integer'},
          },
          'title_queries': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'title': {'type': 'string'},
          'body': {'type': 'string'},
          'archive_sources': {
            'type': 'boolean',
            'description': 'true 时软删原文，默认 false',
          },
        },
        'required': ['body'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'publish_note',
      'description': '把文章上架到雅集',
      'parameters': {
        'type': 'object',
        'properties': {
          'note_id': {'type': 'integer'},
          'title_query': {'type': 'string'},
          'city': {'type': 'string'},
        },
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'unpublish_note',
      'description': '下架雅集文章',
      'parameters': {
        'type': 'object',
        'properties': {
          'note_id': {'type': 'integer'},
          'title_query': {'type': 'string'},
        },
      },
    },
  },
];

class AgentToolRunner {
  AgentToolRunner(this.store);

  final AppStore store;

  String summarize(String tool, Map<String, dynamic> args) {
    switch (tool) {
      case 'create_note':
        return '记一条${_kindLabel(args['kind'])}：'
            '${_snip(args['title'] ?? args['body'])}';
      case 'update_note':
        return '更新笔记 ${_snip(args['title_query'] ?? args['note_id'])}';
      case 'convert_note_kind':
        return '把笔记改成${_kindLabel(args['new_kind'])}';
      case 'merge_notes_to_article':
        return '整理成文章「${_snip(args['title'] ?? '无标题')}」（保留原文）';
      case 'publish_note':
        return '上架文章到雅集';
      case 'unpublish_note':
        return '下架雅集文章';
      default:
        return '执行 $tool';
    }
  }

  String _kindLabel(dynamic kind) {
    switch ('$kind') {
      case 'memo':
        return '备忘';
      case 'schedule':
        return '日程';
      case 'article':
        return '文章';
      default:
        return '随笔';
    }
  }

  String _snip(dynamic raw) {
    final s = '$raw'.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (s.isEmpty) return '（无标题）';
    return s.length > 24 ? '${s.substring(0, 24)}…' : s;
  }

  Future<String> runRead(String tool, Map<String, dynamic> args) async {
    switch (tool) {
      case 'list_notes':
        return _listNotes(args['kind']?.toString());
      default:
        throw StateError('$tool 不是只读工具');
    }
  }

  Future<String> _listNotes(String? kind) async {
    final notes = await store.notesOf(
      kind: (kind == null || kind.trim().isEmpty) ? null : kind.trim(),
    );
    if (notes.isEmpty) return '笔记本是空的。';
    final buf = StringBuffer('笔记列表：\n');
    for (final n in notes.take(40)) {
      final extra = noteRecurRemindSummary(n);
      buf.writeln(
        '· #${n.id} [${n.kindLabel}] ${n.displayTitle}'
        '${n.isListed ? '（已上架）' : ''}'
        '${extra.isEmpty ? '' : ' · $extra'}',
      );
    }
    return buf.toString().trimRight();
  }

  Future<Note?> _resolveNote(Map<String, dynamic> args) async {
    final idRaw = args['note_id'];
    final id = idRaw is int ? idRaw : int.tryParse('$idRaw');
    if (id != null) return store.db.noteById(id);
    final q = '${args['title_query'] ?? ''}'.trim();
    if (q.isEmpty) return null;
    final all = await store.notesOf();
    for (final n in all) {
      if (n.title.contains(q) ||
          n.body.contains(q) ||
          n.displayTitle.contains(q)) {
        return n;
      }
    }
    return null;
  }

  DateTime? _parseNoteTs(dynamic raw, {bool mustBeFuture = false}) {
    if (raw == null) return null;
    final s = '$raw'.trim();
    if (s.isEmpty) return null;
    final dt = DateTime.tryParse(s);
    if (dt == null) return null;
    final local = dt.isUtc ? dt.toLocal() : dt;
    if (mustBeFuture) return sanitizeFutureRemind(local);
    return local;
  }

  int? _parseIntArg(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    return int.tryParse('$raw'.trim());
  }

  ({
    String recurFreq,
    String? recurByday,
    DateTime? recurUntil,
    int? recurCount,
    bool clearUntil,
    bool clearCount,
    bool clearByday,
    int? remindOffsetMin,
    DateTime? remindAt,
  }) _parseRecurArgs(
    Map<String, dynamic> args, {
    DateTime? scheduleAt,
    String? kind,
  }) {
    final freqRaw = args.containsKey('recur_freq')
        ? normalizeRecurFreq('${args['recur_freq']}')
        : null;
    final freq = freqRaw ?? '';
    String? byday;
    var clearByday = false;
    if (args.containsKey('recur_byday')) {
      final b = '${args['recur_byday']}'.trim().toUpperCase();
      if (b.isEmpty) {
        clearByday = true;
        byday = null;
      } else {
        byday = b;
      }
    } else if (freq == kRecurWeekly && scheduleAt != null) {
      byday = weekdayToByDay(scheduleAt);
    }

    DateTime? until;
    int? count;
    var clearUntil = false;
    var clearCount = false;
    final hasUntil = args.containsKey('recur_until');
    final hasCount = args.containsKey('recur_count');
    if (hasUntil) {
      final raw = args['recur_until'];
      if (raw == null || '$raw'.trim().isEmpty) {
        clearUntil = true;
        until = null;
      } else {
        until = _parseNoteTs(raw);
        clearCount = true;
        count = null;
      }
    }
    if (hasCount) {
      final raw = args['recur_count'];
      if (raw == null || '$raw'.trim().isEmpty) {
        clearCount = true;
        count = null;
      } else {
        count = _parseIntArg(raw);
        clearUntil = true;
        until = null;
      }
    }

    int? offset;
    DateTime? remind =
        _parseNoteTs(args['remind_at'], mustBeFuture: true);
    if (args.containsKey('remind_offset_min')) {
      final parsed = _parseIntArg(args['remind_offset_min']) ?? 0;
      // <0：不提醒；否则提前分钟数
      offset = parsed < 0 ? -1 : parsed;
      if (kind == kNoteKindSchedule || kind == null) {
        remind = remindAtFromOffset(scheduleAt, offset);
        remind = sanitizeFutureRemind(remind);
        if (remind == null && offset >= 0 && scheduleAt != null) {
          // 推算出的提醒已过期 → 改为不提醒
          offset = -1;
        }
      }
    }

    return (
      recurFreq: freq,
      recurByday: byday,
      recurUntil: until,
      recurCount: count,
      clearUntil: clearUntil,
      clearCount: clearCount,
      clearByday: clearByday,
      remindOffsetMin: offset,
      remindAt: remind,
    );
  }

  Future<String> commit(PendingAction action) async {
    if (store.isGuest) {
      return '游客不能改笔记本。请先注册/登录后再操作。';
    }
    final args = action.args;
    switch (action.tool) {
      case 'create_note':
        final kind = '${args['kind'] ?? kNoteKindNote}'.trim();
        final k = kind.isEmpty ? kNoteKindNote : kind;
        final scheduleAt = _parseNoteTs(args['schedule_at']);
        final recur = _parseRecurArgs(args, scheduleAt: scheduleAt, kind: k);
        final remind = recur.remindAt ??
            _parseNoteTs(args['remind_at'], mustBeFuture: true);
        final id = await store.addNote(
          kind: k,
          title: '${args['title'] ?? ''}'.trim(),
          body: sanitizeAiPlainText('${args['body'] ?? ''}'),
          scheduleAt: scheduleAt,
          remindAt: remind,
          recurFreq: recur.recurFreq == kRecurOnce ? '' : recur.recurFreq,
          recurByday: recur.recurByday,
          recurUntil: recur.recurUntil,
          recurCount: recur.recurCount,
          remindOffsetMin: recur.remindOffsetMin ??
              (k == kNoteKindSchedule && remind == null ? -1 : 0),
        );
        return '已记下${_kindLabel(k)} #$id。';
      case 'update_note':
        final note = await _resolveNote(args);
        if (note == null) return '找不到要改的笔记。';
        final scheduleAt = args.containsKey('schedule_at')
            ? _parseNoteTs(args['schedule_at'])
            : note.scheduleAt;
        final recur = _parseRecurArgs(
          args,
          scheduleAt: scheduleAt,
          kind: note.kind,
        );
        await store.saveNote(
          id: note.id,
          title: args.containsKey('title') ? '${args['title']}'.trim() : null,
          body: args.containsKey('body')
              ? sanitizeAiPlainText('${args['body']}')
              : null,
          scheduleAt: args.containsKey('schedule_at') ? scheduleAt : null,
          clearScheduleAt:
              args.containsKey('schedule_at') && scheduleAt == null,
          remindAt: recur.remindAt ??
              (args.containsKey('remind_at')
                  ? _parseNoteTs(args['remind_at'], mustBeFuture: true)
                  : null),
          clearRemindAt: (args.containsKey('remind_at') &&
                  (args['remind_at'] == null ||
                      '${args['remind_at']}'.trim().isEmpty) &&
                  recur.remindOffsetMin == null) ||
              recur.remindOffsetMin == -1,
          recurFreq: args.containsKey('recur_freq')
              ? (recur.recurFreq == kRecurOnce ? '' : recur.recurFreq)
              : null,
          recurByday: recur.recurByday,
          clearRecurByday: recur.clearByday,
          recurUntil: recur.recurUntil,
          clearRecurUntil: recur.clearUntil,
          recurCount: recur.recurCount,
          clearRecurCount: recur.clearCount,
          remindOffsetMin: recur.remindOffsetMin,
        );
        return '已更新笔记 #${note.id}。';
      case 'convert_note_kind':
        final note = await _resolveNote(args);
        if (note == null) return '找不到要转换的笔记。';
        final newKind = '${args['new_kind']}'.trim();
        if (newKind.isEmpty) return '请指定 new_kind。';
        final scheduleAt = args.containsKey('schedule_at')
            ? _parseNoteTs(args['schedule_at'])
            : note.scheduleAt;
        final recur = _parseRecurArgs(
          args,
          scheduleAt: scheduleAt,
          kind: newKind,
        );
        await store.saveNote(
          id: note.id,
          kind: newKind,
          scheduleAt: args.containsKey('schedule_at') ? scheduleAt : null,
          remindAt: recur.remindAt ??
              (args.containsKey('remind_at')
                  ? _parseNoteTs(args['remind_at'], mustBeFuture: true)
                  : null),
          clearRemindAt: recur.remindOffsetMin == -1,
          recurFreq: args.containsKey('recur_freq')
              ? (recur.recurFreq == kRecurOnce ? '' : recur.recurFreq)
              : null,
          recurByday: recur.recurByday,
          clearRecurByday: recur.clearByday,
          recurUntil: recur.recurUntil,
          clearRecurUntil: recur.clearUntil,
          recurCount: recur.recurCount,
          clearRecurCount: recur.clearCount,
          remindOffsetMin: recur.remindOffsetMin,
        );
        return '已把 #${note.id} 改成${_kindLabel(newKind)}。';
      case 'merge_notes_to_article':
        final ids = <int>{};
        final idList = args['note_ids'];
        if (idList is List) {
          for (final e in idList) {
            final id = e is int ? e : int.tryParse('$e');
            if (id != null) ids.add(id);
          }
        }
        final queries = args['title_queries'];
        if (queries is List) {
          final all = await store.notesOf();
          for (final q in queries) {
            final s = '$q'.trim();
            if (s.isEmpty) continue;
            for (final n in all) {
              if (n.title.contains(s) || n.body.contains(s)) ids.add(n.id);
            }
          }
        }
        final sources = <Note>[];
        for (final id in ids) {
          final n = await store.db.noteById(id);
          if (n != null) sources.add(n);
        }
        final body = sanitizeAiPlainText('${args['body'] ?? ''}');
        if (body.isEmpty) return '整理后的正文不能为空。';
        final newId = await store.addNote(
          kind: kNoteKindArticle,
          title: '${args['title'] ?? ''}'.trim(),
          body: body,
          sourceNoteUuids: sources.map((e) => e.uuid).toList(),
        );
        if (args['archive_sources'] == true) {
          for (final s in sources) {
            await store.removeNote(s.id);
          }
        }
        return '已生成文章 #$newId'
            '${sources.isEmpty ? '' : '（来源 ${sources.length} 篇，默认保留）'}。';
      case 'publish_note':
        final note = await _resolveNote(args);
        if (note == null) return '找不到文章。';
        if (note.kind != kNoteKindArticle) {
          await store.saveNote(id: note.id, kind: kNoteKindArticle);
        }
        await store.setNoteListing(
          noteId: note.id,
          listed: true,
          city: args['city']?.toString(),
        );
        return '已上架文章 #${note.id}。';
      case 'unpublish_note':
        final note = await _resolveNote(args);
        if (note == null) return '找不到文章。';
        await store.setNoteListing(noteId: note.id, listed: false);
        return '已下架文章 #${note.id}。';
      default:
        return '未知操作：${action.tool}';
    }
  }
}
