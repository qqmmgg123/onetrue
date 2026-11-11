import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../domain/note_recur.dart';
import '../reminders/reminder_service.dart';
import '../state/app_store.dart';
import 'bill_page.dart';
import 'format.dart';
import 'note_editor_page.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  static const _hourStart = 6;
  static const _hourEnd = 23;

  late DateTime _month;
  late DateTime _selected;
  /// month | three
  String _mode = 'month';
  late final PageController _monthPage;
  late final PageController _threePage;
  static const _monthBase = 120;
  static const _threeBase = 400;

  @override
  void initState() {
    super.initState();
    final today = dateOnly(DateTime.now());
    _month = DateTime(today.year, today.month);
    _selected = today;
    _monthPage = PageController(initialPage: _monthBase);
    _threePage = PageController(initialPage: _threeBase);
  }

  @override
  void dispose() {
    _monthPage.dispose();
    _threePage.dispose();
    super.dispose();
  }

  DateTime _monthAt(int page) {
    final today = dateOnly(DateTime.now());
    final base = DateTime(today.year, today.month);
    return DateTime(base.year, base.month + (page - _monthBase));
  }

  DateTime _threeAnchorAt(int page) {
    final today = dateOnly(DateTime.now());
    // 每页以中间日为锚；页 0 对应今天为中间日
    return today.add(Duration(days: (page - _threeBase) * 3));
  }

  List<DateTime> _threeDays(DateTime mid) => [
        mid.subtract(const Duration(days: 1)),
        mid,
        mid.add(const Duration(days: 1)),
      ];

  Map<DateTime, List<({Note note, DateTime at})>> _notesWindow(
    List<Note> notes, {
    required DateTime from,
    required DateTime to,
  }) {
    return notesGroupedByDay(notes, from: from, to: to);
  }

  Future<void> _openNewSchedule(DateTime at, {String kind = kNoteKindSchedule}) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(
          initialKind: kind,
          initialScheduleAt: at,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final reminders = ReminderService.instance;
    final today = dateOnly(DateTime.now());
    final monthFrom = DateTime(_month.year, _month.month, 1);
    final monthTo = DateTime(_month.year, _month.month + 1, 0, 23, 59, 59);
    final threeMid = _selected;
    final threeDays = _threeDays(threeMid);
    final threeFrom = DateTime(
      threeDays.first.year,
      threeDays.first.month,
      threeDays.first.day,
    );
    final threeTo = DateTime(
      threeDays.last.year,
      threeDays.last.month,
      threeDays.last.day,
      23,
      59,
      59,
    );
    final notesByDay = _notesWindow(
      store.notes,
      from: _mode == 'month'
          ? monthFrom.subtract(const Duration(days: 7))
          : threeFrom,
      to: _mode == 'month' ? monthTo.add(const Duration(days: 7)) : threeTo,
    );
    final selectedNotes = notesByDay[_selected] ?? const [];
    final noteAlarms =
        reminders.scheduled.where((a) => a.id >= 800000).toList();
    final dayDues = store.pending
        .where((e) => dateOnly(e.period.dueDate) == _selected)
        .toList();
    final monthDues = store.pending.where((e) {
      final d = e.period.dueDate;
      return d.year == _month.year && d.month == _month.month;
    }).toList();
    final rentSectionItems =
        dayDues.isNotEmpty ? dayDues : (_mode == 'month' ? monthDues : dayDues);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Text(
          _mode == 'month'
              ? '${_month.year}年${_month.month}月'
              : '${ymd(threeDays.first)} – ${ymd(threeDays.last)}',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'month', label: Text('月历')),
            ButtonSegment(value: 'three', label: Text('三日')),
          ],
          selected: {_mode},
          onSelectionChanged: (s) {
            final next = s.first;
            setState(() => _mode = next);
            if (next == 'three') {
              final today = dateOnly(DateTime.now());
              final delta = dateOnly(_selected).difference(today).inDays;
              final page = _threeBase + (delta / 3).round();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_threePage.hasClients) {
                  _threePage.jumpToPage(page);
                }
              });
            } else {
              final today = dateOnly(DateTime.now());
              final base = DateTime(today.year, today.month);
              final page = _monthBase +
                  (_month.year - base.year) * 12 +
                  (_month.month - base.month);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_monthPage.hasClients) {
                  _monthPage.jumpToPage(page);
                }
              });
            }
          },
        ),
        const SizedBox(height: 8),
        Text(
          _mode == 'month'
              ? '左右滑换月；点日期看当天备忘日程。'
              : '左右滑换三日；点空白时段新建日程，长按建备忘。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (_mode == 'month')
          SizedBox(
            height: 320,
            child: PageView.builder(
              controller: _monthPage,
              onPageChanged: (page) {
                final m = _monthAt(page);
                setState(() {
                  _month = m;
                  if (_selected.month != m.month || _selected.year != m.year) {
                    final day = _selected.day.clamp(
                      1,
                      DateTime(m.year, m.month + 1, 0).day,
                    );
                    _selected = DateTime(m.year, m.month, day);
                  }
                });
              },
              itemBuilder: (context, page) {
                final m = _monthAt(page);
                final from = DateTime(m.year, m.month, 1)
                    .subtract(const Duration(days: 7));
                final to = DateTime(m.year, m.month + 1, 0, 23, 59, 59)
                    .add(const Duration(days: 7));
                final pageNotes = _notesWindow(
                  store.notes,
                  from: from,
                  to: to,
                );
                return _MonthGrid(
                  month: m,
                  selected: _selected,
                  today: today,
                  notesByDay: pageNotes,
                  onSelect: (d) => setState(() {
                    _selected = d;
                    _month = DateTime(d.year, d.month);
                  }),
                );
              },
            ),
          )
        else
          SizedBox(
            height: 420,
            child: PageView.builder(
              controller: _threePage,
              onPageChanged: (page) {
                final mid = _threeAnchorAt(page);
                setState(() => _selected = mid);
              },
              itemBuilder: (context, page) {
                final mid = _threeAnchorAt(page);
                final days = _threeDays(mid);
                final from = DateTime(
                  days.first.year,
                  days.first.month,
                  days.first.day,
                );
                final to = DateTime(
                  days.last.year,
                  days.last.month,
                  days.last.day,
                  23,
                  59,
                  59,
                );
                final pageNotes = _notesWindow(
                  store.notes,
                  from: from,
                  to: to,
                );
                return _ThreeDayView(
                  days: days,
                  selected: _selected,
                  today: today,
                  hourStart: _hourStart,
                  hourEnd: _hourEnd,
                  notesByDay: pageNotes,
                  onSelectDay: (d) => setState(() => _selected = d),
                  onTapSlot: (at) => _openNewSchedule(at),
                  onLongPressSlot: (at) =>
                      _openNewSchedule(at, kind: kNoteKindMemo),
                  onTapNote: (n) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => NoteEditorPage(noteId: n.id),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        const SizedBox(height: 16),
        Text(
          '${md(_selected)} 的备忘 / 日程',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (selectedNotes.isEmpty)
          Text(
            '这一天没有备忘或日程。',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          ...selectedNotes.map(
            (e) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                e.note.kind == kNoteKindSchedule
                    ? Icons.event_outlined
                    : Icons.notifications_none,
              ),
              title: Text(e.note.displayTitle),
              subtitle: Text(
                '${e.note.kindLabel} · '
                '${e.at.hour.toString().padLeft(2, '0')}:'
                '${e.at.minute.toString().padLeft(2, '0')}'
                '${isRecurringFreq(e.note.recurFreq) ? ' · 重复' : ''}',
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => NoteEditorPage(noteId: e.note.id),
                  ),
                );
              },
            ),
          ),
        if (rentSectionItems.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            dayDues.isNotEmpty
                ? '${md(_selected)} 的应收'
                : '${_month.month} 月应收（未收）',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ...rentSectionItems.take(8).map(
            (e) => ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.payments_outlined),
              title: Text(
                '${e.roomLabel} · ${formatYuan(e.period.amount)}',
              ),
              subtitle: Text(
                '${ymdCn(e.period.dueDate)} · ${e.propertyName}',
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BillPage(periodId: e.period.id),
                  ),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Text('已排日程提醒', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            if (!reminders.exactAlarmAllowed)
              TextButton(
                onPressed: () => _showExactHint(context),
                child: const Text('需精确闹钟权限'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (noteAlarms.isEmpty)
          Text(
            '暂无未来日程提醒。在备忘里设好时间后会自动排。',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          ...noteAlarms.take(12).map((a) {
            return ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.alarm),
              title: Text(a.title),
              subtitle: Text(
                '${ymd(a.when)} ${a.when.hour.toString().padLeft(2, '0')}:'
                '${a.when.minute.toString().padLeft(2, '0')}'
                '${a.roomLabel.isEmpty ? '' : ' · ${a.roomLabel}'}',
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
          '小米/Android 12+ 可能禁止精确闹钟，导致日程提醒延迟。\n'
          '请到系统设置 → 应用 → 醍醐 → 闹钟与提醒（或「使用精确闹钟」）允许。',
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
    required this.notesByDay,
    required this.onSelect,
  });

  final DateTime month;
  final DateTime selected;
  final DateTime today;
  final Map<DateTime, List<({Note note, DateTime at})>> notesByDay;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month, 1);
    final lead = first.weekday - 1;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final cells = lead + daysInMonth;
    final rows = ((cells + 6) ~/ 7);

    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];

    return Container(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFFE5E5E5)),
          bottom: BorderSide(color: Color(0xFFE5E5E5)),
        ),
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
                final dayNotes = notesByDay[date] ?? const [];
                final isSelected = date == selected;
                final isToday = date == today;
                final hasNote = dayNotes.isNotEmpty;

                return Expanded(
                  child: InkWell(
                    onTap: () => onSelect(date),
                    child: Container(
                      height: 48,
                      margin: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFFEEEEEE)
                            : (isToday ? const Color(0xFFF5F5F5) : null),
                        border: isToday && !isSelected
                            ? Border.all(color: const Color(0xFF111111))
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '$dayNum',
                            style: TextStyle(
                              fontWeight: isToday || isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 2),
                          SizedBox(
                            height: 6,
                            child: hasNote
                                ? Center(
                                    child: Container(
                                      width: 5,
                                      height: 5,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Color(0xFF888888),
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

class _ThreeDayView extends StatelessWidget {
  const _ThreeDayView({
    required this.days,
    required this.selected,
    required this.today,
    required this.hourStart,
    required this.hourEnd,
    required this.notesByDay,
    required this.onSelectDay,
    required this.onTapSlot,
    required this.onLongPressSlot,
    required this.onTapNote,
  });

  final List<DateTime> days;
  final DateTime selected;
  final DateTime today;
  final int hourStart;
  final int hourEnd;
  final Map<DateTime, List<({Note note, DateTime at})>> notesByDay;
  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<DateTime> onTapSlot;
  final ValueChanged<DateTime> onLongPressSlot;
  final ValueChanged<Note> onTapNote;

  static const _rowH = 48.0;

  @override
  Widget build(BuildContext context) {
    final hours = hourEnd - hourStart + 1;
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFFE5E5E5)),
          bottom: BorderSide(color: Color(0xFFE5E5E5)),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 40),
              for (final d in days)
                Expanded(
                  child: InkWell(
                    onTap: () => onSelectDay(d),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      color: dateOnly(d) == dateOnly(selected)
                          ? const Color(0xFFEEEEEE)
                          : null,
                      child: Column(
                        children: [
                          Text(
                            const ['一', '二', '三', '四', '五', '六', '日']
                                [d.weekday - 1],
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          Text(
                            '${d.day}',
                            style: TextStyle(
                              fontWeight: dateOnly(d) == today
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              child: SizedBox(
                height: hours * _rowH,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 40,
                      child: Column(
                        children: [
                          for (var h = hourStart; h <= hourEnd; h++)
                            SizedBox(
                              height: _rowH,
                              child: Align(
                                alignment: Alignment.topCenter,
                                child: Text(
                                  h.toString().padLeft(2, '0'),
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    for (final d in days)
                      Expanded(
                        child: _DayColumn(
                          day: d,
                          hourStart: hourStart,
                          hourEnd: hourEnd,
                          rowH: _rowH,
                          events: notesByDay[dateOnly(d)] ?? const [],
                          onTapSlot: onTapSlot,
                          onLongPressSlot: onLongPressSlot,
                          onTapNote: onTapNote,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.hourStart,
    required this.hourEnd,
    required this.rowH,
    required this.events,
    required this.onTapSlot,
    required this.onLongPressSlot,
    required this.onTapNote,
  });

  final DateTime day;
  final int hourStart;
  final int hourEnd;
  final double rowH;
  final List<({Note note, DateTime at})> events;
  final ValueChanged<DateTime> onTapSlot;
  final ValueChanged<DateTime> onLongPressSlot;
  final ValueChanged<Note> onTapNote;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
          children: [
            for (var h = hourStart; h <= hourEnd; h++)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onTapSlot(
                  DateTime(day.year, day.month, day.day, h),
                ),
                onLongPress: () => onLongPressSlot(
                  DateTime(day.year, day.month, day.day, h),
                ),
                child: Container(
                  height: rowH,
                  decoration: const BoxDecoration(
                    border: Border(
                      top: BorderSide(color: Color(0xFFEEEEEE)),
                      left: BorderSide(color: Color(0xFFEEEEEE)),
                    ),
                  ),
                ),
              ),
          ],
        ),
        for (final e in events)
          if (e.at.hour >= hourStart && e.at.hour <= hourEnd)
            Positioned(
              top: (e.at.hour - hourStart) * rowH +
                  (e.at.minute / 60.0) * rowH,
              left: 2,
              right: 2,
              height: rowH - 4,
              child: Material(
                color: const Color(0xFF111111),
                child: InkWell(
                  onTap: () => onTapNote(e.note),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Text(
                      e.note.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}
