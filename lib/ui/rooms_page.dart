import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../state/app_store.dart';
import 'auth_page.dart';
import 'busy.dart';
import 'city_utils.dart';
import 'marketplace_article_page.dart';
import 'marketplace_listing_page.dart';
import 'note_editor_page.dart';
import 'property_actions.dart';
import 'property_detail_page.dart';

/// 求索：市集（文章+房源）/ 陋室（我的房产+已上架文章）。
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
        body: _MarketplaceHybridBody(store: store),
      );
    }

    final tab = _mainTab!;
    final onLoushi = tab.index == 1;
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
          _MarketplaceHybridBody(store: store),
          _LoushiHybridBody(store: store),
        ],
      ),
      floatingActionButton: onLoushi
          ? FloatingActionButton.extended(
              onPressed: () => showAddPropertyDialog(context),
              icon: const Icon(Icons.add),
              label: const Text('加房产'),
            )
          : null,
    );
  }
}

class _MarketplaceHybridBody extends StatefulWidget {
  const _MarketplaceHybridBody({required this.store});
  final AppStore store;

  @override
  State<_MarketplaceHybridBody> createState() => _MarketplaceHybridBodyState();
}

class _MarketplaceHybridBodyState extends State<_MarketplaceHybridBody> {
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoad());
  }

  Future<void> _ensureLoad() async {
    final store = widget.store;
    if (store.marketplaceCityReady &&
        (store.marketplaceArticles.isNotEmpty ||
            store.marketplace.isNotEmpty ||
            store.marketplaceLoading)) {
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
    if (store.marketplaceError != null &&
        store.marketplaceArticles.isEmpty &&
        store.marketplace.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => store.refreshMarketplace(city: store.marketplaceCity),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          children: [
            Text(
              '加载失败：${store.marketplaceError}',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final articles = store.marketplaceArticles;
    final rooms = store.marketplace;
    final empty = articles.isEmpty && rooms.isEmpty;

    return RefreshIndicator(
      onRefresh: () => store.refreshMarketplace(city: store.marketplaceCity),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        children: [
          if (empty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 48, 24, 24),
              child: Column(
                children: [
                  Text('暂无上架文章或房源。', textAlign: TextAlign.center),
                  SizedBox(height: 8),
                  Text(
                    '有内容的用户上架后会出现在这里。登录后可在「陋室」发布文章或加房产。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Color(0xFF666666)),
                  ),
                ],
              ),
            ),
          if (articles.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('文章', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            ...articles.map(
              (a) => ListTile(
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
              ),
            ),
          ],
          if (rooms.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('房源', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            ...rooms.map((L) {
              final sub = [
                if (L.city.isNotEmpty) L.city,
                if (L.address.isNotEmpty) L.address,
                if (L.hasVideo) '有视频',
              ].join(' · ');
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.blueGrey.shade100,
                  child: Icon(
                    L.hasVideo ? Icons.videocam : Icons.apartment,
                  ),
                ),
                title: Text('${L.propertyName} · ${L.roomLabel}'),
                subtitle: Text(sub.isEmpty ? '已上架' : sub),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MarketplaceListingPage(listing: L),
                    ),
                  );
                },
              );
            }),
          ],
        ],
      ),
    );
  }
}

class _LoushiHybridBody extends StatelessWidget {
  const _LoushiHybridBody({required this.store});
  final AppStore store;

  List<Note> get _listedArticles => store.notes
      .where((n) => n.kind == kNoteKindArticle && n.isListed)
      .toList()
    ..sort((a, b) {
      final ta = a.listedAt ?? a.updatedAt;
      final tb = b.listedAt ?? b.updatedAt;
      return tb.compareTo(ta);
    });

  Future<void> _renameProperty(BuildContext context, Property p) async {
    final name = TextEditingController(text: p.name);
    final city = TextEditingController(text: p.city);
    final address = TextEditingController(text: p.address);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改房产'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '名称（小区 / 整栋）'),
              autofocus: true,
            ),
            TextField(
              controller: city,
              decoration: const InputDecoration(labelText: '城市（如杭州）'),
            ),
            TextField(
              controller: address,
              decoration: const InputDecoration(labelText: '地址（可选）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty && context.mounted) {
      await runBusy(
        context,
        message: '正在保存…',
        task: () => context.read<AppStore>().renameProperty(
              id: p.id,
              name: name.text.trim(),
              address: address.text.trim(),
              city: city.text.trim(),
            ),
      );
    }
    name.dispose();
    city.dispose();
    address.dispose();
  }

  Future<void> _deleteProperty(BuildContext context, Property p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这处房产？'),
        content: Text('将同时删除 ${p.name} 下的房间和租约。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await runBusy(
        context,
        message: '正在删除…',
        task: () => context.read<AppStore>().removeProperty(p.id),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final properties = store.properties;
    final articles = _listedArticles;
    final empty = properties.isEmpty && articles.isEmpty;

    return RefreshIndicator(
      onRefresh: () => store.reload(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 88),
        children: [
          if (empty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
              child: Column(
                children: [
                  const Text(
                    '还没有房产或上架文章。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '点右下角「加房产」管理租约；或写成文章并打开「上架到市集」。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 20),
                  OutlinedButton(
                    onPressed: () => showAddPropertyDialog(context),
                    child: const Text('加房产'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
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
                ],
              ),
            ),
          if (properties.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('我的房产', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            ...properties.map((p) {
              final sub = [
                if (p.city.isNotEmpty) p.city,
                if (p.address.isNotEmpty) p.address,
              ].join(' · ');
              return ListTile(
                leading: const Icon(Icons.home_work_outlined),
                title: Text(p.name),
                subtitle: Text(sub.isEmpty ? '未填城市/地址' : sub),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'rename') {
                      await _renameProperty(context, p);
                    } else if (v == 'delete') {
                      await _deleteProperty(context, p);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('改名')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PropertyDetailPage(propertyId: p.id),
                    ),
                  );
                },
              );
            }),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                const Text('上架文章', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton(
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
              ],
            ),
          ),
          if (articles.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                '还没有上架文章。写成文章并打开「上架到市集」后会出现在这里。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else
            ...articles.map((n) {
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
            }),
        ],
      ),
    );
  }
}
