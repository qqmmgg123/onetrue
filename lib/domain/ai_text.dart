import 'dart:convert';

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
