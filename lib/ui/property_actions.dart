import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_gate.dart';
import '../state/app_store.dart';
import 'busy.dart';
import 'city_utils.dart';

/// 加房产对话框（「作为」与陋室入口共用）。
Future<void> showAddPropertyDialog(BuildContext context) async {
  final allowed = await requireLandlord(context);
  if (!allowed || !context.mounted) return;
  final store = context.read<AppStore>();
  final messenger = ScaffoldMessenger.maybeOf(context);

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
                  decoration: const InputDecoration(labelText: '名称（小区 / 整栋）'),
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
