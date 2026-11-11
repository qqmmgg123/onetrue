import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../state/app_store.dart';
import 'auth_page.dart';
import 'city_utils.dart';
import 'marketplace_article_page.dart';
import 'note_editor_page.dart';

/// 求索：市集 / 陋室，仅文章。
class RoomsPage extends StatefulWidget {
  const RoomsPage({super.key});

  @override
  State<RoomsPage> createState() => _RoomsPageState();
}

class _RoomsPageState extends State<RoomsPage>
    with SingleTickerProviderStateMixin {
  TabController? _mainTab;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final landlord = context.read<AppStore>().isLandlord;
    if (landlord && _mainTab == null) {
      _mainTab = TabController(length: 2, vsync: this);
      _mainTab!.addListener(() {
        if (!_mainTab!.indexIsChanging) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _mainTab?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    if (store.isGuest) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('求索'),
          actions: [
            TextButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AuthPage()),
                );
              },
              child: const Text('登录/注册'),
            ),
          ],
        ),
        body: _MarketplaceArticlesBody(store: store),
      );
    }

    final tab = _mainTab!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('求索'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: TabBar(
            controller: tab,
            tabs: const [
              Tab(height: 36, text: '市集'),
              Tab(height: 36, text: '陋室'),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: tab,
        children: [
          _MarketplaceArticlesBody(store: store),
          _LoushiArticlesBody(store: store),
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
    if (store.marketplaceArticles.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => store.refreshMarketplace(city: store.marketplaceCity),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          children: [
            const Text('暂无上架文章。', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              '有内容的用户上架后会出现在这里。登录后可在「陋室」发布自己的文章。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => store.refreshMarketplace(city: store.marketplaceCity),
      child: ListView.separated(
        itemCount: store.marketplaceArticles.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final a = store.marketplaceArticles[i];
          return ListTile(
            leading: const Icon(Icons.article_outlined),
            title: Text(a.displayTitle),
            subtitle: Text(
              [
                '文章',
                if (a.city.isNotEmpty) a.city,
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
      ),
    );
  }
}

class _LoushiArticlesBody extends StatelessWidget {
  const _LoushiArticlesBody({required this.store});
  final AppStore store;

  List<Note> get _listedArticles => store.notes
      .where((n) => n.kind == kNoteKindArticle && n.isListed)
      .toList()
    ..sort((a, b) {
      final ta = a.listedAt ?? a.updatedAt;
      final tb = b.listedAt ?? b.updatedAt;
      return tb.compareTo(ta);
    });

  @override
  Widget build(BuildContext context) {
    final list = _listedArticles;
    if (list.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => store.reload(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          children: [
            const Text(
              '还没有上架文章。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 8),
            Text(
              '在「作为 → 新笔记」写成文章，打开「上架到市集」后会出现在这里。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            Center(
              child: OutlinedButton(
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
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => store.reload(),
      child: ListView.separated(
        itemCount: list.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final n = list[i];
          final uid = store.user?.id ?? '';
          return ListTile(
            leading: const Icon(Icons.article_outlined),
            title: Text(n.displayTitle),
            subtitle: Text(
              [
                '已上架',
                if (n.city.isNotEmpty) n.city,
              ].join(' · '),
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => MarketplaceArticlePage(
                    article: MarketplaceArticle(
                      noteUuid: n.uuid,
                      title: n.title,
                      body: n.body,
                      format: n.format,
                      city: n.city,
                      listedAt: n.listedAt,
                      ownerId: uid,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
