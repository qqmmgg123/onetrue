import 'package:flutter_test/flutter_test.dart';

import 'package:rent_agent/billing/period_generator.dart';

void main() {
  test('due day clamps to month end', () {
    expect(dueDateInMonth(2026, 2, 31), DateTime(2026, 2, 28));
  });

  test('generates overlapping calendar months', () {
    final drafts = generateRentPeriods(
      leaseStart: DateTime(2026, 10, 15),
      leaseEnd: DateTime(2026, 12, 10),
      dueDay: 10,
      amount: 2800,
      now: DateTime(2026, 10, 5),
    );
    expect(drafts.map((e) => e.dueDate).toList(), [
      DateTime(2026, 10, 10),
      DateTime(2026, 11, 10),
      DateTime(2026, 12, 10),
    ]);
  });
}
