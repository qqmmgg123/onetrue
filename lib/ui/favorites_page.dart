import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../social/social_api.dart';
import '../state/app_store.dart';
import 'format.dart';
import 'marketplace_article_page.dart';
import 'note_quill.dart';

/// 醍醐 → 我的收藏。
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

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

  @override
  Widget build(BuildContext context) {
    final loggedIn = context.watch<AppStore>().user != null;
    return Scaffold(
      appBar: AppBar(title: const Text('我的收藏')),
      body: !loggedIn
          ? const Center(child: Text('登录后可查看收藏'))
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
                                  '还没有收藏。\n在文章详情点星标即可收藏。',
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
                                  leading: const Icon(Icons.star_outline),
                                  title: Text(a.displayTitle),
                                  subtitle: Text(
                                    [
                                      summary,
                                      if (a.listedAt != null)
                                        formatFriendlyWhen(
                                          a.listedAt!.toLocal(),
                                        ),
                                    ].join('\n'),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  isThreeLine: true,
                                  onTap: () async {
                                    await Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            MarketplaceArticlePage(article: a),
                                      ),
                                    );
                                    if (mounted) _load();
                                  },
                                );
                              },
                            ),
                    ),
    );
  }
}
