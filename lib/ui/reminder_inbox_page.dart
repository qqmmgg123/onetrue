import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../domain/note_title.dart';
import '../state/app_store.dart';
import 'format.dart';
import 'note_reminders_page.dart';
import 'notes_list_page.dart';
import 'recent_reads_page.dart';
import 'rent_dues_page.dart';

/// 底栏「醍醐」：近期笔记 / 近期阅读 / 待办事项。
class ReminderInboxPage extends StatelessWidget {
  const ReminderInboxPage({super.key});

  Note? _latestNote(List<Note> notes) {
    if (notes.isEmpty) return null;
    final sorted = [...notes]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sorted.first;
  }

  DateTime? _effectiveRemindAt(Note n) {
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

  Note? _todoPreview(List<Note> notes) {
    final todos = notes
        .where((n) => n.kind == kNoteKindMemo || n.kind == kNoteKindSchedule)
        .toList();
    if (todos.isEmpty) return null;
    final withRemind = <({Note note, DateTime at})>[];
    for (final n in todos) {
      final at = _effectiveRemindAt(n);
      if (at != null) withRemind.add((note: n, at: at));
    }
    if (withRemind.isNotEmpty) {
      withRemind.sort((a, b) => a.at.compareTo(b.at));
      return withRemind.first.note;
    }
    todos.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return todos.first;
  }

  String _noteSummary(Note n) {
    final title = n.displayTitle;
    final plain = plainTextFromNoteBody(n.body);
    if (plain.isEmpty) return title;
    final one = plain.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (one == title) return title;
    final rest = one.length > 48 ? '${one.substring(0, 48)}…' : one;
    return '$title · $rest';
  }

  String _readSummary(ArticleReadRecord r) {
    final title = r.displayTitle;
    final plain = plainTextFromNoteBody(r.body);
    if (plain.isEmpty) return title;
    final one = plain.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (one == title) return title;
    final rest = one.length > 48 ? '${one.substring(0, 48)}…' : one;
    return '$title · $rest';
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    if (store.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final latest = _latestNote(store.notes);
    final latestRead = store.latestArticleRead;
    final todo = _todoPreview(store.notes);
    final todoRemind = todo == null ? null : _effectiveRemindAt(todo);

    return RefreshIndicator(
      onRefresh: () async {
        if (store.isLandlord) {
          await store.refreshMyCache();
        } else {
          await store.reload();
        }
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _HubRow(
            title: '近期笔记',
            summary: latest == null ? '还没有笔记，去「作为」写一篇吧。' : _noteSummary(latest),
            timeLabel: '编辑时间',
            timeText: latest == null
                ? '—'
                : formatFriendlyWhen(latest.updatedAt.toLocal()),
            actionText: '查看全部',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const NotesListPage(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          _HubRow(
            title: '近期阅读',
            summary: latestRead == null
                ? '还没有阅读记录，去市集看看文章吧。'
                : _readSummary(latestRead),
            timeLabel: '阅读时间',
            timeText: latestRead == null
                ? '—'
                : formatFriendlyWhen(latestRead.lastReadAt.toLocal()),
            actionText: '查看全部',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const RecentReadsPage(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          _HubRow(
            title: '未收房源',
            summary: store.pending.isEmpty
                ? '暂无未收账期。'
                : '${store.pending.length} 笔待收 · 最近 ${ymdCn(store.pending.first.period.dueDate)} ${store.pending.first.roomLabel}',
            timeLabel: '最近到期',
            timeText: store.pending.isEmpty
                ? '—'
                : formatFriendlyWhen(store.pending.first.period.dueDate),
            actionText: '查看全部',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const RentDuesPage(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          _HubRow(
            title: '待办事项',
            summary: todo == null
                ? '暂无备忘或日程。'
                : todo.displayTitle,
            timeLabel: '提醒时间',
            timeText: todo == null
                ? '—'
                : (todoRemind == null
                    ? '持久提醒'
                    : formatFriendlyWhen(todoRemind)),
            actionText: '查看全部',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const NoteRemindersPage(),
                ),
              );
            },
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

class _HubRow extends StatelessWidget {
  const _HubRow({
    required this.title,
    required this.summary,
    required this.timeLabel,
    required this.timeText,
    required this.actionText,
    required this.onTap,
  });

  final String title;
  final String summary;
  final String timeLabel;
  final String timeText;
  final String actionText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF444444),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  timeLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: const Color(0xFF888888),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  timeText,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      actionText,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: const Color(0xFF111111),
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
