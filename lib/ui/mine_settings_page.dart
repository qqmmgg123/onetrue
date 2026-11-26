import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_store.dart';
import '../update/app_update_banner.dart';
import 'auth_page.dart';
import 'busy.dart';
import 'sync_dialog.dart';

/// 「其他 → 设置」：账号与本机偏好（原求索「我的 → 设置」）。
class MineSettingsPage extends StatelessWidget {
  const MineSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final email = store.user?.emailMasked ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('账号设置')),
      body: ListView(
        children: [
          if (email.isNotEmpty) ...[
            ListTile(
              title: const Text('邮箱'),
              subtitle: Text(email),
            ),
            const Divider(height: 1),
          ],
          ListTile(
            title: const Text('检查更新'),
            onTap: () => runManualUpdateCheck(context),
          ),
          const Divider(height: 1),
          if (store.isLandlord) ...[
            ListTile(
              title: const Text('刷新数据'),
              subtitle: const Text('拉取我的云端最新数据'),
              onTap: () => runSyncDialog(context, store),
            ),
            const Divider(height: 1),
            ListTile(
              title: const Text('8 秒后测试闹钟'),
              onTap: () async {
                try {
                  await store.testNotification();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          '已预约约 8 秒后提醒。请保持屏幕亮着、不要杀后台；'
                          '若仍无声，到系统设置打开本 App 的通知与「闹钟和提醒」权限。',
                        ),
                        duration: Duration(seconds: 6),
                      ),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('$e')),
                    );
                  }
                }
              },
            ),
            const Divider(height: 1),
            ListTile(
              title: const Text('退出登录'),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('退出登录？'),
                    content: const Text('将清空本机业务缓存并回到游客模式。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('退出'),
                      ),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  await runBusy(
                    context,
                    message: '正在退出…',
                    task: () => store.logout(),
                  );
                  if (context.mounted) Navigator.of(context).pop();
                }
              },
            ),
          ] else
            ListTile(
              title: const Text('登录 / 注册'),
              subtitle: const Text('登录后可同步与上架'),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AuthPage()),
                );
              },
            ),
        ],
      ),
    );
  }
}
