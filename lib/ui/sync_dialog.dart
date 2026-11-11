import 'package:flutter/material.dart';

import '../state/app_store.dart';

/// 刷新当前登录用户的云端缓存（增量/全量拉取，市集不在此列）。
Future<void> runSyncDialog(BuildContext context, AppStore store) async {
  final progress = ValueNotifier<String>('正在刷新…');
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      title: const Text('刷新数据'),
      content: SizedBox(
        width: 280,
        child: ValueListenableBuilder<String>(
          valueListenable: progress,
          builder: (_, msg, __) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 16),
                Text(msg, style: const TextStyle(fontSize: 15)),
              ],
            );
          },
        ),
      ),
    ),
  );
  Object? err;
  try {
    final r = await store.refreshMyCache(
      onProgress: (m) => progress.value = m,
    );
    if (!r.ok) err = r.error ?? '刷新失败';
  } catch (e) {
    err = e;
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  progress.dispose();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(err != null ? '刷新失败：$err' : '已刷新为我的最新云端数据'),
      duration: const Duration(seconds: 3),
    ),
  );
}
