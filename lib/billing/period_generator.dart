class PeriodDraft {
  const PeriodDraft({
    required this.periodStart,
    required this.periodEnd,
    required this.dueDate,
    required this.amount,
  });

  final DateTime periodStart;
  final DateTime periodEnd;
  final DateTime dueDate;
  final double amount;
}

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime dueDateInMonth(int year, int month, int dueDay) {
  final lastDay = DateTime(year, month + 1, 0).day;
  final day = dueDay < 1 ? 1 : (dueDay > lastDay ? lastDay : dueDay);
  return DateTime(year, month, day);
}

/// 每个与租约重叠的自然月生成一期，到期日为当月 [dueDay]（大月没有该日则落到月末）。
List<PeriodDraft> generateRentPeriods({
  required DateTime leaseStart,
  DateTime? leaseEnd,
  required int dueDay,
  required double amount,
  DateTime? now,
}) {
  final start = dateOnly(leaseStart);
  final end = leaseEnd == null ? null : dateOnly(leaseEnd);
  final today = dateOnly(now ?? DateTime.now());
  final lastMonth = end ?? DateTime(today.year, today.month + 18, 1);

  var cursor = DateTime(start.year, start.month, 1);
  final drafts = <PeriodDraft>[];

  while (!cursor.isAfter(DateTime(lastMonth.year, lastMonth.month, 1))) {
    final periodStart = cursor;
    final periodEnd = DateTime(cursor.year, cursor.month + 1, 0);
    if (end != null && periodStart.isAfter(end)) {
      break;
    }
    if (!periodEnd.isBefore(start)) {
      drafts.add(
        PeriodDraft(
          periodStart: periodStart,
          periodEnd: periodEnd,
          dueDate: dueDateInMonth(cursor.year, cursor.month, dueDay),
          amount: amount,
        ),
      );
    }
    cursor = DateTime(cursor.year, cursor.month + 1, 1);
  }
  return drafts;
}
