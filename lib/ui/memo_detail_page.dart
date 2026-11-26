import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../state/app_store.dart';
import 'busy.dart';
import 'format.dart';
import 'memo_quill_preview.dart';
import 'note_editor_page.dart';
import 'note_quill.dart';

/// 备忘详情：富文本正文 + 添加时间；可编辑 / 删除。
class MemoDetailPage extends StatelessWidget {
  const MemoDetailPage({super.key, required this.noteId});

  final int noteId;

  Future<void> _confirmDelete(
    BuildContext context,
    AppStore store,
    Note note,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条备忘？'),
        content: Text('确认删除「${note.displayTitle}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await runBusy(
      context,
      message: '正在删除…',
      task: () => store.removeNote(note.id),
    );
    if (!context.mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    Note? note;
    for (final n in store.notes) {
      if (n.id == noteId) {
        note = n;
        break;
      }
    }

    if (note == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('备忘')),
        body: const Center(child: Text('这条备忘已不存在。')),
      );
    }

    final n = note;
    final title = n.hasTitle ? n.title.trim() : n.displayTitle;

    return Scaffold(
      appBar: AppBar(
        title: const Text('备忘'),
        actions: [
          if (!n.isCompleted)
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => NoteEditorPage(noteId: n.id),
                  ),
                );
              },
            ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context, store, n),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            '添加时间 ${ymdHm(n.updatedAt.toLocal())}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          MemoQuillPreview(
            body: n.body,
            format: n.format.isEmpty ? kStoredQuill : n.format,
            scrollable: false,
            enableSelection: true,
          ),
        ],
      ),
    );
  }
}
