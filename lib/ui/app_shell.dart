import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent/agent_settings.dart';
import '../state/app_store.dart';
import '../sync/sync_service.dart';
import '../update/app_update_banner.dart';
import 'auth_page.dart';
import 'busy.dart';
import 'calendar_page.dart';
import 'chat_page.dart';
import 'home_page.dart';
import 'rooms_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    AgentSettings.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final landlord = store.isLandlord;

    // 游客：房源 / 对话；房东：应收 / 日历 / 房源 / 对话
    final titles = landlord
        ? const ['缘初', '日历', '房源', '对话']
        : const ['房源', '对话'];
    final pages = landlord
        ? const <Widget>[
            HomePage(),
            CalendarPage(),
            RoomsPage(),
            ChatPage(),
          ]
        : const <Widget>[
            RoomsPage(),
            ChatPage(),
          ];
    final destinations = landlord
        ? const [
            NavigationDestination(
              icon: Icon(Icons.event_note_outlined),
              selectedIcon: Icon(Icons.event_note),
              label: '应收',
            ),
            NavigationDestination(
              icon: Icon(Icons.calendar_month_outlined),
              selectedIcon: Icon(Icons.calendar_month),
              label: '日历',
            ),
            NavigationDestination(
              icon: Icon(Icons.apartment_outlined),
              selectedIcon: Icon(Icons.apartment),
              label: '房源',
            ),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: '对话',
            ),
          ]
        : const [
            NavigationDestination(
              icon: Icon(Icons.apartment_outlined),
              selectedIcon: Icon(Icons.apartment),
              label: '房源',
            ),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: '对话',
            ),
          ];

    if (_index >= pages.length) {
      _index = 0;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_index]),
        actions: [
          if (landlord)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Text(
                  store.user?.phoneMasked ?? '',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            )
          else
            TextButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AuthPage()),
                );
              },
              child: const Text('登录/注册'),
            ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'auth') {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AuthPage()),
                );
              } else if (value == 'logout') {
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
                if (ok == true && mounted) {
                  await runBusy(
                    context,
                    message: '正在退出…',
                    task: () => store.logout(),
                  );
                  setState(() => _index = 0);
                }
              } else if (value == 'seed') {
                await runBusy(
                  context,
                  message: '正在写入演示数据…',
                  task: () => store.seedDemo(),
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已写入演示：302 / 张三 / 本月今天到期')),
                  );
                }
              } else if (value == 'ping') {
                try {
                  await store.testNotification();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          '已预约约 8 秒后提醒。请保持屏幕亮着、不要杀后台；'
                          '若仍无声，到系统设置打开本 App 的通知与「闹钟和提醒」权限，并关掉省电限制。',
                        ),
                        duration: Duration(seconds: 6),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('$e')),
                    );
                  }
                }
              } else if (value == 'update') {
                await runManualUpdateCheck(context);
              } else if (value == 'sync') {
                await _runSync(context, store);
              }
            },
            itemBuilder: (context) {
              final items = <PopupMenuEntry<String>>[
                const PopupMenuItem(value: 'update', child: Text('检查更新')),
              ];
              if (landlord) {
                items.addAll(const [
                  PopupMenuItem(value: 'sync', child: Text('立即同步')),
                  PopupMenuItem(value: 'ping', child: Text('8 秒后测试闹钟')),
                  PopupMenuItem(value: 'seed', child: Text('填入演示数据')),
                  PopupMenuItem(value: 'logout', child: Text('退出登录')),
                ]);
              } else {
                items.add(
                  const PopupMenuItem(value: 'auth', child: Text('登录/注册')),
                );
              }
              return items;
            },
          ),
        ],
      ),
      body: AppUpdateHost(
        child: IndexedStack(
          index: _index,
          children: pages,
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: destinations,
      ),
    );
  }

  Future<void> _runSync(BuildContext context, AppStore store) async {
    final progress = ValueNotifier<String>('准备同步…');
    final log = <String>['准备同步…'];
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('正在同步'),
        content: SizedBox(
          width: 320,
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
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: Text(
                        log.join('\n'),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade700,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    SyncReport? r;
    Object? err;
    try {
      r = await store.silentSync(
        fullPull: true,
        onProgress: (m) {
          log.add(m);
          if (log.length > 40) log.removeAt(0);
          progress.value = m;
        },
      );
    } catch (e) {
      err = e;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();
    final msg = err != null
        ? '同步失败：$err'
        : r!.error == 'sync_disabled'
            ? '未开启同步：请先登录，并确认已配置 Neon'
            : r.ok
                ? '同步完成：上传 ${r.pushed} 条 · 下载 ${r.pulled} 条'
                : '同步失败：${r.error}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 5),
      ),
    );
  }
}
