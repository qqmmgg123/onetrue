import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../social/social_api.dart';
import '../state/app_store.dart';
import 'format.dart';
import 'marketplace_article_page.dart';
import 'note_quill.dart';

/// 醍醐 → 留意的人：按最新上架时间展示留意用户的文章。
class FollowingFeedPage extends StatefulWidget {
  const FollowingFeedPage({super.key});

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

  @override
  Widget build(BuildContext context) {
    final loggedIn = context.watch<AppStore>().user != null;
    return Scaffold(
      appBar: AppBar(title: const Text('留意的人')),
      body: !loggedIn
          ? const Center(child: Text('登录后可查看留意动态'))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: _items.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.all(24),
                              children: const [
                                SizedBox(height: 48),
                                Text(
                                  '还没有留意的人，或对方暂无上架文章。\n去雅集文章详情滑到作者陋室点留意吧。',
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            )
                          : ListView.separated(
                              itemCount: _items.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, i) {
                                final a = _items[i];
                                final plain = plainTextFromStoredBody(
                                  a.body,
                                  format: a.format,
                                )
                                    .replaceAll(RegExp(r'\s+'), ' ')
                                    .trim();
                                final summary = plain.isEmpty
                                    ? a.displayTitle
                                    : (plain.length > 72
                                        ? '${plain.substring(0, 72)}…'
                                        : plain);
                                return ListTile(
                                  title: Text(a.displayTitle),
                                  subtitle: Text(
                                    [
                                      summary,
                                      if (a.listedAt != null)
                                        formatFriendlyWhen(
                                          a.listedAt!.toLocal(),
                                        ),
                                      '❤ ${a.recommendCount} · 评 ${a.commentCount}',
                                    ].join('\n'),
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  isThreeLine: true,
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            MarketplaceArticlePage(article: a),
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
