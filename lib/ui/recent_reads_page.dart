import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/note_title.dart';
import '../state/app_store.dart';
import 'format.dart';
import 'marketplace_article_page.dart';
import 'note_quill.dart';

/// 醍醐 → 近期阅读：仅登录用户；按最后阅读时间倒序。
class RecentReadsPage extends StatelessWidget {
  const RecentReadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    if (store.isGuest) {
      return Scaffold(
        appBar: AppBar(title: const Text('近期阅读')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '登录后才会记录近期阅读。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final list = store.articleReads;

    return Scaffold(
      appBar: AppBar(title: const Text('近期阅读')),
      body: list.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '还没有阅读记录。去「求索 → 雅集」点开文章后会出现在这里。',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final r = list[i];
                final decoded = plainTextFromStoredBody(
                  r.body,
                  format: r.format.isNotEmpty ? r.format : kStoredQuill,
                );
                final plain = decoded
                    .replaceAll(RegExp(r'\s+'), ' ')
                    .trim();
                final fallback = plainTextFromNoteBody(r.body)
                    .replaceAll(RegExp(r'\s+'), ' ')
                    .trim();
                final text = plain.isNotEmpty ? plain : fallback;
                final summary = text.isEmpty
                    ? r.displayTitle
                    : (text.length > 60 ? '${text.substring(0, 60)}…' : text);
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
