import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../social/social_api.dart';
import 'marketplace_article_page.dart';

/// 阅读各入口统一打开：已删除 / 已改类型（下架）分别提示，不进详情。
Future<void> openMarketplaceArticle(
  BuildContext context,
  MarketplaceArticle article, {
  String? highlightCommentId,
}) async {
  final status = await SocialApi.instance.resolveArticleAvailability(
    article.noteUuid,
    hintDeleted: article.deleted,
    hintDelisted: article.delisted,
  );
  if (!context.mounted) return;
  if (status != ArticleAvailability.ok) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(status.userMessage)),
    );
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => MarketplaceArticlePage(
        article: article,
        highlightCommentId: highlightCommentId,
      ),
    ),
  );
}
