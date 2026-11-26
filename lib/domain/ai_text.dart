import 'dart:convert';

/// 把「文章/备忘」等中文或别名归一成 kind 码。
String? normalizeNoteKind(String raw, {bool allowAdmonition = false}) {
  final original = raw.trim();
  if (original.isEmpty) return null;
  final k = original.toLowerCase();
  const map = {
    'note': 'note',
    '笔记': 'note',
    '随笔': 'note',
    'memo': 'memo',
    '备忘': 'memo',
    'schedule': 'schedule',
    '日常': 'schedule',
    '日程': 'schedule',
    'article': 'article',
    '文章': 'article',
    'admonition': 'admonition',
    '谏言': 'admonition',
  };
  final hit = map[k] ?? map[original];
  if (hit == 'admonition' && !allowAdmonition) return null;
  return hit;
}

/// 从用户话里推断目标形态。
String? inferKindFromUserText(String text) {
  final t = text;
  if (RegExp(r'改成文章|换成文章|类型改成文章|改成\s*article', caseSensitive: false)
      .hasMatch(t)) {
    return 'article';
  }
  if (RegExp(r'改成备忘|换成备忘|类型改成备忘|改成\s*memo', caseSensitive: false)
      .hasMatch(t)) {
    return 'memo';
  }
  if (RegExp(
    r'改成日常|换成日常|改成日程|类型改成日常|改成\s*schedule',
    caseSensitive: false,
  ).hasMatch(t)) {
    return 'schedule';
  }
  if (RegExp(r'改成笔记|换成笔记|类型改成笔记|改成\s*note', caseSensitive: false)
      .hasMatch(t)) {
    return 'note';
  }
  if (RegExp(r'改成谏言|换成谏言|类型改成谏言').hasMatch(t)) {
    return 'admonition';
  }

  if (t.contains('备忘') &&
      (RegExp(r'写|记|加|新建|创建').hasMatch(t) || looksLikeWriteRequest(t))) {
    return 'memo';
  }
  if (t.contains('文章') && looksLikeWriteRequest(t)) return 'article';
  if (RegExp(r'日常|日程').hasMatch(t) &&
      (RegExp(r'写|安排|新建|创建').hasMatch(t) || looksLikeWriteRequest(t))) {
    return 'schedule';
  }
  if (t.contains('笔记') &&
      looksLikeWriteRequest(t) &&
      !RegExp(r'文章|备忘|日常|日程').hasMatch(t)) {
    return 'note';
  }
  return null;
}

/// 用户是否在要求写/改正文（用于强制 replace_draft 重试）。
bool looksLikeWriteRequest(String text) {
  if (RegExp(
    r'写一篇|写一篇文章|生成一篇|帮我写|扩写|润色|改写|重写|纠正正文|写入正文|写正文|起草|写文|生成正文|写个|写份|写一下|写段|补全文|填充正文',
  ).hasMatch(text)) {
    return true;
  }
  return RegExp(
    r'正文.?(没有|没写|为空|空的|呢)|没有.?(正文|内容)|没写内容|正文呢|怎么没有正文|内容呢',
  ).hasMatch(text);
}

/// 在文末追加 / 加一句 —— 禁止整篇替换。
bool looksLikeAppendRequest(String text) {
  // 「在某句后面写…」是局部 edit_span，不算文末追加
  if (countLikelySpanEditOps(text) >= 1) return false;
  return RegExp(
    r'最后加|末尾加|文末加|文章最后|在最后|加上一句|加一句|追加|添一句|补一句|再加一句|加到最后|接在后面',
  ).hasMatch(text);
}

/// 局部增删改（某句后插入 / 删某句 / 改某段）—— 应用 edit_span。
bool looksLikeSpanEditRequest(String text) {
  if (countLikelySpanEditOps(text) >= 1) return true;
  return RegExp(
    r'后面加|前面加|后面写|前面写|中间加|句后|句前|段后|段前|删掉|删除.*(句|段|这句|那句)|去掉.*(句|段)|把.+改成|改写|替换.*(句|段)|某句|那句|这句|那段|这段',
  ).hasMatch(text);
}

/// 估算用户一句话里要求几处局部编辑（连续「前面写/后面写/删掉/把…改成」）。
int countLikelySpanEditOps(String text) {
  final t = text;
  if (t.trim().isEmpty) return 0;
  return RegExp(
    r'在[^，。；;\n]{0,48}?(?:前(?:面|边)|后(?:面|边))(?:写|加|插入|补)|'
    r'(?:前(?:面|边)|后(?:面|边))(?:写|加|插入)|'
    r'删掉|删除(?:这|那)?(?:句|段|行)?|去掉(?:这|那)?(?:句|段)|'
    r'把[^，。；;\n]{1,40}?改成',
  ).allMatches(t).length;
}

bool tipIsSpanEdit(String tip) {
  return RegExp(r'已删除指定片段|已改写指定片段|已在指定句').hasMatch(tip);
}

/// 合并连续、同锚点的 insert_before / insert_after（与 Web coalesceEditSpanCalls 对齐）。
List<({String name, Map<String, dynamic> args})> coalesceEditSpanCalls(
  List<({String name, Map<String, dynamic> args})> calls,
) {
  if (calls.length < 2) return calls;
  final out = <({String name, Map<String, dynamic> args})>[];
  for (final c in calls) {
    if (c.name != 'edit_span') {
      out.add(c);
      continue;
    }
    final args = Map<String, dynamic>.from(c.args);
    final action =
        '${args['action'] ?? args['op'] ?? ''}'.trim().toLowerCase();
    final find =
        '${args['find'] ?? args['target'] ?? args['span'] ?? ''}'.trim();
    final text = '${args['text'] ?? args['with'] ?? args['plain'] ?? ''}';
    if (out.isNotEmpty) {
      final prev = out.last;
      final prevAction =
          '${prev.args['action'] ?? ''}'.trim().toLowerCase();
      final prevFind = '${prev.args['find'] ?? ''}'.trim();
      if (prev.name == 'edit_span' &&
          find.isNotEmpty &&
          find == prevFind &&
          action == prevAction &&
          (action == 'insert_after' || action == 'insert_before')) {
        final prevText = '${prev.args['text'] ?? ''}';
        final merged = Map<String, dynamic>.from(prev.args);
        merged['text'] =
            action == 'insert_after' ? prevText + text : text + prevText;
        out[out.length - 1] = (name: 'edit_span', args: merged);
        continue;
      }
    }
    args['action'] = action;
    args['find'] = find;
    args['text'] = text;
    out.add((name: 'edit_span', args: args));
  }
  return out;
}

/// 模型把工具名当纯文本输出时的抢救结果。
class PseudoToolExtract {
  const PseudoToolExtract({
    required this.calls,
    required this.cleaned,
  });
  final List<({String name, Map<String, dynamic> args})> calls;
  final String cleaned;
}

/// 解析如 `replace_draft\n# 标题\n正文` 的伪工具调用。
PseudoToolExtract extractPseudoToolCalls(String content) {
  final text = content.trim();
  if (text.isEmpty) {
    return const PseudoToolExtract(calls: [], cleaned: '');
  }

  final head = RegExp(
    r'^(replace_draft|append_draft|set_title)\s*(?:\r?\n+|[:：]\s*)([\s\S]*)$',
    caseSensitive: false,
  ).firstMatch(text);
  if (head == null) {
    return PseudoToolExtract(calls: const [], cleaned: text);
  }

  final name = head.group(1)!.toLowerCase();
  var rest = (head.group(2) ?? '').trim();

  if (rest.startsWith('{')) {
    try {
      final obj = jsonDecode(rest);
      if (obj is Map) {
        if (name == 'set_title') {
          final title = '${obj['title'] ?? ''}'.trim();
          return PseudoToolExtract(
            calls: title.isEmpty
                ? const []
                : [(name: 'set_title', args: {'title': title})],
            cleaned: '',
          );
        }
        final plain = pickDraftPlain(Map<String, dynamic>.from(obj));
        if (plain.isNotEmpty) {
          return PseudoToolExtract(
            calls: [(name: name, args: {'plain': plain})],
            cleaned: '',
          );
        }
      }
    } catch (_) {}
  }

  if (name == 'set_title') {
    final title =
        rest.split(RegExp(r'\r?\n')).first.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    return PseudoToolExtract(
      calls: title.isEmpty
          ? const []
          : [(name: 'set_title', args: {'title': title})],
      cleaned: '',
    );
  }

  final calls = <({String name, Map<String, dynamic> args})>[];
  final titleLine = RegExp(r'^#\s+([^\n]+)\r?\n([\s\S]*)$').firstMatch(rest);
  if (titleLine != null) {
    final title = titleLine.group(1)!.trim();
    rest = (titleLine.group(2) ?? '').trim();
    if (title.isNotEmpty) {
      calls.add((name: 'set_title', args: {'title': title}));
    }
  }
  final plain = sanitizeAiPlainText(rest);
  if (plain.isNotEmpty) {
    calls.add((name: name, args: {'plain': plain}));
  }
  return PseudoToolExtract(
    calls: calls,
    cleaned: calls.isEmpty ? text : '',
  );
}

/// 从 tool arguments 取正文（兼容 plain/text/body/content 及破损 JSON）。
String pickDraftPlain(Map<String, dynamic> args, {String rawArgs = ''}) {
  for (final k in ['plain', 'text', 'body', 'content', 'draft', 'article']) {
    final v = args[k];
    if (v is String && v.trim().isNotEmpty) {
      return sanitizeAiPlainText(v);
    }
  }
  if (rawArgs.trim().isEmpty) return '';
  for (final k in ['plain', 'text', 'body', 'content']) {
    final extracted = _extractJsonStringField(rawArgs, k);
    if (extracted.trim().isNotEmpty) {
      return sanitizeAiPlainText(extracted);
    }
  }
  return '';
}

String _extractJsonStringField(String raw, String key) {
  final token = '"$key"';
  final idx = raw.indexOf(token);
  if (idx < 0) return '';
  final colon = raw.indexOf(':', idx + token.length);
  if (colon < 0) return '';
  var i = colon + 1;
  while (i < raw.length && RegExp(r'\s').hasMatch(raw[i])) {
    i++;
  }
  if (i >= raw.length || raw[i] != '"') return '';
  i++;
  final out = StringBuffer();
  while (i < raw.length) {
    final ch = raw[i];
    if (ch == r'\') {
      if (i + 1 >= raw.length) break;
      final n = raw[i + 1];
      if (n == 'n') {
        out.write('\n');
      } else if (n == 'r') {
        out.write('\r');
      } else if (n == 't') {
        out.write('\t');
      } else {
        out.write(n);
      }
      i += 2;
      continue;
    }
    if (ch == '"') break;
    out.write(ch);
    i++;
  }
  return out.toString();
}

Map<String, dynamic> parseToolArgsMap(dynamic argsRaw) {
  if (argsRaw is Map) {
    return Map<String, dynamic>.from(argsRaw);
  }
  if (argsRaw is! String || argsRaw.trim().isEmpty) {
    return {};
  }
  final s = argsRaw.trim();
  try {
    final decoded = jsonDecode(s);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {}
  try {
    final repaired = s.replaceAllMapped(
      RegExp(r'("(?:\\.|[^"\\])*")|[\r\n]+'),
      (m) => m.group(1) ?? r'\n',
    );
    final decoded = jsonDecode(repaired);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {}
  // 破损 JSON：仍尽量抽出 plain
  final plain = pickDraftPlain(const {}, rawArgs: s);
  if (plain.isNotEmpty) return {'plain': plain};
  return {};
}

/// 去掉模型爱包的 Markdown 代码块 / 外层引号，得到可写入笔记的纯文本。
String sanitizeAiPlainText(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  final fence = RegExp(
    r'^```(?:json|markdown|md|text|quill)?\s*\r?\n([\s\S]*?)\r?\n```\s*$',
    caseSensitive: false,
  );
  final m = fence.firstMatch(s);
  if (m != null) {
    s = (m.group(1) ?? '').trim();
  }
  if ((s.startsWith('"') && s.endsWith('"')) ||
      (s.startsWith("'") && s.endsWith("'"))) {
    s = s.substring(1, s.length - 1).trim();
  }
  // 误把 Quill Delta JSON 当纯文本
  if (s.startsWith('[')) {
    try {
      final decoded = jsonDecode(s);
      if (decoded is List) {
        final buf = StringBuffer();
        for (final op in decoded) {
          if (op is Map && op['insert'] is String) {
            buf.write(op['insert']);
          }
        }
        final plain = buf.toString().trimRight();
        if (plain.isNotEmpty) return plain;
      }
    } catch (_) {}
  }
  s = s.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
  s = s.replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1');
  s = s.replaceAll(RegExp(r'__(.+?)__'), r'$1');
  s = s.replaceAll(RegExp(r'`([^`]+)`'), r'$1');
  return s.trim();
}
