import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../reminders/reminder_service.dart';
import '../state/app_store.dart';
import 'format.dart';
import 'home_page.dart';
import 'reminder_settings_page.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late DateTime _month;
  late DateTime _selected;

  @override
  void initState() {
    super.initState();
    final today = dateOnly(DateTime.now());
    _month = DateTime(today.year, today.month);
    _selected = today;
  }

  Map<DateTime, List<DueItem>> _byDay(List<DueItem> pending) {
    final map = <DateTime, List<DueItem>>{};
    for (final item in pending) {
      final key = dateOnly(item.period.dueDate);
      map.putIfAbsent(key, () => []).add(item);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final reminders = ReminderService.instance;
    final byDay = _byDay(store.pending);
    final selectedItems = byDay[_selected] ?? const <DueItem>[];
    final today = dateOnly(DateTime.now());

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => setState(() {
                _month = DateTime(_month.year, _month.month - 1);
              }),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                '${_month.year}年${_month.month}月',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              onPressed: () => setState(() {
                _month = DateTime(_month.year, _month.month + 1);
              }),
              icon: const Icon(Icons.chevron_right),
            ),
            IconButton(
              tooltip: '闹钟设置',
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ReminderSettingsPage(),
                  ),
                );
                if (mounted) await store.reload();
              },
              icon: const Icon(Icons.alarm),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '点日期看当天应收。提醒只在本 App 内管理，不同步系统日历。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        _MonthGrid(
          month: _month,
          selected: _selected,
          today: today,
          byDay: byDay,
          onSelect: (d) => setState(() => _selected = d),
        ),
        const SizedBox(height: 16),
        Text(
          '${md(_selected)} 的应收',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (selectedItems.isEmpty)
          Text(
            _selected.isBefore(today)
                ? '这一天没有未收账期（或已记收款）。'
                : '这一天暂时没有应收。',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          ...selectedItems.map((e) => DueTile(item: e)),
        const SizedBox(height: 20),
        Row(
          children: [
            Text('已排闹钟', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            if (!reminders.exactAlarmAllowed)
              TextButton(
                onPressed: () => _showExactHint(context),
                child: const Text('需精确闹钟权限'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          reminders.settings.enabled
              ? '每天 ${reminders.settings.hour.toString().padLeft(2, '0')}:00 · '
                  '提前 ${reminders.settings.advanceDays} 天 + 当天 + 逾期续催'
              : '闹钟已关闭（可在右上角闹钟图标里打开）',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (reminders.scheduled.isEmpty)
          Text(
            '暂无未来闹钟。登记租约并保持闹钟开启后会自动排。',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          ...reminders.scheduled.take(12).map((a) {
            return ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.alarm),
              title: Text(a.title),
              subtitle: Text(
                '${ymd(a.when)} ${a.when.hour.toString().padLeft(2, '0')}:'
                '${a.when.minute.toString().padLeft(2, '0')} · ${a.roomLabel}',
              ),
            );
          }),
      ],
    );
  }

  void _showExactHint(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('打开精确闹钟'),
        content: const Text(
          '小米/Android 12+ 可能禁止精确闹钟，导致收租提醒延迟。\n'
          '请到系统设置 → 应用 → 缘初 → 闹钟与提醒（或「使用精确闹钟」）允许。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.selected,
    required this.today,
    required this.byDay,
    required this.onSelect,
  });

  final DateTime month;
  final DateTime selected;
  final DateTime today;
  final Map<DateTime, List<DueItem>> byDay;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month, 1);
    // Monday-based week: DateTime.weekday Mon=1 ... Sun=7
    final lead = first.weekday - 1;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final cells = lead + daysInMonth;
    final rows = ((cells + 6) ~/ 7);

    final scheme = Theme.of(context).colorScheme;
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
      child: Column(
        children: [
          Row(
            children: weekdays
                .map(
                  (w) => Expanded(
                    child: Center(
                      child: Text(
                        w,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 6),
          for (var r = 0; r < rows; r++)
            Row(
              children: List.generate(7, (c) {
                final index = r * 7 + c;
                final dayNum = index - lead + 1;
                if (dayNum < 1 || dayNum > daysInMonth) {
                  return const Expanded(child: SizedBox(height: 44));
                }
                final date = DateTime(month.year, month.month, dayNum);
                final items = byDay[date] ?? const <DueItem>[];
                final isSelected = date == selected;
                final isToday = date == today;
                final hasDue = items.isNotEmpty;
                final isOverdue = hasDue && date.isBefore(today);

                return Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onSelect(date),
                    child: Container(
                      height: 48,
                      margin: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? scheme.primaryContainer
                            : (isToday
                                ? scheme.surfaceVariant.withOpacity(0.6)
                                : null),
                        borderRadius: BorderRadius.circular(8),
                        border: isToday && !isSelected
                            ? Border.all(color: scheme.primary)
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '$dayNum',
                            style: TextStyle(
                              fontWeight:
                                  isToday ? FontWeight.w700 : FontWeight.w500,
                              color: isOverdue ? Colors.red.shade700 : null,
                            ),
                          ),
                          const SizedBox(height: 2),
                          SizedBox(
                            height: 6,
                            child: hasDue
                                ? Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: List.generate(
                                      items.length > 3 ? 3 : items.length,
                                      (_) => Container(
                                        width: 5,
                                        height: 5,
                                        margin: const EdgeInsets.symmetric(
                                          horizontal: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: isOverdue
                                              ? Colors.red.shade700
                                              : scheme.primary,
                                        ),
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
        ],
      ),
    );
  }
}
