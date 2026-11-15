import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent/agent_settings.dart';
import '../auth/auth_gate.dart';
import '../state/app_store.dart';
import '../update/app_update_banner.dart';
import 'auth_page.dart';
import 'calendar_page.dart';
import 'chat_page.dart';
import 'contact_feedback_page.dart';
import 'mine_settings_page.dart';
import 'note_editor_page.dart';
import 'reminder_inbox_page.dart';
import 'rooms_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;
  DateTime? _lastResumePull;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AgentSettings.instance.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;
    final store = context.read<AppStore>();
    if (!store.isLandlord) return;
    final now = DateTime.now();
    if (_lastResumePull != null &&
        now.difference(_lastResumePull!) < const Duration(seconds: 8)) {
      return;
    }
    _lastResumePull = now;
    // ignore: unawaited_futures
    store.refreshMyCache();
  }

  Future<void> _onAsAction() async {
    final store = context.read<AppStore>();
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Text('作为', style: Theme.of(ctx).textTheme.titleMedium),
              const Divider(height: 16),
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: const Text('新笔记'),
                onTap: () => Navigator.pop(ctx, 'note'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: const Text('找 AI'),
                onTap: () => Navigator.pop(ctx, 'ai'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (!mounted || choice == null) return;

    if (choice == 'note') {
      final ok = store.isLandlord || await requireLandlord(context);
      if (!ok || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const NoteEditorPage()),
      );
    } else if (choice == 'ai') {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ChatPage()),
      );
    }
  }

  Future<void> _onOtherAction() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Text('其他', style: Theme.of(ctx).textTheme.titleMedium),
              const Divider(height: 16),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('设置'),
                onTap: () => Navigator.pop(ctx, 'settings'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.support_agent_outlined),
                title: const Text('联系与反馈'),
                onTap: () => Navigator.pop(ctx, 'support'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (!mounted || choice == null) return;
    if (choice == 'settings') {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const MineSettingsPage()),
      );
    } else if (choice == 'support') {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ContactFeedbackPage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final landlord = store.isLandlord;

    // 游客：求索；房东：醍醐 / 光阴 / 求索
    // 「作为」「其他」不占 IndexedStack，点开弹窗
    final titles = landlord
        ? const ['醍醐', '光阴', '求索']
        : const ['求索'];
    final pages = landlord
        ? const <Widget>[
            ReminderInboxPage(),
            CalendarPage(),
            RoomsPage(),
          ]
        : const <Widget>[
            RoomsPage(),
          ];
    final asIndex = pages.length;
    final otherIndex = pages.length + 1;
    final destinations = landlord
        ? const [
            NavigationDestination(
              icon: Icon(Icons.notifications_none),
              selectedIcon: Icon(Icons.notifications),
              label: '醍醐',
            ),
            NavigationDestination(
              icon: Icon(Icons.calendar_month_outlined),
              selectedIcon: Icon(Icons.calendar_month),
              label: '光阴',
            ),
            NavigationDestination(
              icon: Icon(Icons.explore_outlined),
              selectedIcon: Icon(Icons.explore),
              label: '求索',
            ),
            NavigationDestination(
              icon: Icon(Icons.edit_outlined),
              selectedIcon: Icon(Icons.edit),
              label: '作为',
            ),
            NavigationDestination(
              icon: Icon(Icons.more_horiz),
              selectedIcon: Icon(Icons.more_horiz),
              label: '其他',
            ),
          ]
        : const [
            NavigationDestination(
              icon: Icon(Icons.explore_outlined),
              selectedIcon: Icon(Icons.explore),
              label: '求索',
            ),
            NavigationDestination(
              icon: Icon(Icons.edit_outlined),
              selectedIcon: Icon(Icons.edit),
              label: '作为',
            ),
            NavigationDestination(
              icon: Icon(Icons.more_horiz),
              selectedIcon: Icon(Icons.more_horiz),
              label: '其他',
            ),
          ];

    if (_index >= pages.length) {
      _index = 0;
    }

    final seekIndex = landlord ? 2 : 0;
    final onSeek = _index == seekIndex;

    return Scaffold(
      appBar: onSeek
          ? null
          : AppBar(
              title: Text(titles[_index]),
              actions: [
                if (!landlord)
                  TextButton(
                    onPressed: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const AuthPage()),
                      );
                    },
                    child: const Text('登录/注册'),
                  )
                else
                  IconButton(
                    tooltip: '检查更新',
                    onPressed: () => runManualUpdateCheck(context),
                    icon: const Icon(Icons.system_update_alt, size: 20),
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
        onDestinationSelected: (i) {
          if (i == asIndex) {
            _onAsAction();
            return;
          }
          if (i == otherIndex) {
            _onOtherAction();
            return;
          }
          setState(() => _index = i);
        },
        destinations: destinations,
      ),
    );
  }
}

