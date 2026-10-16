import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent/agent_settings.dart';
import '../state/app_store.dart';
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

  static const _titles = ['收租助手', '日历', '房源', '对话'];

  @override
  void initState() {
    super.initState();
    AgentSettings.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'seed') {
                await store.seedDemo();
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
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'ping', child: Text('8 秒后测试闹钟')),
              PopupMenuItem(value: 'seed', child: Text('填入演示数据')),
            ],
          ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: const [
          HomePage(),
          CalendarPage(),
          RoomsPage(),
          ChatPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
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
        ],
      ),
    );
  }
}
