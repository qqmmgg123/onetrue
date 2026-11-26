import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../social/social_api.dart';
import '../state/app_store.dart';
import 'article_feed_card.dart';
import 'open_article.dart';

/// 留意的人：按最新时间展示留意用户的文章。
class FollowingFeedPage extends StatefulWidget {
  const FollowingFeedPage({super.key, this.embedded = false});

  /// 嵌入阅读 Tab 时不画独立 Scaffold / AppBar。
  final bool embedded;

  @override
  State<FollowingFeedPage> createState() => _FollowingFeedPageState();
}

class _FollowingFeedPageState extends State<FollowingFeedPage> {
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
      final list = await SocialApi.instance.fetchFollowingArticles();
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

  Widget _body(bool loggedIn) {
    if (!loggedIn) {
      return const Center(child: Text('登录后可查看留意动态'));
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
      onOpen: (a) => openMarketplaceArticle(context, a),
      empty: const Padding(
        padding: EdgeInsets.fromLTRB(24, 48, 24, 24),
        child: Text(
          '还没有留意的人，或对方暂无文章。\n去阅读推荐打开文章后点作者头像留意吧。',
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
      appBar: AppBar(title: const Text('留意的人')),
      body: _body(loggedIn),
    );
  }
}
