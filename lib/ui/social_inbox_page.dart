import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../social/social_api.dart';
import '../social/social_models.dart';
import '../state/app_store.dart';
import '../sync/sync_service.dart';
import 'format.dart';
import 'marketplace_article_page.dart';
import 'widgets/user_avatar.dart';

/// 醍醐 → 评点和回书（类小红书/B站消息流）。
class SocialInboxPage extends StatefulWidget {
  const SocialInboxPage({super.key});

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
      // 只展示评论/回复类（关注、推荐也可显示）
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
        return '$who 评点了你的文章';
      case 'recommend':
        return '$who 推荐了你的文章';
      case 'follow':
        return '$who 留意了你';
      default:
        return who;
    }
  }

  Future<void> _open(SocialNotificationItem n) async {
    final noteId = n.noteId?.trim() ?? '';
    if (noteId.isEmpty) return;
    try {
      // 拉一篇 listed 文章详情
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
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MarketplaceArticlePage(
            article: hit!,
            highlightCommentId: n.commentId,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = context.watch<AppStore>().user != null;
    return Scaffold(
      appBar: AppBar(title: const Text('评点和回书')),
      body: !loggedIn
          ? const Center(child: Text('登录后可查看互动消息'))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: _items.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: const [
                                SizedBox(height: 80),
                                Center(child: Text('暂无评点或回书')),
                              ],
                            )
                          : ListView.separated(
                              itemCount: _items.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
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
                                  onTap: () => _open(n),
                                );
                              },
                            ),
                    ),
    );
  }
}
