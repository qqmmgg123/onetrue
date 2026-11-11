import 'models.dart';

const kRecurOnce = 'once';
const kRecurDaily = 'daily';
const kRecurWeekly = 'weekly';
const kRecurMonthly = 'monthly';
const kRecurYearly = 'yearly';

const kRecurByDayCodes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

String weekdayToByDay(DateTime dt) => kRecurByDayCodes[dt.weekday - 1];

int? byDayToWeekday(String? code) {
  final i = kRecurByDayCodes.indexOf((code ?? '').toUpperCase());
  return i < 0 ? null : i + 1;
}

String normalizeRecurFreq(String? raw) {
  final f = (raw ?? '').trim().toLowerCase();
  switch (f) {
    case kRecurDaily:
    case kRecurWeekly:
    case kRecurMonthly:
    case kRecurYearly:
      return f;
    default:
      return kRecurOnce;
  }
}

bool isRecurringFreq(String? freq) {
  final f = normalizeRecurFreq(freq);
  return f != kRecurOnce;
}

/// 将相对偏移写回绝对 remindAt（日程用）。
DateTime? remindAtFromOffset(DateTime? scheduleAt, int offsetMin) {
  if (scheduleAt == null) return null;
  final off = offsetMin < 0 ? 0 : offsetMin;
  return scheduleAt.subtract(Duration(minutes: off));
}

int offsetMinFromRemind(DateTime? scheduleAt, DateTime? remindAt) {
  if (scheduleAt == null || remindAt == null) return 0;
  final diff = scheduleAt.difference(remindAt).inMinutes;
  return diff < 0 ? 0 : diff;
}

String formatRemindOffset(int minutes) {
  if (minutes <= 0) return '日程开始时';
  if (minutes % (24 * 60) == 0) {
    final d = minutes ~/ (24 * 60);
    return '提前 $d 天';
  }
  if (minutes % 60 == 0) {
    final h = minutes ~/ 60;
    return '提前 $h 小时';
  }
  return '提前 $minutes 分钟';
}

String formatRecurSummary({
  required String? freq,
  String? byday,
  DateTime? until,
  int? count,
  DateTime? scheduleAt,
}) {
  final f = normalizeRecurFreq(freq);
  if (f == kRecurOnce) return '一次性';
  String base;
  switch (f) {
    case kRecurDaily:
      base = '每天';
      break;
    case kRecurWeekly:
      final wd = byDayToWeekday(byday) ?? scheduleAt?.weekday ?? 1;
      const labels = ['一', '二', '三', '四', '五', '六', '日'];
      base = '每周${labels[wd - 1]}';
      break;
    case kRecurMonthly:
      final day = scheduleAt?.day ?? 1;
      base = '每月$day日';
      break;
    case kRecurYearly:
      if (scheduleAt != null) {
        base = '每年${scheduleAt.month}月${scheduleAt.day}日';
      } else {
        base = '每年';
      }
      break;
    default:
      base = '一次性';
  }
  if (count != null && count > 0) return '$base · ${count}次';
  if (until != null) {
    final u = until.isUtc ? until.toLocal() : until;
    return '$base · 至${u.year}-${u.month.toString().padLeft(2, '0')}-'
        '${u.day.toString().padLeft(2, '0')}';
  }
  return '$base · 永不结束';
}

String noteRecurRemindSummary(Note note) {
  final parts = <String>[];
  if (note.kind == kNoteKindSchedule) {
    parts.add(
      formatRecurSummary(
        freq: note.recurFreq,
        byday: note.recurByday,
        until: note.recurUntil,
        count: note.recurCount,
        scheduleAt: note.scheduleAt?.toLocal(),
      ),
    );
    parts.add(formatRemindOffset(note.remindOffsetMin));
  } else if (note.kind == kNoteKindMemo && note.remindAt != null) {
    final r = note.remindAt!.toLocal();
    parts.add(
      '提醒 ${r.year}-${r.month.toString().padLeft(2, '0')}-'
      '${r.day.toString().padLeft(2, '0')} '
      '${r.hour.toString().padLeft(2, '0')}:'
      '${r.minute.toString().padLeft(2, '0')}',
    );
  }
  return parts.join(' · ');
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _withTime(DateTime day, DateTime template) => DateTime(
      day.year,
      day.month,
      day.day,
      template.hour,
      template.minute,
      template.second,
      template.millisecond,
    );

DateTime _addMonthsClamped(DateTime base, int months) {
  final targetMonth = base.month + months;
  final y = base.year + ((targetMonth - 1) ~/ 12);
  final m = ((targetMonth - 1) % 12) + 1;
  final last = DateTime(y, m + 1, 0).day;
  final day = base.day > last ? last : base.day;
  return DateTime(
    y,
    m,
    day,
    base.hour,
    base.minute,
    base.second,
    base.millisecond,
  );
}

/// 在 [from, to] 窗口内展开日程实例开始时间（本地时区）。
List<DateTime> expandOccurrences(
  Note note, {
  required DateTime from,
  required DateTime to,
  int safetyCap = 400,
}) {
  final startRaw = note.scheduleAt;
  if (startRaw == null) return const [];
  final start = startRaw.isUtc ? startRaw.toLocal() : startRaw;
  final windowFrom = from.isUtc ? from.toLocal() : from;
  final windowTo = to.isUtc ? to.toLocal() : to;
  if (!windowTo.isAfter(windowFrom) && windowTo != windowFrom) {
    return const [];
  }

  final freq = normalizeRecurFreq(note.recurFreq);
  if (freq == kRecurOnce || note.kind != kNoteKindSchedule) {
    if (!start.isBefore(windowFrom) && !start.isAfter(windowTo)) {
      return [start];
    }
    return const [];
  }

  final interval =
      note.recurInterval < 1 ? 1 : note.recurInterval;
  final until = note.recurUntil == null
      ? null
      : (note.recurUntil!.isUtc
          ? note.recurUntil!.toLocal()
          : note.recurUntil!);
  final untilEnd = until == null
      ? null
      : DateTime(until.year, until.month, until.day, 23, 59, 59, 999);
  final count = note.recurCount;

  DateTime? cursor;
  switch (freq) {
    case kRecurDaily:
      cursor = start;
      break;
    case kRecurWeekly:
      final want = byDayToWeekday(note.recurByday) ?? start.weekday;
      var d = _dateOnly(start);
      while (d.weekday != want) {
        d = d.add(const Duration(days: 1));
      }
      cursor = _withTime(d, start);
      break;
    case kRecurMonthly:
    case kRecurYearly:
      cursor = start;
      break;
    default:
      cursor = start;
  }

  final out = <DateTime>[];
  var seriesIndex = 0;
  var guard = 0;
  while (cursor != null && guard < safetyCap * 8) {
    guard++;
    if (untilEnd != null && cursor.isAfter(untilEnd)) break;
    if (count != null && count > 0 && seriesIndex >= count) break;
    if (cursor.isAfter(windowTo)) break;

    final inWindow =
        !cursor.isBefore(windowFrom) && !cursor.isAfter(windowTo);
    if (inWindow) {
      out.add(cursor);
      if (out.length >= safetyCap) break;
    }
    seriesIndex++;

    switch (freq) {
      case kRecurDaily:
        cursor = cursor.add(Duration(days: interval));
        break;
      case kRecurWeekly:
        cursor = cursor.add(Duration(days: 7 * interval));
        break;
      case kRecurMonthly:
        cursor = _addMonthsClamped(cursor, interval);
        break;
      case kRecurYearly:
        cursor = _addMonthsClamped(cursor, 12 * interval);
        break;
      default:
        cursor = null;
    }
  }
  return out;
}

/// 月历/列表：把笔记按「实例日」归桶（重复日程可落多天）。
Map<DateTime, List<({Note note, DateTime at})>> notesGroupedByDay(
  List<Note> notes, {
  required DateTime from,
  required DateTime to,
}) {
  final map = <DateTime, List<({Note note, DateTime at})>>{};
  for (final n in notes) {
    if (n.kind == kNoteKindSchedule && n.scheduleAt != null) {
      final occ = expandOccurrences(n, from: from, to: to);
      for (final at in occ) {
        final key = _dateOnly(at);
        map.putIfAbsent(key, () => []).add((note: n, at: at));
      }
      continue;
    }
    if (n.kind == kNoteKindMemo) {
      final raw = n.remindAt;
      if (raw == null) continue;
      final at = raw.isUtc ? raw.toLocal() : raw;
      if (at.isBefore(from) || at.isAfter(to)) continue;
      final key = _dateOnly(at);
      map.putIfAbsent(key, () => []).add((note: n, at: at));
    }
  }
  return map;
}
