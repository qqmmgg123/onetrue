import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' hide Text;

/// 把库里存的 body 解析成 Quill Document（兼容旧纯文本）。
Document documentFromBody(String body, {String format = kStoredQuill}) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return Document();
  if (format == kStoredQuill || trimmed.startsWith('[')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List) return Document.fromJson(decoded);
    } catch (_) {}
  }
  return Document.fromJson([
    {'insert': body.endsWith('\n') ? body : '$body\n'},
  ]);
}

String bodyToStorage(QuillController controller) {
  return jsonEncode(controller.document.toDelta().toJson());
}

String bodyPlain(QuillController controller) {
  return controller.document.toPlainText().trimRight();
}

/// 展示用：把存库 body（Quill JSON 或纯文本）转成可读纯文本。
String plainTextFromStoredBody(String body, {String format = kStoredQuill}) {
  return documentFromBody(body, format: format).toPlainText().trimRight();
}

const kStoredQuill = 'quill';

void replaceDocument(QuillController controller, Document doc) {
  controller.document = doc;
  controller.updateSelection(
    const TextSelection.collapsed(offset: 0),
    ChangeSource.LOCAL,
  );
}

void replaceWithPlain(QuillController controller, String plain) {
  final text = plain.endsWith('\n') ? plain : '$plain\n';
  replaceDocument(
    controller,
    Document.fromJson([
      {'insert': text},
    ]),
  );
}

/// 在现有正文末尾追加纯文本（不覆盖原文）。
void appendWithPlain(QuillController controller, String plain) {
  final add = plain.replaceAll(RegExp(r'\n+$'), '').trim();
  if (add.isEmpty) return;
  final cur = bodyPlain(controller).trimRight();
  final next = cur.isEmpty ? add : '$cur\n$add';
  replaceWithPlain(controller, next);
}

void replaceWithDeltaJson(QuillController controller, List<dynamic> delta) {
  replaceDocument(controller, Document.fromJson(delta));
}

/// 对当前选区（无选区则整篇）套用块/行内格式。
void applyDraftFormat(QuillController controller, Map<String, dynamic> ops) {
  final sel = controller.selection;
  final hasSel = sel.isValid && !sel.isCollapsed;
  if (!hasSel) {
    final len = controller.document.length;
    if (len > 1) {
      controller.updateSelection(
        TextSelection(baseOffset: 0, extentOffset: len - 1),
        ChangeSource.LOCAL,
      );
    }
  }

  if (ops['bold'] == true) {
    controller.formatSelection(Attribute.bold);
  }
  final header = ops['header'];
  if (header is int) {
    controller.formatSelection(HeaderAttribute(level: header));
  } else if (header == null && ops.containsKey('header')) {
    controller.formatSelection(Attribute.clone(Attribute.header, null));
  }
  final list = ops['list']?.toString();
  if (list == 'ordered') {
    controller.formatSelection(Attribute.ol);
  } else if (list == 'bullet') {
    controller.formatSelection(Attribute.ul);
  } else if (list == 'none') {
    controller.formatSelection(Attribute.clone(Attribute.list, null));
  }
  final align = ops['align']?.toString();
  if (align == 'left') {
    controller.formatSelection(Attribute.leftAlignment);
  } else if (align == 'center') {
    controller.formatSelection(Attribute.centerAlignment);
  } else if (align == 'right') {
    controller.formatSelection(Attribute.rightAlignment);
  } else if (align == 'justify') {
    controller.formatSelection(Attribute.justifyAlignment);
  }
  final size = ops['size']?.toString();
  if (size != null && size.isNotEmpty) {
    controller.formatSelection(SizeAttribute(size));
  }
}
