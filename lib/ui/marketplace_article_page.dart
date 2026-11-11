import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../state/app_store.dart';
import '../sync/sync_service.dart';
import 'format.dart';
import 'note_quill.dart';

/// 文章详情：初始在详情页；向右滑到作者陋室，向左滑回详情。
class MarketplaceArticlePage extends StatefulWidget {
  const MarketplaceArticlePage({super.key, required this.article});

  final MarketplaceArticle article;

  @override
  State<MarketplaceArticlePage> createState() => _MarketplaceArticlePageState();
}

class _MarketplaceArticlePageState extends State<MarketplaceArticlePage> {
  late final PageController _page;

  @override
  void initState() {
    super.initState();
    // 1=详情，0=作者陋室：从详情向右滑到陋室
    _page = PageController(initialPage: 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppStore>().recordArticleOpen(widget.article);
    });
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _page,
        children: [
          _AuthorLoushiPane(
            ownerId: widget.article.ownerId,
            onBackToArticle: () => _page.animateToPage(
              1,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOut,
            ),
          ),
          _ArticleDetailPane(
            article: widget.article,
            onOpenAuthor: () => _page.animateToPage(
              0,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOut,
            ),
          ),
        ],
      ),
    );
  }
}

class _ArticleDetailPane extends StatelessWidget {
  const _ArticleDetailPane({
    required this.article,
    required this.onOpenAuthor,
  });

  final MarketplaceArticle article;
  final VoidCallback onOpenAuthor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(article.displayTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          if (article.ownerId.trim().isNotEmpty)
            TextButton(
              onPressed: onOpenAuthor,
              child: const Text('作者陋室'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (article.city.isNotEmpty || article.listedAt != null)
            Text(
              [
                if (article.city.isNotEmpty) article.city,
                if (article.listedAt != null)
                  ymdCn(article.listedAt!.toLocal()),
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 12),
          SelectableText(
            plainTextFromStoredBody(article.body),
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 24),
          Text(
            article.ownerId.trim().isEmpty
                ? '向右滑动可查看作者陋室（若已关联作者）。'
                : '向右滑动打开作者陋室；向左滑回本文。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _AuthorLoushiPane extends StatefulWidget {
  const _AuthorLoushiPane({
    required this.ownerId,
    required this.onBackToArticle,
  });

  final String ownerId;
  final VoidCallback onBackToArticle;

  @override
  State<_AuthorLoushiPane> createState() => _AuthorLoushiPaneState();
}

class _AuthorLoushiPaneState extends State<_AuthorLoushiPane> {
  bool _loading = true;
  String? _error;
  List<MarketplaceArticle> _articles = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final oid = widget.ownerId.trim();
    if (oid.isEmpty) {
      setState(() {
        _loading = false;
        _error = '暂无作者信息';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sync = SyncService(db: context.read<AppStore>().db);
      final articles = await sync.fetchListedArticles(ownerId: oid);
      if (!mounted) return;
      setState(() {
        _articles = articles;
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('作者陋室'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBackToArticle,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _articleList(),
                ),
    );
  }

  Widget _articleList() {
    if (_articles.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 80),
          Center(child: Text('这位作者还没有上架文章')),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _articles.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final a = _articles[i];
        return ListTile(
          leading: const Icon(Icons.article_outlined),
          title: Text(a.displayTitle),
          subtitle: Text(
            [
              if (a.city.isNotEmpty) a.city,
              '已上架',
            ].join(' · '),
          ),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MarketplaceArticlePage(article: a),
              ),
            );
          },
        );
      },
    );
  }
}
