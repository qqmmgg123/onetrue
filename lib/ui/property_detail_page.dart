import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_database.dart';
import '../domain/models.dart';
import '../state/app_store.dart';
import 'format.dart';
import 'room_detail_page.dart';

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
    return Scaffold(
      appBar: AppBar(title: Text(_property?.name ?? '房产')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                children: [
                  if (_property?.address.isNotEmpty == true)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_property!.address),
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
                        trailing: const Icon(Icons.chevron_right),
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
      await context.read<AppStore>().addRoom(
            widget.propertyId,
            label.text.trim(),
          );
      await _load();
    }
    label.dispose();
  }
}
