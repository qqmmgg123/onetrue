/// 正文片段增删改（与 Web lib/ai-plain.js applySpanEdit 对齐）。

class SpanEditIntent {
  const SpanEditIntent({
    required this.action,
    required this.find,
    required this.text,
  });
  final String action;
  final String find;
  final String text;
}

class SpanEditResult {
  const SpanEditResult.ok(this.next, this.tip)
      : error = null,
        ok = true;
  const SpanEditResult.fail(this.error)
      : next = null,
        tip = null,
        ok = false;

  final bool ok;
  final String? next;
  final String? tip;
  final String? error;
}

/// 从用户话术解析有序局部编辑意图（与 Web extractSpanEditIntents 对齐）。
List<SpanEditIntent> extractSpanEditIntents(String text) {
  final t = text;
  if (t.trim().isEmpty) return const [];
  final intents = <SpanEditIntent>[];
  // \u201c \u201d = “ ”
  final quoted = RegExp(
    '在\\s*[「『\u201c"\']([^「『」』\u201c\u201d"\']+?)[」』\u201d"\']'
    '\\s*(前|后)(?:面|边)?\\s*(?:写|加|插入|补)\\s*[，,]?\\s*'
    '[「『\u201c"\']([^「『」』\u201c\u201d"\']+?)[」』\u201d"\']',
  );
  for (final m in quoted.allMatches(t)) {
    final find = (m.group(1) ?? '').trim();
    final side = m.group(2) ?? '';
    final insertText = (m.group(3) ?? '').trim();
    if (find.isEmpty || insertText.isEmpty) continue;
    intents.add(SpanEditIntent(
      action: side == '前' ? 'insert_before' : 'insert_after',
      find: find,
      text: insertText,
    ));
  }
  if (intents.isNotEmpty) return intents;

  final plain = RegExp(
    r'在\s*([^\s，,。；;前后来]{1,40}?)\s*(前|后)(?:面|边)?\s*(?:写|加|插入|补)\s*[，,]?\s*([^\s，,。；;]{1,80})',
  );
  for (final m in plain.allMatches(t)) {
    final find = (m.group(1) ?? '').trim();
    final side = m.group(2) ?? '';
    final insertText = (m.group(3) ?? '').trim();
    if (find.isEmpty || insertText.isEmpty) continue;
    intents.add(SpanEditIntent(
      action: side == '前' ? 'insert_before' : 'insert_after',
      find: find,
      text: insertText,
    ));
  }
  return intents;
}

List<SpanEditIntent> coalesceSpanIntents(List<SpanEditIntent> intents) {
  if (intents.length < 2) return intents;
  final out = <SpanEditIntent>[];
  for (final intent in intents) {
    if (out.isNotEmpty) {
      final prev = out.last;
      if (intent.find.isNotEmpty &&
          intent.find == prev.find &&
          intent.action == prev.action &&
          (intent.action == 'insert_after' ||
              intent.action == 'insert_before')) {
        final mergedText = intent.action == 'insert_after'
            ? prev.text + intent.text
            : intent.text + prev.text;
        out[out.length - 1] = SpanEditIntent(
          action: prev.action,
          find: prev.find,
          text: mergedText,
        );
        continue;
      }
    }
    out.add(intent);
  }
  return out;
}

({String plain, List<String> tips, List<String> errors, bool ok})
    applySpanEditsSequential(String sourcePlain, List<SpanEditIntent> intents) {
  var plain = sourcePlain;
  final tips = <String>[];
  final errors = <String>[];
  for (final intent in coalesceSpanIntents(intents)) {
    final result = applySpanEdit(plain, {
      'action': intent.action,
      'find': intent.find,
      'text': intent.text,
    });
    if (!result.ok) {
      errors.add(result.error ?? '局部编辑失败');
      continue;
    }
    plain = result.next ?? plain;
    tips.add(result.tip ?? '已局部编辑');
  }
  return (
    plain: plain,
    tips: tips,
    errors: errors,
    ok: errors.isEmpty && tips.isNotEmpty,
  );
}

List<String> missingSpanInsertTexts(
  String plain,
  List<SpanEditIntent> intents,
) {
  final missing = <String>[];
  for (final intent in intents) {
    if (intent.action != 'insert_before' && intent.action != 'insert_after') {
      continue;
    }
    final text = intent.text.trim();
    if (text.isNotEmpty && !plain.contains(text)) missing.add(text);
  }
  return missing;
}

SpanEditResult applySpanEdit(
  String sourcePlain,
  Map<String, dynamic> args,
) {
  final src = sourcePlain;
  final action = '${args['action'] ?? args['op'] ?? ''}'.trim().toLowerCase();
  final findRaw =
      '${args['find'] ?? args['target'] ?? args['span'] ?? ''}'.trim();
  final text = '${args['text'] ?? args['with'] ?? args['plain'] ?? ''}';
  final all = args['all'] == true ||
      args['all'] == 1 ||
      '${args['all']}' == 'true';

  const actions = {
    'replace',
    'delete',
    'insert_after',
    'insert_before',
  };
  if (!actions.contains(action)) {
    return const SpanEditResult.fail(
      'edit_span 需要 action=replace|delete|insert_after|insert_before',
    );
  }
  if (findRaw.isEmpty) {
    return const SpanEditResult.fail('edit_span 需要 find（原文片段）');
  }
  if ((action == 'replace' ||
          action == 'insert_after' ||
          action == 'insert_before') &&
      text.trim().isEmpty) {
    return const SpanEditResult.fail('edit_span 需要 text（新内容）');
  }

  final hit = locateSpan(src, findRaw);
  if (hit == null) {
    final shown =
        findRaw.length > 24 ? '${findRaw.substring(0, 24)}…' : findRaw;
    return SpanEditResult.fail('未在正文中找到「$shown」');
  }

  String next;
  if (all) {
    final pieces = <String>[];
    var from = 0;
    var count = 0;
    while (from <= src.length) {
      final sub = src.substring(from);
      final loc = locateSpan(sub, findRaw);
      if (loc == null) {
        pieces.add(src.substring(from));
        break;
      }
      final absStart = from + loc.$1;
      final absEnd = from + loc.$2;
      pieces.add(src.substring(from, absStart));
      pieces.add(_spanPatch(src.substring(absStart, absEnd), action, text));
      from = absEnd;
      count += 1;
      if (count > 50) break;
    }
    next = pieces.join();
  } else {
    final before = src.substring(0, hit.$1);
    final mid = src.substring(hit.$1, hit.$2);
    final after = src.substring(hit.$2);
    next = before + _spanPatch(mid, action, text) + after;
  }

  final tip = switch (action) {
    'delete' => '已删除指定片段',
    'replace' => '已改写指定片段',
    'insert_after' => '已在指定句后插入',
    _ => '已在指定句前插入',
  };
  return SpanEditResult.ok(next, tip);
}

String _spanPatch(String matched, String action, String text) {
  switch (action) {
    case 'delete':
      return '';
    case 'replace':
      return text;
    case 'insert_after':
      return matched + text;
    case 'insert_before':
      return text + matched;
    default:
      return matched;
  }
}

/// (start, end) 半开区间。
(int, int)? locateSpan(String source, String findRaw) {
  final src = source;
  final find = findRaw;
  if (src.isEmpty || find.isEmpty) return null;

  var idx = src.indexOf(find);
  if (idx >= 0) return (idx, idx + find.length);

  final trimmed = find.trim();
  if (trimmed.isNotEmpty && trimmed != find) {
    idx = src.indexOf(trimmed);
    if (idx >= 0) return (idx, idx + trimmed.length);
  }

  final normSrc = _collapseWs(src);
  final normFind = _collapseWs(trimmed.isEmpty ? find : trimmed);
  if (normFind.isEmpty) return null;
  final nIdx = normSrc.indexOf(normFind);
  if (nIdx < 0) return null;
  return _mapCollapsedRange(src, nIdx, nIdx + normFind.length);
}

String _collapseWs(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

(int, int)? _mapCollapsedRange(String source, int cStart, int cEnd) {
  var ci = 0;
  var start = -1;
  var end = -1;
  var inWs = false;
  var i = 0;
  while (i < source.length && RegExp(r'\s').hasMatch(source[i])) {
    i++;
  }
  for (; i < source.length; i++) {
    final ch = source[i];
    if (RegExp(r'\s').hasMatch(ch)) {
      if (!inWs) {
        if (ci == cStart && start < 0) start = i;
        if (ci >= cStart && ci < cEnd) end = i + 1;
        ci += 1;
        inWs = true;
      }
      continue;
    }
    inWs = false;
    if (ci == cStart && start < 0) start = i;
    if (ci < cEnd) end = i + 1;
    ci += 1;
    if (ci >= cEnd && start >= 0) break;
  }
  if (start < 0 || end < 0 || end <= start) return null;
  return (start, end);
}
