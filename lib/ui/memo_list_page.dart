import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/memo_sort.dart';
import '../domain/models.dart';
import '../domain/note_title.dart';
import '../state/app_store.dart';
import 'admonition_side_panel.dart';
import 'auth_page.dart';
import 'busy.dart';
import 'l2_side_drawer.dart';
import 'memo_detail_page.dart';
import 'note_editor_page.dart';
import 'format.dart';

/// 备忘单列卡片：标题+摘要；右上角 ⋮；左下时间；右下置顶+办结。
class MemoListPage extends StatefulWidget {
  const MemoListPage({super.key, this.drawerKey});

  final GlobalKey<L2SideDrawerState>? drawerKey;

  @override
  State<MemoListPage> createState() => _MemoListPageState();
}

class _MemoListPageState extends State<MemoListPage> {
  static const _pageSize = 40;
  final _scroll = ScrollController();
  int _visible = _pageSize;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  List<Note> _sortedMemos(AppStore store) {
    if (store.isGuest) return const [];
    return sortMemosForList(store.notes);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 120) {
      return;
    }
    final total = _sortedMemos(context.read<AppStore>()).length;
    if (_visible >= total) return;
    setState(() => _visible = (_visible + _pageSize).clamp(0, total));
  }

  Future<void> _openAuth(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AuthPage()),
    );
  }

  Future<void> _openNew(BuildContext context, AppStore store) async {
    if (store.isGuest) {
      await _openAuth(context);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const NoteEditorPage(initialKind: kNoteKindMemo),
      ),
    );
  }

  Future<void> _onRefresh(AppStore store) async {
    if (store.isGuest || _refreshing) return;
    setState(() => _refreshing = true);
    try {
      await store.refreshMyCache();
      if (mounted) setState(() => _visible = _pageSize);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

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
    if (ok != true) return;
    if (!context.mounted) return;
    await runBusy(
      context,
      message: '正在删除…',
      task: () => store.removeNote(note.id),
    );
  }

  Future<void> _togglePin(AppStore store, Note note) async {
    await runBusy(
      context,
      message: note.isPinned ? '取消置顶…' : '置顶中…',
      task: () => store.setMemoPinned(note.id, pinned: !note.isPinned),
    );
  }

  Future<void> _toggleDone(AppStore store, Note note) async {
    await runBusy(
      context,
      message: note.isCompleted ? '取消办结…' : '办结中…',
      task: () => store.setMemoCompleted(note.id, completed: !note.isCompleted),
    );
  }

  String _excerpt(Note n) {
    final plain = plainTextFromNoteBody(n.body).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (plain.isEmpty) return '';
    return plain.length > 180 ? '${plain.substring(0, 180)}…' : plain;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final guest = store.isGuest;
    final all = _sortedMemos(store);
    final showCount = _visible < _pageSize ? _pageSize : _visible;
    final list = all.take(showCount).toList();

    return L2SideDrawer(
      key: widget.drawerKey,
      enableEdgeSwipe: true,
      drawer: const AdmonitionSidePanel(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: FloatingActionButton(
          onPressed: () => _openNew(context, store),
          child: const Icon(Icons.add),
        ),
        body: RefreshIndicator(
          onRefresh: () => _onRefresh(store),
          child: guest
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(24),
                  children: [
                    const SizedBox(height: 48),
                    const Text('登录后开始写备忘', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    Center(
                      child: FilledButton(
                        onPressed: () => _openAuth(context),
                        child: const Text('去登录'),
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                  itemCount: 1 + list.length + (list.length < all.length ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == 0) return _addCard(context, store);
                    final mi = i - 1;
                    if (mi >= list.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(
                          child: Text(
                            '加载更多…',
                            style: TextStyle(color: Color(0xFF888888)),
                          ),
                        ),
                      );
                    }
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _memoCard(context, store, list[mi]),
                    );
                  },
                ),
        ),
      ),
    );
  }

  Widget _addCard(BuildContext context, AppStore store) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: const Color(0xFFF7F7F8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFFCCCCCC)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openNew(context, store),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 28, horizontal: 16),
            child: Column(
              children: [
                Text(
                  '＋ 添加备忘',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '写一条新的备忘',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6B6B6B)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _memoCard(BuildContext context, AppStore store, Note n) {
    final done = n.isCompleted;
    final title = n.displayTitle;
    final summary = _excerpt(n);
    final muted = done ? const Color(0xFF9A9A9A) : const Color(0xFF6B6B6B);
    final titleColor = done ? const Color(0xFF9A9A9A) : const Color(0xFF1A1A1A);
    final bg = done ? const Color(0xFFF3F3F3) : Colors.white;

    return Material(
      color: bg,
      elevation: done ? 0 : 1,
      shadowColor: Colors.black12,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => MemoDetailPage(noteId: n.id)),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4, right: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              height: 1.4,
                              color: titleColor,
                              decoration: done
                                  ? TextDecoration.lineThrough
                                  : TextDecoration.none,
                            ),
                          ),
                          if (summary.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              summary,
                              maxLines: 5,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: muted,
                                decoration: done
                                    ? TextDecoration.lineThrough
                                    : TextDecoration.none,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.more_vert, size: 20, color: muted),
                    onSelected: (v) async {
                      if (v == 'edit') {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => NoteEditorPage(noteId: n.id),
                          ),
                        );
                      } else if (v == 'delete') {
                        await _confirmDelete(context, store, n);
                      }
                    },
                    itemBuilder: (ctx) => [
                      if (!done)
                        const PopupMenuItem(
                          value: 'edit',
                          child: Text('编辑'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('删除'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      formatFriendlyWhen(n.updatedAt),
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ),
                  IconButton(
                    tooltip: n.isPinned ? '取消置顶' : '置顶',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      n.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                      size: 20,
                      color: done
                          ? muted
                          : (n.isPinned
                              ? const Color(0xFF1A1A1A)
                              : const Color(0xFF888888)),
                    ),
                    onPressed: () => _togglePin(store, n),
                  ),
                  Checkbox(
                    value: done,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    onChanged: (_) => _toggleDone(store, n),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
