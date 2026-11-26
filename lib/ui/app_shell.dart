import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent/agent_settings.dart';
import '../state/app_store.dart';
import '../update/app_update_banner.dart';
import 'auth_page.dart';
import 'calendar_page.dart';
import 'contact_feedback_page.dart';
import 'l2_side_drawer.dart';
import 'memo_list_page.dart';
import 'mine_settings_page.dart';
import 'notes_home_page.dart';
import 'rooms_page.dart';

/// 一级：笔记 → 备忘 → 日常 → 阅读 → 其他
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  static const _kNotes = 0;
  static const _kMemo = 1;
  static const _kCal = 2;
  static const _kRead = 3;
  static const _kOther = 4;

  int _index = _kRead;
  bool? _wasGuest;
  DateTime? _lastResumePull;
  final _memoDrawerKey = GlobalKey<L2SideDrawerState>();
  final _calDrawerKey = GlobalKey<L2SideDrawerState>();

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
    if (store.isGuest) return;
    final now = DateTime.now();
    if (_lastResumePull != null &&
        now.difference(_lastResumePull!) < const Duration(seconds: 8)) {
      return;
    }
    _lastResumePull = now;
    // ignore: unawaited_futures
    store.refreshMyCache();
  }

  void _syncDefaultTab(bool isGuest) {
    if (_wasGuest == null) {
      _wasGuest = isGuest;
      _index = isGuest ? _kRead : _kNotes;
      return;
    }
    if (_wasGuest == isGuest) return;
    _wasGuest = isGuest;
    // 登录后落到笔记；退出后落到阅读
    _index = isGuest ? _kRead : _kNotes;
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
                title: const Text('账号设置'),
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
    final guest = store.isGuest;
    _syncDefaultTab(guest);

    const titles = ['笔记', '备忘', '日常', '阅读'];
    final pages = <Widget>[
      const NotesHomePage(),
      MemoListPage(drawerKey: _memoDrawerKey),
      CalendarPage(drawerKey: _calDrawerKey),
      const RoomsPage(),
    ];

    final onRead = _index == _kRead;
    final safeIndex = _index.clamp(0, pages.length - 1);
    final showL2Menu = safeIndex == _kMemo || safeIndex == _kCal;

    return Scaffold(
      appBar: onRead
          ? null
          : AppBar(
              leading: showL2Menu
                  ? IconButton(
                      tooltip: '菜单',
                      onPressed: () {
                        if (safeIndex == _kMemo) {
                          _memoDrawerKey.currentState?.toggle();
                        } else if (safeIndex == _kCal) {
                          _calDrawerKey.currentState?.toggle();
                        }
                      },
                      icon: const L2MenuIcon(),
                    )
                  : null,
              title: Text(titles[safeIndex]),
              actions: [
                if (guest)
                  TextButton(
                    onPressed: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const AuthPage()),
                      );
                    },
                    child: const Text('登录/注册'),
                  ),
              ],
            ),
      body: AppUpdateHost(
        child: IndexedStack(
          index: safeIndex,
          children: pages,
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index > _kRead ? _kRead : _index,
        onDestinationSelected: (i) {
          if (i == _kOther) {
            _onOtherAction();
            return;
          }
          setState(() => _index = i);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.edit_note_outlined),
            selectedIcon: Icon(Icons.edit_note),
            label: '笔记',
          ),
          NavigationDestination(
            icon: Icon(Icons.sticky_note_2_outlined),
            selectedIcon: Icon(Icons.sticky_note_2),
            label: '备忘',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '日常',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: '阅读',
          ),
          NavigationDestination(
            icon: Icon(Icons.more_horiz),
            selectedIcon: Icon(Icons.more_horiz),
            label: '其他',
          ),
        ],
      ),
    );
  }
}
