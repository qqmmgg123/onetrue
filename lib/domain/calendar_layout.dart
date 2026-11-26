/// Google 日历风格：重叠日常并排分列，右侧留 gutter 可继续点空白添加。

class CalendarLaidOutEvent<T> {
  const CalendarLaidOutEvent({
    required this.data,
    required this.startMin,
    required this.endMin,
    required this.col,
    required this.colCount,
  });

  final T data;
  final int startMin;
  final int endMin;
  final int col;
  final int colCount;

  /// 相对日列可用宽度（已扣除右侧 gutter）的 left 比例 0..1
  double get leftFrac => col / colCount;

  /// 相对日列可用宽度的 width 比例 0..1
  double get widthFrac => 1.0 / colCount;
}

/// [events] 元素需提供起始分钟（当日 0 起）与可选时长（默认 60）。
List<CalendarLaidOutEvent<T>> layoutCalendarEvents<T>(
  List<T> events, {
  required int Function(T e) startMinuteOf,
  int Function(T e)? durationMinuteOf,
  int defaultDurationMin = 60,
}) {
  if (events.isEmpty) return <CalendarLaidOutEvent<T>>[];

  final items = <({T data, int start, int end})>[
    for (final e in events)
      (
        data: e,
        start: startMinuteOf(e),
        end: startMinuteOf(e) +
            (durationMinuteOf?.call(e) ?? defaultDurationMin).clamp(15, 24 * 60),
      ),
  ]..sort((a, b) {
      final c = a.start.compareTo(b.start);
      if (c != 0) return c;
      return a.end.compareTo(b.end);
    });

  // 贪心分列：列内上一事件 end <= 当前 start 则可复用
  final colEnds = <int>[];
  final cols = <int>[];
  for (final it in items) {
    var col = -1;
    for (var i = 0; i < colEnds.length; i++) {
      if (colEnds[i] <= it.start) {
        col = i;
        colEnds[i] = it.end;
        break;
      }
    }
    if (col < 0) {
      col = colEnds.length;
      colEnds.add(it.end);
    }
    cols.add(col);
  }

  // 连通重叠簇内统一 colCount
  final colCount = List<int>.filled(items.length, 1);
  var clusterStart = 0;
  var clusterEnd = items.first.end;
  var clusterMaxCol = cols.first;

  void flush(int from, int toExclusive, int maxCol) {
    final n = maxCol + 1;
    for (var i = from; i < toExclusive; i++) {
      colCount[i] = n;
    }
  }

  for (var i = 1; i < items.length; i++) {
    if (items[i].start < clusterEnd) {
      if (items[i].end > clusterEnd) clusterEnd = items[i].end;
      if (cols[i] > clusterMaxCol) clusterMaxCol = cols[i];
    } else {
      flush(clusterStart, i, clusterMaxCol);
      clusterStart = i;
      clusterEnd = items[i].end;
      clusterMaxCol = cols[i];
    }
  }
  flush(clusterStart, items.length, clusterMaxCol);

  return [
    for (var i = 0; i < items.length; i++)
      CalendarLaidOutEvent(
        data: items[i].data,
        startMin: items[i].start,
        endMin: items[i].end,
        col: cols[i],
        colCount: colCount[i],
      ),
  ];
}

/// 将日列内 Y（相对列顶）转为吸附到 [snapMin] 的 DateTime。
DateTime calendarTimeFromY({
  required DateTime day,
  required double localY,
  required double rowH,
  required int hourStart,
  required int hourEnd,
  int snapMin = 15,
}) {
  final totalMin = ((localY / rowH) * 60.0) + hourStart * 60;
  var snapped = ((totalMin / snapMin).round() * snapMin);
  final minBound = hourStart * 60;
  final maxBound = hourEnd * 60;
  if (snapped < minBound) snapped = minBound;
  if (snapped > maxBound) snapped = maxBound;
  return DateTime(
    day.year,
    day.month,
    day.day,
    snapped ~/ 60,
    snapped % 60,
  );
}

String calendarOccKey(int noteId, DateTime at) =>
    '$noteId:${at.millisecondsSinceEpoch}';
