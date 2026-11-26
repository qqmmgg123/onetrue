import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/calendar_layout.dart';
import '../domain/models.dart';
import '../domain/note_recur.dart';
import '../state/app_store.dart';
import 'auth_page.dart';
import 'busy.dart';
import 'format.dart';
import 'l2_side_drawer.dart';
import 'note_editor_page.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key, this.drawerKey});

  final GlobalKey<L2SideDrawerState>? drawerKey;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  static const _hourStart = 6;
  static const _hourEnd = 23;

  late DateTime _selected;
  late final PageController _threePage;
  static const _threeBase = 400;

  @override
  void initState() {
    super.initState();
    final today = dateOnly(DateTime.now());
    _selected = today;
    _threePage = PageController(initialPage: _threeBase);
  }

  @override
  void dispose() {
    _threePage.dispose();
    super.dispose();
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

  Future<void> _openAuth() {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AuthPage()),
    );
  }

  Future<void> _openNewSchedule(DateTime at, {String kind = kNoteKindSchedule}) {
    final store = context.read<AppStore>();
    if (store.isGuest) {
      return _openAuth();
    }
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(
          initialKind: kind,
          initialScheduleAt: at,
        ),
      ),
    );
  }

  /// 拖到新时间：按「该实例」相对位移平移整条日程的 scheduleAt（重复系列一并移动）。
  /// 失败抛错，供三日视图回滚乐观位置。
  Future<void> _moveSchedule({
    required Note note,
    required DateTime fromOccurrence,
    required DateTime toAt,
  }) async {
    final store = context.read<AppStore>();
    if (store.isGuest) {
      await _openAuth();
      throw StateError('需要登录');
    }
    final base = note.scheduleAt;
    if (base == null) return;
    final localBase = base.isUtc ? base.toLocal() : base;
    if (toAt.isAtSameMomentAs(fromOccurrence)) return;
    final newSchedule = localBase.add(toAt.difference(fromOccurrence));
    final newRemind = remindAtFromOffset(newSchedule, note.remindOffsetMin);
    if (!mounted) return;
    await runBusy(
      context,
      message: '时间重新设置中…',
      task: () async {
        await store.saveNote(
          id: note.id,
          scheduleAt: newSchedule,
          remindAt: newRemind,
          clearRemindAt: newRemind == null,
        );
      },
    );
  }

  void _selectDay(DateTime day) {
    final d = dateOnly(day);
    setState(() => _selected = d);
    // 中间日 = today + (page - base)*3
    final today = dateOnly(DateTime.now());
    final targetPage =
        _threeBase + ((d.difference(today).inDays) / 3).round();
    if (_threePage.hasClients) {
      _threePage.animateToPage(
        targetPage,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final today = dateOnly(DateTime.now());
    final threeDays = _threeDays(_selected);
    final monthFrom = DateTime(_selected.year, _selected.month - 1, 1);
    final monthTo = DateTime(_selected.year, _selected.month + 2, 0, 23, 59, 59);
    final sideNotes = _notesWindow(
      store.notes,
      from: monthFrom,
      to: monthTo,
    );
    final selectedNotes = sideNotes[_selected] ?? const [];

    return L2SideDrawer(
      key: widget.drawerKey,
      enableEdgeSwipe: false,
      drawer: _CalendarSidePanel(
        selected: _selected,
        today: today,
        notesByDay: sideNotes,
        dayNotes: selectedNotes,
        onSelectDay: (d) {
          _selectDay(d);
          widget.drawerKey?.currentState?.close();
        },
        onOpenNote: (n) {
          widget.drawerKey?.currentState?.close();
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => NoteEditorPage(noteId: n.id)),
          );
        },
        onArrange: () {
          widget.drawerKey?.currentState?.close();
          final at = DateTime(
            _selected.year,
            _selected.month,
            _selected.day,
            9,
          );
          _openNewSchedule(at);
        },
      ),
      child: RefreshIndicator(
        onRefresh: () async {
          if (store.isGuest) return;
          await store.refreshMyCache();
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                '${ymd(threeDays.first)} – ${ymd(threeDays.last)}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                '左右滑换三日；点空白叠卡；长按卡片拖到其他时间。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Expanded(
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
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: _ThreeDayView(
                      days: days,
                      selected: _selected,
                      today: today,
                      hourStart: _hourStart,
                      hourEnd: _hourEnd,
                      notesByDay: pageNotes,
                      onSelectDay: (d) => setState(() => _selected = d),
                      onTapSlot: (at) => _openNewSchedule(at),
                      onLongPressSlot: (at) => _openNewSchedule(at),
                      onTapNote: (n) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => NoteEditorPage(noteId: n.id),
                          ),
                        );
                      },
                      onMoveNote: (note, from, to) => _moveSchedule(
                        note: note,
                        fromOccurrence: from,
                        toAt: to,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarSidePanel extends StatefulWidget {
  const _CalendarSidePanel({
    required this.selected,
    required this.today,
    required this.notesByDay,
    required this.dayNotes,
    required this.onSelectDay,
    required this.onOpenNote,
    required this.onArrange,
  });

  final DateTime selected;
  final DateTime today;
  final Map<DateTime, List<({Note note, DateTime at})>> notesByDay;
  final List<({Note note, DateTime at})> dayNotes;
  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<Note> onOpenNote;
  final VoidCallback onArrange;

  @override
  State<_CalendarSidePanel> createState() => _CalendarSidePanelState();
}

class _CalendarSidePanelState extends State<_CalendarSidePanel> {
  late DateTime _month;

  static const _wd = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  void initState() {
    super.initState();
    _month = DateTime(widget.selected.year, widget.selected.month, 1);
  }

  @override
  void didUpdateWidget(covariant _CalendarSidePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected.year != widget.selected.year ||
        oldWidget.selected.month != widget.selected.month) {
      _month = DateTime(widget.selected.year, widget.selected.month, 1);
    }
  }

  List<DateTime> get _cells {
    final first = _month;
    final pad = (first.weekday + 6) % 7;
    final start = first.subtract(Duration(days: pad));
    return List.generate(42, (i) => dateOnly(start.add(Duration(days: i))));
  }

  @override
  Widget build(BuildContext context) {
    final cells = _cells;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
          child: Row(
            children: [
              IconButton(
                tooltip: '上一年',
                onPressed: () => setState(
                  () => _month = DateTime(_month.year - 1, _month.month, 1),
                ),
                icon: const Icon(Icons.keyboard_double_arrow_left, size: 18),
              ),
              IconButton(
                tooltip: '上一月',
                onPressed: () => setState(
                  () => _month = DateTime(_month.year, _month.month - 1, 1),
                ),
                icon: const Icon(Icons.chevron_left, size: 20),
              ),
              Expanded(
                child: Text(
                  '${_month.year}年${_month.month}月',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: '下一月',
                onPressed: () => setState(
                  () => _month = DateTime(_month.year, _month.month + 1, 1),
                ),
                icon: const Icon(Icons.chevron_right, size: 20),
              ),
              IconButton(
                tooltip: '下一年',
                onPressed: () => setState(
                  () => _month = DateTime(_month.year + 1, _month.month, 1),
                ),
                icon: const Icon(Icons.keyboard_double_arrow_right, size: 18),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: _wd
                .map(
                  (w) => Expanded(
                    child: Center(
                      child: Text(
                        w,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF6B6B6B),
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 7,
            children: [
              for (final d in cells)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => widget.onSelectDay(d),
                  child: Container(
                    margin: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dateOnly(d) == dateOnly(widget.selected)
                          ? const Color(0xFF1A1A1A)
                          : null,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${d.day}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: dateOnly(d) == dateOnly(widget.today)
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: dateOnly(d) == dateOnly(widget.selected)
                                ? Colors.white
                                : (d.month != _month.month
                                    ? const Color(0xFFC4C4C4)
                                    : const Color(0xFF1A1A1A)),
                          ),
                        ),
                        if ((widget.notesByDay[d] ?? const []).isNotEmpty)
                          Container(
                            width: 3,
                            height: 3,
                            margin: const EdgeInsets.only(top: 1),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: dateOnly(d) == dateOnly(widget.selected)
                                  ? Colors.white70
                                  : const Color(0xFF1A1A1A),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.selected.month}月${widget.selected.day}日 · 当天日常',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6B6B6B),
                  ),
                ),
              ),
              TextButton(
                onPressed: widget.onArrange,
                child: const Text('＋ 安排'),
              ),
            ],
          ),
        ),
        Expanded(
          child: widget.dayNotes.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text(
                    '这一天暂无日常',
                    style: TextStyle(color: Color(0xFF6B6B6B), fontSize: 13),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                  itemCount: widget.dayNotes.length,
                  itemBuilder: (_, i) {
                    final e = widget.dayNotes[i];
                    final hm =
                        '${e.at.hour.toString().padLeft(2, '0')}:${e.at.minute.toString().padLeft(2, '0')}';
                    return ListTile(
                      dense: true,
                      title: Text(e.note.displayTitle),
                      subtitle: Text(hm),
                      onTap: () => widget.onOpenNote(e.note),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ThreeDayView extends StatefulWidget {
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
    required this.onMoveNote,
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
  final Future<void> Function(Note note, DateTime from, DateTime to) onMoveNote;

  static const _rowH = 48.0;

  @override
  State<_ThreeDayView> createState() => _ThreeDayViewState();
}

class _CalDragPreview {
  const _CalDragPreview({
    required this.note,
    required this.from,
    required this.day,
    required this.startMin,
    required this.durationMin,
  });

  final Note note;
  final DateTime from;
  final DateTime day;
  final int startMin;
  final int durationMin;
}

class _ThreeDayViewState extends State<_ThreeDayView> {
  late final List<GlobalKey> _colKeys;
  final Map<String, DateTime> _optimistic = {};
  _CalDragPreview? _preview;
  String? _draggingKey;
  int? _lastPreviewDayIndex;
  int? _lastPreviewStartMin;

  @override
  void initState() {
    super.initState();
    _colKeys = List.generate(widget.days.length, (_) => GlobalKey());
  }

  @override
  void didUpdateWidget(covariant _ThreeDayView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.days.length != widget.days.length) {
      _colKeys
        ..clear()
        ..addAll(List.generate(widget.days.length, (_) => GlobalKey()));
    }
  }

  Map<DateTime, List<({Note note, DateTime at})>> get _effectiveByDay {
    if (_optimistic.isEmpty) return widget.notesByDay;
    final next = <DateTime, List<({Note note, DateTime at})>>{
      for (final e in widget.notesByDay.entries) e.key: List.of(e.value),
    };
    for (final entry in _optimistic.entries) {
      final parts = entry.key.split(':');
      if (parts.length != 2) continue;
      final noteId = int.tryParse(parts[0]);
      final fromTs = int.tryParse(parts[1]);
      if (noteId == null || fromTs == null) continue;
      final toAt = entry.value;
      ({Note note, DateTime at})? moved;
      for (final list in next.values) {
        final i = list.indexWhere(
          (e) =>
              e.note.id == noteId && e.at.millisecondsSinceEpoch == fromTs,
        );
        if (i >= 0) {
          moved = list.removeAt(i);
          break;
        }
      }
      if (moved == null) continue;
      final day = dateOnly(toAt);
      next.putIfAbsent(day, () => <({Note note, DateTime at})>[]);
      next[day]!.add((note: moved.note, at: toAt));
      next[day]!.sort((a, b) => a.at.compareTo(b.at));
    }
    return next;
  }

  DateTime? _snapFromGlobal(Offset global) {
    int? bestIdx;
    double bestDist = double.infinity;
    Offset? bestLocal;
    for (var i = 0; i < widget.days.length; i++) {
      final box =
          _colKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final local = box.globalToLocal(global);
      if (local.dx >= 0 && local.dx < box.size.width) {
        final y = local.dy.clamp(0.0, box.size.height);
        return calendarTimeFromY(
          day: widget.days[i],
          localY: y,
          rowH: _ThreeDayView._rowH,
          hourStart: widget.hourStart,
          hourEnd: widget.hourEnd,
        );
      }
      final mid = box.localToGlobal(Offset(box.size.width / 2, 0)).dx;
      final dist = (global.dx - mid).abs();
      if (dist < bestDist) {
        bestDist = dist;
        bestIdx = i;
        bestLocal = Offset(
          box.size.width / 2,
          local.dy.clamp(0.0, box.size.height),
        );
      }
    }
    if (bestIdx == null || bestLocal == null) return null;
    return calendarTimeFromY(
      day: widget.days[bestIdx],
      localY: bestLocal.dy,
      rowH: _ThreeDayView._rowH,
      hourStart: widget.hourStart,
      hourEnd: widget.hourEnd,
    );
  }

  void _onDragStart(Note note, DateTime at, int startMin, int endMin) {
    _draggingKey = calendarOccKey(note.id, at);
    _lastPreviewDayIndex = null;
    _lastPreviewStartMin = null;
    setState(() {
      _preview = _CalDragPreview(
        note: note,
        from: at,
        day: dateOnly(at),
        startMin: startMin,
        durationMin: (endMin - startMin).clamp(15, 24 * 60),
      );
    });
  }

  void _onDragUpdate(Offset global) {
    final to = _snapFromGlobal(global);
    if (to == null || _preview == null) return;
    final dayIdx = widget.days.indexWhere((d) => dateOnly(d) == dateOnly(to));
    final startMin = to.hour * 60 + to.minute;
    if (dayIdx == _lastPreviewDayIndex && startMin == _lastPreviewStartMin) {
      return;
    }
    _lastPreviewDayIndex = dayIdx;
    _lastPreviewStartMin = startMin;
    setState(() {
      _preview = _CalDragPreview(
        note: _preview!.note,
        from: _preview!.from,
        day: dateOnly(to),
        startMin: startMin,
        durationMin: _preview!.durationMin,
      );
    });
  }

  Future<void> _onDragEnd({required bool cancelled}) async {
    final preview = _preview;
    final from = preview?.from;
    final note = preview?.note;
    final key = _draggingKey;
    setState(() {
      _preview = null;
      _draggingKey = null;
    });
    if (cancelled || preview == null || note == null || from == null) return;
    final to = DateTime(
      preview.day.year,
      preview.day.month,
      preview.day.day,
      preview.startMin ~/ 60,
      preview.startMin % 60,
    );
    if (to.isAtSameMomentAs(from)) return;
    final occ = key ?? calendarOccKey(note.id, from);
    setState(() => _optimistic[occ] = to);
    try {
      await widget.onMoveNote(note, from, to);
      if (mounted) setState(() => _optimistic.remove(occ));
    } catch (_) {
      if (mounted) setState(() => _optimistic.remove(occ));
    }
  }

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
                          onMoveNote: onMoveNote,
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

typedef _CalDragPayload = ({Note note, DateTime at});

class _DayColumn extends StatefulWidget {
  const _DayColumn({
    required this.day,
    required this.hourStart,
    required this.hourEnd,
    required this.rowH,
    required this.events,
    required this.onTapSlot,
    required this.onLongPressSlot,
    required this.onTapNote,
    required this.onMoveNote,
  });

  final DateTime day;
  final int hourStart;
  final int hourEnd;
  final double rowH;
  final List<({Note note, DateTime at})> events;
  final ValueChanged<DateTime> onTapSlot;
  final ValueChanged<DateTime> onLongPressSlot;
  final ValueChanged<Note> onTapNote;
  final void Function(Note note, DateTime from, DateTime to) onMoveNote;

  /// 右侧永久留白，点空白可继续叠卡
  static const double gutter = 14;

  @override
  State<_DayColumn> createState() => _DayColumnState();
}

class _DayColumnState extends State<_DayColumn> {
  Offset? _lastDragGlobal;

  void _acceptDrop(_CalDragPayload data) {
    final box = context.findRenderObject() as RenderBox?;
    final global = _lastDragGlobal;
    if (box == null || !box.hasSize || global == null) return;
    final local = box.globalToLocal(global);
    final y = local.dy + widget.rowH * 0.35;
    final to = calendarTimeFromY(
      day: widget.day,
      localY: y,
      rowH: widget.rowH,
      hourStart: widget.hourStart,
      hourEnd: widget.hourEnd,
    );
    widget.onMoveNote(data.note, data.at, to);
  }

  @override
  Widget build(BuildContext context) {
    final day = widget.day;
    final hourStart = widget.hourStart;
    final hourEnd = widget.hourEnd;
    final rowH = widget.rowH;
    final visible = [
      for (final e in widget.events)
        if (e.at.hour >= hourStart && e.at.hour <= hourEnd) e,
    ];
    final laid = layoutCalendarEvents<({Note note, DateTime at})>(
      visible,
      startMinuteOf: (e) => e.at.hour * 60 + e.at.minute,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final usableW =
            (constraints.maxWidth - _DayColumn.gutter).clamp(0.0, double.infinity);
        return DragTarget<_CalDragPayload>(
          onWillAccept: (_) => true,
          onMove: (details) {
            _lastDragGlobal = details.offset;
          },
          onAccept: _acceptDrop,
          builder: (context, candidate, rejected) {
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Column(
                  children: [
                    for (var h = hourStart; h <= hourEnd; h++)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => widget.onTapSlot(
                          DateTime(day.year, day.month, day.day, h),
                        ),
                        onLongPress: () => widget.onLongPressSlot(
                          DateTime(day.year, day.month, day.day, h),
                        ),
                        child: Container(
                          height: rowH,
                          decoration: BoxDecoration(
                            color: candidate.isNotEmpty
                                ? const Color(0x08000000)
                                : null,
                            border: const Border(
                              top: BorderSide(color: Color(0xFFEEEEEE)),
                              left: BorderSide(color: Color(0xFFEEEEEE)),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                for (final item in laid)
                  Positioned(
                    top: (item.startMin / 60.0 - hourStart) * rowH,
                    left: 2.0 + item.leftFrac * usableW,
                    width: (item.widthFrac * usableW - 4).clamp(18.0, usableW),
                    height: ((item.endMin - item.startMin) / 60.0 * rowH - 4)
                        .clamp(22.0, rowH * 8),
                    child: _EventChip(
                      note: item.data.note,
                      at: item.data.at,
                      onTap: () => widget.onTapNote(item.data.note),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _EventChip extends StatelessWidget {
  const _EventChip({
    required this.note,
    required this.at,
    required this.onTap,
  });

  final Note note;
  final DateTime at;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final chip = Material(
      color: const Color(0xFF111111),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            note.displayTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );

    return LongPressDraggable<_CalDragPayload>(
      data: (note: note, at: at),
      hapticFeedbackOnStart: true,
      delay: const Duration(milliseconds: 180),
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(4),
        color: const Color(0xFF111111),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140, minHeight: 36),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text(
              note.displayTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.28, child: chip),
      child: chip,
    );
  }
}
