import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../social/social_api.dart';
import '../social/social_models.dart';
import '../state/app_store.dart';
import '../sync/sync_service.dart';
import 'busy.dart';
import 'format.dart';
import 'open_article.dart';
import 'widgets/user_avatar.dart';

/// 留言与回复（留言=文章顶层评点；回复=明确回书给我；另含推荐/留意）。
class SocialInboxPage extends StatefulWidget {
  const SocialInboxPage({super.key, this.embedded = false});

  /// 嵌入阅读 Tab 时不画独立 Scaffold / AppBar。
  final bool embedded;

  @override
  State<SocialInboxPage> createState() => _SocialInboxPageState();
}

class _SocialInboxPageState extends State<SocialInboxPage> {
  bool _loading = true;
  String? _error;
  List<SocialNotificationItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await SocialApi.instance.listMyNotifications();
      final filtered = list
          .where((e) =>
              e.kind == 'comment' ||
              e.kind == 'reply' ||
              e.kind == 'recommend' ||
              e.kind == 'follow')
          .toList();
      if (!mounted) return;
      setState(() {
        _items = filtered;
        _loading = false;
      });
      final unread = filtered.where((e) => !e.isRead).map((e) => e.id);
      if (unread.isNotEmpty) {
        await SocialApi.instance.markNotificationsRead(unread);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String _title(SocialNotificationItem n) {
    final who = n.actorNickname.isNotEmpty ? n.actorNickname : '有人';
    switch (n.kind) {
      case 'reply':
        return '$who 回书了你';
      case 'comment':
        return '$who 给你的文章留了言';
      case 'recommend':
        return '$who 推荐了你的文章';
      case 'follow':
        return '$who 留意了你';
      default:
        return who;
    }
  }

  Future<void> _remove(SocialNotificationItem n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除这条提醒？'),
        content: Text('将「${_title(n)}」从留言与回复中移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await runBusy(
      context,
      message: '正在移除…',
      task: () => SocialApi.instance.deleteNotification(n.id),
    );
    if (!mounted) return;
    setState(() {
      _items = _items.where((e) => e.id != n.id).toList();
    });
  }

  Future<void> _open(SocialNotificationItem n) async {
    final noteId = n.noteId?.trim() ?? '';
    if (noteId.isEmpty) return;
    try {
      final rows = await SyncService(db: context.read<AppStore>().db)
          .fetchListedArticles();
      MarketplaceArticle? hit;
      for (final a in rows) {
        if (a.noteUuid == noteId) {
          hit = a;
          break;
        }
      }
      hit ??= MarketplaceArticle(
        noteUuid: noteId,
        title: n.noteTitle,
        body: '',
        format: 'plain',
      );
      if (!mounted) return;
      await openMarketplaceArticle(
        context,
        hit,
        highlightCommentId: n.commentId,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开失败：$e')),
      );
    }
  }

  Widget _body(bool loggedIn) {
    if (!loggedIn) {
      return const Center(child: Text('登录后可查看互动消息'));
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 80),
                Center(child: Text('暂无留言或回复')),
              ],
            )
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final n = _items[i];
                return ListTile(
                  leading: UserAvatar(
                    url: null,
                    nickname: n.actorNickname,
                    radius: 22,
                  ),
                  title: Text(_title(n)),
                  subtitle: Text(
                    [
                      if (n.noteTitle.isNotEmpty) n.noteTitle,
                      if (n.body.isNotEmpty) n.body,
                      formatFriendlyWhen(n.createdAt),
                    ].where((e) => e.trim().isNotEmpty).join('\n'),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  trailing: IconButton(
                    tooltip: '移除',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => _remove(n),
                  ),
                  onTap: () => _open(n),
                );
              },
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = context.watch<AppStore>().user != null;
    if (widget.embedded) return _body(loggedIn);
    return Scaffold(
      appBar: AppBar(title: const Text('留言')),
      body: _body(loggedIn),
    );
  }
}
