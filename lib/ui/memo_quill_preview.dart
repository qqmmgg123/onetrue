import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' hide Text;

import 'note_quill.dart';

/// 只读 Quill 预览（备忘卡片 / 详情共用）。
class MemoQuillPreview extends StatefulWidget {
  const MemoQuillPreview({
    super.key,
    required this.body,
    this.format = kStoredQuill,
    this.padding = EdgeInsets.zero,
    this.scrollable = false,
    this.showCursor = false,
    this.enableSelection = false,
  });

  final String body;
  final String format;
  final EdgeInsetsGeometry padding;
  final bool scrollable;
  final bool showCursor;
  final bool enableSelection;

  @override
  State<MemoQuillPreview> createState() => _MemoQuillPreviewState();
}

class _MemoQuillPreviewState extends State<MemoQuillPreview> {
  late QuillController _controller;
  late final FocusNode _focus;
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    _focus = FocusNode(canRequestFocus: false);
    _scroll = ScrollController();
    _controller = QuillController(
      document: documentFromBody(widget.body, format: widget.format),
      selection: const TextSelection.collapsed(offset: 0),
    );
  }

  @override
  void didUpdateWidget(covariant MemoQuillPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.body != widget.body || oldWidget.format != widget.format) {
      _controller.dispose();
      _controller = QuillController(
        document: documentFromBody(widget.body, format: widget.format),
        selection: const TextSelection.collapsed(offset: 0),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return QuillEditor(
      controller: _controller,
      focusNode: _focus,
      scrollController: _scroll,
      scrollable: widget.scrollable,
      padding: widget.padding,
      autoFocus: false,
      readOnly: true,
      expands: false,
      showCursor: widget.showCursor,
      enableInteractiveSelection: widget.enableSelection,
    );
  }
}
