import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_service.dart';
import '../domain/models.dart';
import '../social/avatar_io.dart';
import '../state/app_store.dart';
import 'article_feed_card.dart';
import 'auth_page.dart';
import 'busy.dart';
import 'city_utils.dart';
import 'favorites_page.dart';
import 'following_feed_page.dart';
import 'marketplace_article_page.dart';
import 'note_editor_page.dart';
import 'open_article.dart';
import 'recent_reads_page.dart';
import 'social_inbox_page.dart';
import 'widgets/user_avatar.dart';

/// 阅读：推荐 / 留意 / 近期 / 收藏 / 我的 / 留言。
class RoomsPage extends StatefulWidget {
  const RoomsPage({super.key});

  @override
  State<RoomsPage> createState() => _RoomsPageState();
}

class _RoomsPageState extends State<RoomsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  static const _labels = ['推荐', '留意', '近期', '收藏', '我的', '留言'];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _labels.length, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _openAuth() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AuthPage()),
    );
  }

  Future<void> _openNewArticle(AppStore store) async {
    if (store.isGuest) {
      await _openAuth();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            const NoteEditorPage(initialKind: kNoteKindArticle),
      ),
    );
  }

  Widget _loginCta(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('登录后可查看此内容', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _openAuth,
              child: const Text('登录'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final guest = store.isGuest;

    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读'),
        actions: [
          if (guest)
            TextButton(
              onPressed: _openAuth,
              child: const Text('登录'),
            )
          else
            IconButton(
              tooltip: '写文章',
              icon: const Icon(Icons.add),
              onPressed: () => _openNewArticle(store),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: TabBar(
            controller: _tabs,
            isScrollable: true,
            tabs: [
              for (final label in _labels)
                Tab(height: 36, text: label),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _MarketplaceArticlesBody(store: store),
          guest ? _loginCta(context) : const FollowingFeedPage(embedded: true),
          guest ? _loginCta(context) : const RecentReadsPage(embedded: true),
          guest ? _loginCta(context) : const FavoritesPage(embedded: true),
          guest ? _loginCta(context) : _MyArticlesBody(store: store),
          guest ? _loginCta(context) : const SocialInboxPage(embedded: true),
        ],
      ),
    );
  }
}

class _MarketplaceArticlesBody extends StatefulWidget {
  const _MarketplaceArticlesBody({required this.store});
  final AppStore store;

  @override
  State<_MarketplaceArticlesBody> createState() =>
      _MarketplaceArticlesBodyState();
}

class _MarketplaceArticlesBodyState extends State<_MarketplaceArticlesBody> {
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoad());
  }

  Future<void> _ensureLoad() async {
    final store = widget.store;
    if (store.marketplaceCityReady &&
        (store.marketplaceArticles.isNotEmpty || store.marketplaceLoading)) {
      return;
    }
    if (store.marketplaceCity.isNotEmpty) {
      store.marketplaceCityReady = true;
      await store.refreshMarketplace();
      return;
    }
    setState(() => _locating = true);
    try {
      final city = await detectCityName();
      if (!mounted) return;
      if (city != null && city.isNotEmpty) {
        await store.refreshMarketplace(city: city);
      } else {
        store.marketplaceCityReady = true;
        await store.refreshMarketplace(city: '');
      }
    } catch (_) {
      if (!mounted) return;
      store.marketplaceCityReady = true;
      await store.refreshMarketplace(city: '');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    if (_locating || store.marketplaceLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ArticleFeedGrid(
      articles: store.marketplaceArticles,
      onRefresh: () => store.refreshMarketplace(city: store.marketplaceCity),
      onOpen: (a) => openMarketplaceArticle(context, a),
      empty: Padding(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
        child: Column(
          children: [
            const Text('暂无文章。', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              '有内容的用户发布后会出现在这里。登录后可在「我的」发布自己的文章。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// 「我的」：本机文章（不按上架状态过滤）。
class _MyArticlesBody extends StatelessWidget {
  const _MyArticlesBody({required this.store});
  final AppStore store;

  List<Note> get _articles => store.notes
      .where((n) => n.kind == kNoteKindArticle)
      .toList()
    ..sort((a, b) {
      final ta = a.updatedAt;
      final tb = b.updatedAt;
      return tb.compareTo(ta);
    });

  Future<void> _changeAvatar(BuildContext context) async {
    final uid = AuthService.instance.currentUser?.id ?? '';
    if (uid.isEmpty) return;
    try {
      final url = await pickCropUploadAvatar(context: context, userId: uid);
      if (url == null || !context.mounted) return;
      await runBusy(
        context,
        message: '更新头像…',
        task: () => AuthService.instance.updateAvatarUrl(url),
      );
      await AuthService.instance.refreshProfile();
      imageCache.clear();
      imageCache.clearLiveImages();
      if (context.mounted) await store.reload();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('上传失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _articles;
    final user = store.user ?? AuthService.instance.currentUser;
    final nick = user?.displayName.trim().isNotEmpty == true
        ? user!.displayName
        : '我';
    final avatar = user?.avatarUrl ?? '';

    Widget header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Column(
        children: [
          GestureDetector(
            onTap: () => _changeAvatar(context),
            child: Column(
              children: [
                UserAvatar(url: avatar, nickname: nick, radius: 40),
                const SizedBox(height: 6),
                const Text(
                  '点击更换头像',
                  style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            nick,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );

    final uid = store.user?.id ?? '';
    final articles = list
        .map(
          (n) => MarketplaceArticle(
            noteUuid: n.uuid,
            title: n.title,
            body: n.body,
            format: n.format,
            city: n.city,
            coverUrl: n.coverUrl,
            listedAt: n.listedAt,
            ownerId: uid,
            recommendCount: 0,
            commentCount: 0,
            viewCount: 0,
          ),
        )
        .toList();

    Future<void> openArticle(MarketplaceArticle a) async {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MarketplaceArticlePage(article: a),
        ),
      );
    }

    Future<void> deleteArticle(MarketplaceArticle a) async {
      Note? note;
      for (final n in list) {
        if (n.uuid == a.noteUuid) {
          note = n;
          break;
        }
      }
      if (note == null) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('删除这篇文章？'),
          content: Text('确认删除「${a.displayTitle}」？删除后无法恢复。'),
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
        task: () => store.removeNote(note!.id),
      );
    }

    return ArticleFeedGrid(
      articles: articles,
      header: Column(
        children: [
          header,
          const Divider(height: 1),
        ],
      ),
      onRefresh: () => store.reload(),
      onOpen: openArticle,
      deleteMode: ArticleFeedDeleteMode.always,
      onDelete: deleteArticle,
      empty: Padding(
        padding: const EdgeInsets.fromLTRB(24, 36, 24, 24),
        child: Column(
          children: [
            const Text(
              '还没有文章。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 8),
            Text(
              '点右上角「+」写成文章并发布后会出现在这里。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NoteEditorPage(
                      initialKind: kNoteKindArticle,
                    ),
                  ),
                );
              },
              child: const Text('去写文章'),
            ),
          ],
        ),
      ),
    );
  }
}
