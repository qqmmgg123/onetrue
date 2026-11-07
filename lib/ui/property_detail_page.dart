import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_database.dart';
import '../domain/models.dart';
import '../state/app_store.dart';
import 'busy.dart';
import 'format.dart';
import 'room_detail_page.dart';
import 'room_video_thumb.dart';

class PropertyDetailPage extends StatefulWidget {
  const PropertyDetailPage({super.key, required this.propertyId});

  final int propertyId;

  @override
  State<PropertyDetailPage> createState() => _PropertyDetailPageState();
}

class _PropertyDetailPageState extends State<PropertyDetailPage> {
  Property? _property;
  List<RoomSnapshot> _rooms = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = AppDatabase.instance;
    final store = context.read<AppStore>();
    final property = await db.getProperty(widget.propertyId);
    final rooms = await store.roomsOf(widget.propertyId);
    if (!mounted) return;
    setState(() {
      _property = property;
      _rooms = rooms;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final property = _property;
    return Scaffold(
      appBar: AppBar(
        title: Text(property?.name ?? '房产'),
        actions: [
          if (property != null)
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'rename') {
                  await _renameProperty(property);
                } else if (v == 'delete') {
                  await _deleteProperty(property);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('改名')),
                PopupMenuItem(value: 'delete', child: Text('删除房产')),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                children: [
                  if (property != null &&
                      (property.city.isNotEmpty ||
                          property.address.isNotEmpty))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        [
                          if (property.city.isNotEmpty) property.city,
                          if (property.address.isNotEmpty) property.address,
                        ].join(' · '),
                      ),
                    ),
                  if (_rooms.isEmpty) const Text('还没有房间。'),
                  ..._rooms.map((snap) {
                    final lease = snap.lease;
                    final tenant = snap.tenant;
                    final subtitle = lease == null
                        ? '空房'
                        : '${tenant?.name ?? '租户'} · 每月${lease.rentDueDay}号 · ${formatYuan(lease.baseRent)}';
                    return Card(
                      child: ListTile(
                        title: Text(snap.room.label),
                        subtitle: Text(subtitle),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            RoomVideoThumb.fromRoom(
                              snap.room,
                              onClosed: _load,
                            ),
                            PopupMenuButton<String>(
                              onSelected: (v) async {
                                if (v == 'rename') {
                                  await _renameRoom(snap.room);
                                } else if (v == 'delete') {
                                  await _deleteRoom(snap.room);
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'rename',
                                  child: Text('改房号'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除房间'),
                                ),
                              ],
                            ),
                          ],
                        ),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  RoomDetailPage(roomId: snap.room.id),
                            ),
                          );
                          await _load();
                        },
                      ),
                    );
                  }),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addRoom,
        icon: const Icon(Icons.add),
        label: const Text('加房间'),
      ),
    );
  }

  Future<void> _renameProperty(Property p) async {
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
    if (ok == true && name.text.trim().isNotEmpty && mounted) {
      final n = name.text.trim();
      final c = city.text.trim();
      final a = address.text.trim();
      await runBusy(
        context,
        message: '正在保存…',
        task: () async {
          await context.read<AppStore>().renameProperty(
                id: p.id,
                name: n,
                address: a,
                city: c,
              );
          await _load();
        },
      );
    }
    name.dispose();
    city.dispose();
    address.dispose();
  }

  Future<void> _deleteProperty(Property p) async {
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
    if (ok == true && mounted) {
      await runBusy(
        context,
        message: '正在删除…',
        task: () => context.read<AppStore>().removeProperty(p.id),
      );
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _renameRoom(Room room) async {
    final label = TextEditingController(text: room.label);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('改房号'),
        content: TextField(
          controller: label,
          decoration: const InputDecoration(labelText: '房号，如 302'),
          autofocus: true,
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
    if (ok == true && label.text.trim().isNotEmpty && mounted) {
      final n = label.text.trim();
      await runBusy(
        context,
        message: '正在保存…',
        task: () async {
          await context.read<AppStore>().renameRoom(id: room.id, label: n);
          await _load();
        },
      );
    }
    label.dispose();
  }

  Future<void> _deleteRoom(Room room) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个房间？'),
        content: Text('将删除 ${room.label} 及其租约和账期。'),
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
    if (ok == true && mounted) {
      await runBusy(
        context,
        message: '正在删除…',
        task: () async {
          await context.read<AppStore>().removeRoom(room.id);
          await _load();
        },
      );
    }
  }

  Future<void> _addRoom() async {
    final label = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新房间'),
        content: TextField(
          controller: label,
          decoration: const InputDecoration(labelText: '房号，如 302'),
          autofocus: true,
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
    if (ok == true && label.text.trim().isNotEmpty && mounted) {
      final n = label.text.trim();
      await runBusy(
        context,
        message: '正在保存…',
        task: () async {
          await context.read<AppStore>().addRoom(widget.propertyId, n);
          await _load();
        },
      );
    }
    label.dispose();
  }
}
