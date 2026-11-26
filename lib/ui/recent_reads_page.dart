import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../state/app_store.dart';
import 'article_feed_card.dart';
import 'busy.dart';
import 'open_article.dart';

/// 近期阅读：仅登录用户；按最后阅读时间倒序。
class RecentReadsPage extends StatelessWidget {
  const RecentReadsPage({super.key, this.embedded = false});

  /// 嵌入阅读 Tab 时不画独立 Scaffold / AppBar。
  final bool embedded;

  Widget _body(BuildContext context, AppStore store) {
    if (store.isGuest) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '登录后才会记录近期阅读。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final list = store.articleReads;
    final articles = list.map((r) => r.toArticle()).toList();

    Future<void> removeRead(MarketplaceArticle article) async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('移除阅读记录？'),
          content: Text('将「${article.displayTitle}」从近期阅读中移除。'),
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
      if (ok != true || !context.mounted) return;
      await runBusy(
        context,
        message: '正在移除…',
        task: () => store.removeArticleRead(article.noteUuid),
      );
    }

    return ArticleFeedGrid(
      articles: articles,
      onRefresh: () => store.syncArticleReadsFromCloud(),
      onOpen: (a) => openMarketplaceArticle(context, a),
      deleteMode: ArticleFeedDeleteMode.always,
      deleteTooltip: '移除记录',
      onDelete: removeRead,
      footTimeOf: (a) {
        for (final r in list) {
          if (r.noteUuid == a.noteUuid) return r.lastReadAt;
        }
        return null;
      },
      empty: const Padding(
        padding: EdgeInsets.fromLTRB(24, 48, 24, 24),
        child: Text(
          '还没有阅读记录。去「阅读 → 推荐」点开文章后会出现在这里。',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    if (embedded) return _body(context, store);
    return Scaffold(
      appBar: AppBar(title: const Text('近期阅读')),
      body: _body(context, store),
    );
  }
}
