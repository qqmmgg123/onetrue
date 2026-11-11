import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../state/app_store.dart';
import 'busy.dart';
import 'format.dart';
import 'note_editor_page.dart';

/// 待办事项：未到点 / 已过点 / 无提醒时间。
class NoteRemindersPage extends StatelessWidget {
  const NoteRemindersPage({super.key});

  DateTime? _remindAt(Note n) {
    if (n.kind == kNoteKindSchedule && n.scheduleAt != null) {
      final start =
          n.scheduleAt!.isUtc ? n.scheduleAt!.toLocal() : n.scheduleAt!;
      final off = n.remindOffsetMin < 0 ? 0 : n.remindOffsetMin;
      return start.subtract(Duration(minutes: off));
    }
    if (n.remindAt != null) {
      return n.remindAt!.isUtc ? n.remindAt!.toLocal() : n.remindAt!;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final memos = store.notes
        .where(
          (n) => n.kind == kNoteKindMemo || n.kind == kNoteKindSchedule,
        )
        .toList();
    final now = DateTime.now();

    final upcoming = <Note>[];
    final past = <Note>[];
    final noRemind = <Note>[];

    for (final n in memos) {
      final t = _remindAt(n);
      if (t == null) {
        noRemind.add(n);
      } else if (t.isAfter(now)) {
        upcoming.add(n);
      } else {
        past.add(n);
      }
    }

    upcoming.sort((a, b) => _remindAt(a)!.compareTo(_remindAt(b)!));
    past.sort((a, b) => _remindAt(b)!.compareTo(_remindAt(a)!));
    noRemind.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return Scaffold(
      appBar: AppBar(title: const Text('待办事项')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (memos.isEmpty)
            const Text('还没有待办。可在「作为 → 新笔记」添加备忘或日程，或让对话帮你记。'),
          if (upcoming.isNotEmpty) ...[
            Text('未到点', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...upcoming.map(
              (n) => _NoteRemTile(note: n, when: _remindAt(n)),
            ),
            const SizedBox(height: 16),
          ],
          if (past.isNotEmpty) ...[
            Text('已过点', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...past.map((n) => _NoteRemTile(note: n, when: _remindAt(n))),
            const SizedBox(height: 16),
          ],
          if (noRemind.isNotEmpty) ...[
            Text('无提醒时间', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...noRemind.map((n) => _NoteRemTile(note: n, when: null)),
          ],
        ],
      ),
    );
  }
}

class _NoteRemTile extends StatelessWidget {
  const _NoteRemTile({required this.note, required this.when});
  final Note note;
  final DateTime? when;

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除待办'),
        content: Text('确认删除「${note.displayTitle}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final store = context.read<AppStore>();
    await runBusy(
      context,
      message: '正在删除…',
      task: () => store.removeNote(note.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        note.kind == kNoteKindSchedule
            ? Icons.event_outlined
            : Icons.notifications_none,
      ),
      title: Text(note.displayTitle),
      subtitle: Text(
        [
          note.kindLabel,
          if (when != null) ymdHm(when!),
          if (when == null) '持久提醒',
        ].join(' · '),
      ),
      trailing: IconButton(
        tooltip: '删除',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _confirmDelete(context),
      ),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => NoteEditorPage(noteId: note.id),
          ),
        );
      },
    );
  }
}
