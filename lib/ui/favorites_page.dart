import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../social/social_api.dart';
import '../state/app_store.dart';
import 'article_feed_card.dart';
import 'busy.dart';
import 'open_article.dart';

/// 我的收藏。
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key, this.embedded = false});

  /// 嵌入阅读 Tab 时不画独立 Scaffold / AppBar。
  final bool embedded;

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  bool _loading = true;
  String? _error;
  List<MarketplaceArticle> _items = const [];

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
      final list = await SocialApi.instance.fetchMyFavorites();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _unfavorite(MarketplaceArticle a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消收藏？'),
        content: Text('将「${a.displayTitle}」从收藏中移除。'),
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
      task: () async {
        final still = await SocialApi.instance.hasFavorited(a.noteUuid);
        if (still) await SocialApi.instance.toggleFavorite(a.noteUuid);
      },
    );
    if (mounted) await _load();
  }

  Widget _body(bool loggedIn) {
    if (!loggedIn) {
      return const Center(child: Text('登录后可查看收藏'));
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    return ArticleFeedGrid(
      articles: _items,
      onRefresh: _load,
      onOpen: (a) async {
        await openMarketplaceArticle(context, a);
        if (mounted) _load();
      },
      deleteMode: ArticleFeedDeleteMode.always,
      deleteTooltip: '取消收藏',
      onDelete: _unfavorite,
      empty: const Padding(
        padding: EdgeInsets.fromLTRB(24, 48, 24, 24),
        child: Text(
          '还没有收藏。\n在文章详情点星标即可收藏。',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = context.watch<AppStore>().user != null;
    if (widget.embedded) return _body(loggedIn);
    return Scaffold(
      appBar: AppBar(title: const Text('我的收藏')),
      body: _body(loggedIn),
    );
  }
}
