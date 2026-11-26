import 'dart:convert';

import 'models.dart';

/// 从笔记正文抽出可读纯文本（兼容 Quill Delta JSON 与纯文本）。
String plainTextFromNoteBody(String body) {
  final raw = body.trim();
  if (raw.isEmpty) return '';
  if (raw.startsWith('[')) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final buf = StringBuffer();
        for (final op in decoded) {
          if (op is Map && op['insert'] is String) {
            buf.write(op['insert'] as String);
          }
        }
        return buf.toString().replaceAll('\u00A0', ' ').trim();
      }
    } catch (_) {}
  }
  return raw;
}

/// 无标题时用正文首行生成列表/会话式默认标题（规则生成，不调大模型）。
/// 与「找 AI」用首条用户话截断做会话标题同一思路。
String suggestNoteTitle({
  required String title,
  required String body,
  String fallback = '未命名',
  int maxLen = 24,
}) {
  final typed = title.trim();
  if (typed.isNotEmpty) return typed;

  final plain = plainTextFromNoteBody(body);
  for (final line in plain.split(RegExp(r'\r?\n'))) {
    var s = line.trim();
    if (s.isEmpty) continue;
    // 去掉常见列表前缀，避免标题变成「1. xxx」
    s = s.replaceFirst(RegExp(r'^([-*•]+|\d+[.\u3001、])\s*'), '').trim();
    if (s.isEmpty) continue;
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}…';
  }
  return fallback;
}

/// 随笔/备忘：标题为空则落库默认标题；日程/文章保持原样（由 UI 强制必填）。
String resolveNoteTitleForSave({
  required String kind,
  required String title,
  required String body,
}) {
  final typed = title.trim();
  if (typed.isNotEmpty) return typed;
  if (kind == kNoteKindNote || kind == kNoteKindMemo) {
    return suggestNoteTitle(
      title: '',
      body: body,
      fallback: kind == kNoteKindMemo ? '备忘' : '笔记',
    );
  }
  return '';
}
