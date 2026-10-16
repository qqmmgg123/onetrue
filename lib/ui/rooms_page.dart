import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_store.dart';
import 'property_detail_page.dart';

class RoomsPage extends StatelessWidget {
  const RoomsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Scaffold(
      body: store.properties.isEmpty
          ? const Center(child: Text('还没有小区。点右下角先加一处房产。'))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
              itemCount: store.properties.length,
              itemBuilder: (context, i) {
                final p = store.properties[i];
                return Card(
                  child: ListTile(
                    title: Text(p.name),
                    subtitle: Text(p.address.isEmpty ? '未填地址' : p.address),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PropertyDetailPage(propertyId: p.id),
                        ),
                      );
                    },
                    onLongPress: () async {
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
                      if (ok == true) {
                        await store.removeProperty(p.id);
                      }
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

  Future<void> _addProperty(BuildContext context) async {
    final name = TextEditingController();
    final address = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新房产'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '名称（小区 / 整栋）'),
              autofocus: true,
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
      await context.read<AppStore>().addProperty(
            name.text.trim(),
            address.text.trim(),
          );
    }
    name.dispose();
    address.dispose();
  }
}
