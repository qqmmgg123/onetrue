import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_store.dart';
import 'format.dart';
import 'marketplace_article_page.dart';

/// 醍醐 → 近期阅读：本机阅读过的文章，按最后阅读时间倒序。
class RecentReadsPage extends StatelessWidget {
  const RecentReadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final list = store.articleReads;

    return Scaffold(
      appBar: AppBar(title: const Text('近期阅读')),
      body: list.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '还没有阅读记录。去「求索 → 市集」点开文章后会出现在这里。',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final r = list[i];
                final plain = r.body
                    .replaceAll(RegExp(r'\s+'), ' ')
                    .trim();
                final summary = plain.isEmpty
                    ? r.displayTitle
                    : (plain.length > 60
                        ? '${plain.substring(0, 60)}…'
                        : plain);
                return ListTile(
                  leading: const Icon(Icons.menu_book_outlined),
                  title: Text(r.displayTitle),
                  subtitle: Text(
                    [
                      summary,
                      formatFriendlyWhen(r.lastReadAt.toLocal()),
                    ].join('\n'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            MarketplaceArticlePage(article: r.toArticle()),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}
