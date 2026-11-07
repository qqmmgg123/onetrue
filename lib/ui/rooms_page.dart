import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_gate.dart';
import '../domain/models.dart';
import '../state/app_store.dart';
import 'busy.dart';
import 'city_utils.dart';
import 'marketplace_listing_page.dart';
import 'property_detail_page.dart';

class RoomsPage extends StatefulWidget {
  const RoomsPage({super.key});

  @override
  State<RoomsPage> createState() => _RoomsPageState();
}

class _RoomsPageState extends State<RoomsPage> {
  /// 0=我的，1=广场（仅房东显示切换；游客固定广场）
  int _segment = 0;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    if (store.isGuest) {
      return _MarketplaceBody(store: store);
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('我的'), icon: Icon(Icons.home_work_outlined)),
              ButtonSegment(value: 1, label: Text('广场'), icon: Icon(Icons.storefront_outlined)),
            ],
            selected: {_segment},
            onSelectionChanged: (s) => setState(() => _segment = s.first),
          ),
        ),
        Expanded(
          child: _segment == 0
              ? _LandlordRoomsBody(store: store)
              : _MarketplaceBody(store: store),
        ),
      ],
    );
  }
}

class _LandlordRoomsBody extends StatelessWidget {
  const _LandlordRoomsBody({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: store.properties.isEmpty
          ? const Center(child: Text('还没有小区。点右下角先加一处房产。'))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
              itemCount: store.properties.length,
              itemBuilder: (context, i) {
                final p = store.properties[i];
                final sub = [
                  if (p.city.isNotEmpty) p.city,
                  if (p.address.isNotEmpty) p.address,
                ].join(' · ');
                return Card(
                  child: ListTile(
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
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addProperty(context),
        icon: const Icon(Icons.add),
        label: const Text('加房产'),
      ),
    );
  }

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

  Future<void> _addProperty(BuildContext context) async {
    final allowed = await requireLandlord(context);
    if (!allowed) return;
    final store = context.read<AppStore>();
    final messenger = ScaffoldMessenger.maybeOf(context);

    // 打开前尽量自动填城市（失败不挡录入）
    var prefillCity = store.marketplaceCity;
    if (prefillCity.isEmpty) {
      try {
        prefillCity = await runBusy(
          context,
          message: '正在识别所在城市…',
          task: () async => (await detectCityName()) ?? '',
        );
      } catch (_) {
        prefillCity = '';
      }
    }
    if (!context.mounted) return;

    final name = TextEditingController();
    final city = TextEditingController(text: prefillCity);
    final address = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('新房产'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration:
                        const InputDecoration(labelText: '名称（小区 / 整栋）'),
                    autofocus: true,
                  ),
                  TextField(
                    controller: city,
                    decoration: InputDecoration(
                      labelText: '城市（上架广场必填）',
                      suffixIcon: IconButton(
                        tooltip: '重新定位',
                        icon: const Icon(Icons.my_location),
                        onPressed: () async {
                          try {
                            final c = await detectCityName();
                            if (c != null && c.isNotEmpty) {
                              city.text = c;
                              setLocal(() {});
                            }
                          } catch (_) {}
                        },
                      ),
                    ),
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
            );
          },
        );
      },
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      try {
        await store.addProperty(
          name.text.trim(),
          address.text.trim(),
          city: city.text.trim(),
        );
      } catch (e) {
        messenger?.showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    name.dispose();
    city.dispose();
    address.dispose();
  }
}

class _MarketplaceBody extends StatefulWidget {
  const _MarketplaceBody({required this.store});
  final AppStore store;

  @override
  State<_MarketplaceBody> createState() => _MarketplaceBodyState();
}

class _MarketplaceBodyState extends State<_MarketplaceBody> {
  final _cityCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cityCtrl.text = widget.store.marketplaceCity;
    if (widget.store.marketplace.isEmpty && !widget.store.marketplaceLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.store.refreshMarketplace();
      });
    }
  }

  @override
  void dispose() {
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    try {
      final city = await runBusy(
        context,
        message: '正在定位…',
        task: detectCityName,
      );
      if (!mounted) return;
      if (city == null || city.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('未能识别城市，请打开定位权限后重试，或手动点选城市'),
          ),
        );
        return;
      }
      _cityCtrl.text = city;
      await widget.store.refreshMarketplace(city: city);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已定位到$city')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('定位超时，请手动点选城市，或到户外/打开 Wi‑Fi 后再试'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Scaffold(
      // 嵌在房东「我的/广场」切换里时不要再套一层顶栏间距冲突
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _cityCtrl,
                    decoration: const InputDecoration(
                      labelText: '城市筛选',
                      hintText: '留空=全部',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (v) => store.refreshMarketplace(city: v.trim()),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '定位',
                  onPressed: _locate,
                  icon: const Icon(Icons.my_location),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: () =>
                      store.refreshMarketplace(city: _cityCtrl.text.trim()),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FilterChip(
                    label: const Text('全部'),
                    selected: store.marketplaceCity.isEmpty,
                    onSelected: (_) {
                      _cityCtrl.clear();
                      store.refreshMarketplace(city: '');
                    },
                  ),
                ),
                ...kCommonCities.map(
                  (c) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: FilterChip(
                      label: Text(c),
                      selected: store.marketplaceCity == c,
                      onSelected: (_) {
                        _cityCtrl.text = c;
                        store.refreshMarketplace(city: c);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: store.marketplaceLoading
                ? const Center(child: CircularProgressIndicator())
                : store.marketplaceError != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            '加载失败：${store.marketplaceError}',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : store.marketplace.isEmpty
                        ? const Center(child: Text('该城市暂无上架房源'))
                        : RefreshIndicator(
                            onRefresh: () => store.refreshMarketplace(
                              city: _cityCtrl.text.trim(),
                            ),
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                              itemCount: store.marketplace.length,
                              itemBuilder: (context, i) {
                                final L = store.marketplace[i];
                                final sub = [
                                  if (L.city.isNotEmpty) L.city,
                                  if (L.address.isNotEmpty) L.address,
                                  if (L.hasVideo) '有视频',
                                ].join(' · ');
                                return Card(
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: Colors.blueGrey.shade100,
                                      child: Icon(
                                        L.hasVideo
                                            ? Icons.videocam
                                            : Icons.apartment,
                                      ),
                                    ),
                                    title: Text(
                                      '${L.propertyName} · ${L.roomLabel}',
                                    ),
                                    subtitle: Text(
                                      sub.isEmpty ? '已上架' : sub,
                                    ),
                                    onTap: () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              MarketplaceListingPage(
                                            listing: L,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}
