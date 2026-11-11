import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../state/app_store.dart';
import 'busy.dart';
import 'format.dart';
import 'note_editor_page.dart';

/// 笔记列表：按更新时间倒序；点进编辑，可删除。
class NotesListPage extends StatefulWidget {
  const NotesListPage({super.key, this.showFab = false});

  /// 是否显示「写一条」；醍醐入口默认不显示（用「作为 → 新笔记」）。
  final bool showFab;

  @override
  State<NotesListPage> createState() => _NotesListPageState();
}

class _NotesListPageState extends State<NotesListPage> {
  String? _kindFilter;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final list = (_kindFilter == null
            ? [...store.notes]
            : store.notes.where((n) => n.kind == _kindFilter).toList())
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return Scaffold(
      appBar: AppBar(title: const Text('笔记')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                for (var i = 0; i < 5; i++) ...[
                  if (i > 0) const SizedBox(width: 14),
                  Builder(
                    builder: (_) {
                      const kinds = <String?>[
                        null,
                        kNoteKindNote,
                        kNoteKindMemo,
                        kNoteKindSchedule,
                        kNoteKindArticle,
                      ];
                      const labels = ['全部', '随笔', '备忘', '日程', '文章'];
                      final kind = kinds[i];
                      final selected = _kindFilter == kind;
                      return GestureDetector(
                        onTap: () => setState(() => _kindFilter = kind),
                        child: Text(
                          labels[i],
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
                            color: selected
                                ? const Color(0xFF111111)
                                : const Color(0xFF888888),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _kindFilter == null
                            ? '还没有笔记。到「作为 → 新笔记」写一篇。'
                            : '这一类还没有笔记。',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.only(bottom: widget.showFab ? 88 : 24),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final n = list[i];
                      final when = n.scheduleAt ?? n.remindAt;
                      return ListTile(
                        title: Text(n.displayTitle),
                        subtitle: Text(
                          [
                            n.kindLabel,
                            if (n.isListed) '已上架',
                            formatFriendlyWhen(n.updatedAt.toLocal()),
                            if (when != null) ymdHm(when.toLocal()),
                          ].join(' · '),
                        ),
                        trailing: IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _confirmDelete(context, store, n),
                        ),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => NoteEditorPage(noteId: n.id),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: widget.showFab
          ? FloatingActionButton.extended(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const NoteEditorPage()),
                );
              },
              icon: const Icon(Icons.edit_note),
              label: const Text('写一条'),
            )
          : null,
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AppStore store,
    Note note,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条笔记？'),
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
  }
}
