import 'package:flutter_test/flutter_test.dart';
import 'package:rent_agent/billing/bill_models.dart';

void main() {
  test('meter kind parsing', () {
    expect(parseMeterKind('电表'), 'electric');
    expect(parseMeterKind('水'), 'water');
    expect(parseMeterKind('燃气'), 'gas');
  });

  test('share text contains total', () {
    final bill = BillPreview(
      periodId: 1,
      roomLabel: '302',
      tenantName: '张三',
      propertyName: '示例',
      periodStart: DateTime(2026, 10, 1),
      periodEnd: DateTime(2026, 10, 31),
      dueDate: DateTime(2026, 10, 10),
      lines: const [
        BillLine(code: 'rent', label: '房屋租金', amount: 2800),
        BillLine(code: 'discount', label: '本月优惠', amount: -200),
      ],
      total: 2600,
    );
    expect(bill.toShareText(), contains('2,600'));
    expect(bill.toShareText(), contains('本月优惠'));
  });
}
