import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../state/app_store.dart';
import 'auth_page.dart';
import 'busy.dart';
import 'format.dart';
import 'note_editor_page.dart';

/// 底部「笔记」页：仅 kind=note；下拉刷新 + 滚动分页。
class NotesHomePage extends StatefulWidget {
  const NotesHomePage({super.key});

  @override
  State<NotesHomePage> createState() => _NotesHomePageState();
}

class _NotesHomePageState extends State<NotesHomePage> {
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

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 120) {
      return;
    }
    final store = context.read<AppStore>();
    final total = store.isGuest
        ? 0
        : store.notes.where((n) => n.kind == kNoteKindNote).length;
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
      MaterialPageRoute(builder: (_) => const NoteEditorPage()),
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

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final guest = store.isGuest;
    final all = guest
        ? const <Note>[]
        : (store.notes.where((n) => n.kind == kNoteKindNote).toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
    // 勿在空列表时把 _visible 收成 0，否则启动/登录后数据到了仍不显示
    final showCount = _visible < _pageSize ? _pageSize : _visible;
    final list = all.take(showCount).toList();
    final hasMore = list.length < all.length;

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openNew(context, store),
        tooltip: '新笔记',
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
                  const Text(
                    '登录后开始写笔记',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: FilledButton(
                      onPressed: () => _openAuth(context),
                      child: const Text('去登录'),
                    ),
                  ),
                ],
              )
            : all.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(24),
                    children: const [
                      SizedBox(height: 48),
                      Text(
                        '还没有笔记。点右下角 ＋ 写一篇。\n下拉可刷新。',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  )
                : ListView.separated(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: list.length + (hasMore ? 1 : 0),
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      if (i >= list.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: Text(
                              '上拉加载更多…',
                              style: TextStyle(color: Color(0xFF888888)),
                            ),
                          ),
                        );
                      }
                      final n = list[i];
                      return ListTile(
                        title: Text(n.displayTitle),
                        subtitle: Text(
                          formatFriendlyWhen(n.updatedAt.toLocal()),
                        ),
                        trailing: IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () =>
                              _confirmDelete(context, store, n),
                        ),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  NoteEditorPage(noteId: n.id),
                            ),
                          );
                        },
                      );
                    },
                  ),
      ),
    );
  }
}
