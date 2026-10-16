import 'dart:convert';

import '../data/app_database.dart';
import '../ui/format.dart';
import 'bill_models.dart';

class BillingService {
  BillingService({AppDatabase? db}) : _db = db ?? AppDatabase.instance;

  final AppDatabase _db;

  Future<BillPreview> previewPeriod(int periodId) async {
    final ctx = await _db.periodContext(periodId);
    if (ctx == null) throw StateError('账期不存在');
    final invoice = await _db.latestInvoiceForPeriod(periodId);
    if (invoice != null) {
      return BillPreview(
        periodId: periodId,
        roomLabel: ctx.roomLabel,
        tenantName: ctx.tenantName,
        propertyName: ctx.propertyName,
        periodStart: ctx.period.periodStart,
        periodEnd: ctx.period.periodEnd,
        dueDate: ctx.period.dueDate,
        lines: invoice.lines,
        total: invoice.total,
        invoiceId: invoice.id,
        issuedAt: invoice.issuedAt,
      );
    }
    final lines = await _buildLines(ctx);
    final total = _sum(lines);
    return BillPreview(
      periodId: periodId,
      roomLabel: ctx.roomLabel,
      tenantName: ctx.tenantName,
      propertyName: ctx.propertyName,
      periodStart: ctx.period.periodStart,
      periodEnd: ctx.period.periodEnd,
      dueDate: ctx.period.dueDate,
      lines: lines,
      total: total,
    );
  }

  Future<BillPreview> issuePeriod(int periodId) async {
    final existing = await _db.latestInvoiceForPeriod(periodId);
    if (existing != null) {
      return previewPeriod(periodId);
    }
    final ctx = await _db.periodContext(periodId);
    if (ctx == null) throw StateError('账期不存在');
    if (ctx.period.isPaid) throw StateError('已收款的账期不能再出单');

    final lines = await _buildLines(ctx);
    final total = _sum(lines);
    final invoiceId = await _db.insertInvoice(
      periodId: periodId,
      total: total,
      linesJson: jsonEncode(lines.map((e) => e.toJson()).toList()),
    );
    await _db.updatePeriodAmountStatus(
      periodId,
      amount: total,
      status: 'invoiced',
    );
    return BillPreview(
      periodId: periodId,
      roomLabel: ctx.roomLabel,
      tenantName: ctx.tenantName,
      propertyName: ctx.propertyName,
      periodStart: ctx.period.periodStart,
      periodEnd: ctx.period.periodEnd,
      dueDate: ctx.period.dueDate,
      lines: lines,
      total: total,
      invoiceId: invoiceId,
      issuedAt: DateTime.now(),
    );
  }

  /// 刷新未出单账期的试算金额（首页应收数字跟水电/优惠对齐）。
  Future<void> syncOpenPeriodAmounts(int leaseId) async {
    final periods = await _db.periodsForLease(leaseId);
    for (final p in periods) {
      if (!p.isOpen) continue;
      final hasInvoice = await _db.latestInvoiceForPeriod(p.id);
      if (hasInvoice != null) continue;
      final ctx = await _db.periodContext(p.id);
      if (ctx == null) continue;
      final total = _sum(await _buildLines(ctx));
      await _db.updatePeriodAmountStatus(p.id, amount: total, status: p.status);
    }
  }

  Future<List<BillLine>> _buildLines(PeriodContext ctx) async {
    final lines = <BillLine>[
      BillLine(
        code: 'rent',
        label: '房屋租金',
        amount: ctx.lease.baseRent,
        detail: '${ymd(ctx.period.periodStart).substring(0, 7)}',
      ),
    ];
    final extras =
        ctx.extras.isNotEmpty ? ctx.extras : ctx.lease.effectiveExtras;
    var extraIndex = 0;
    for (final e in extras) {
      if (e.amount == 0) continue;
      lines.add(
        BillLine(
          code: 'extra_${extraIndex++}',
          label: e.name,
          amount: e.amount,
        ),
      );
    }

    for (final kind in const ['electric', 'water', 'gas']) {
      final pair = await _db.meterPairForPeriod(ctx.lease.id, kind, ctx.period);
      if (pair == null) continue;
      final price = ctx.lease.priceFor(kind);
      final usage = pair.current - pair.previous;
      final unit = meterUsageUnit(kind);
      final usageName = meterUsageName(kind);
      if (usage < 0) {
        lines.add(
          BillLine(
            code: kind,
            label: '${meterKindLabel(kind)}费',
            amount: 0,
            detail: '读数异常 ${_n(pair.previous)}→${_n(pair.current)}',
          ),
        );
        continue;
      }
      if (price <= 0) {
        lines.add(
          BillLine(
            code: kind,
            label: '${meterKindLabel(kind)}费',
            amount: 0,
            detail:
                '$usageName ${_n(usage)} $unit（${_n(pair.previous)}→${_n(pair.current)}）· 未设单价',
          ),
        );
        continue;
      }
      final amount = double.parse((usage * price).toStringAsFixed(2));
      lines.add(
        BillLine(
          code: kind,
          label: '${meterKindLabel(kind)}费',
          amount: amount,
          detail:
              '$usageName ${_n(usage)} $unit（${_n(pair.previous)}→${_n(pair.current)}）× ${_n(price)}元/$unit',
        ),
      );
    }

    final discount = await _db.discountForPeriod(ctx.period.id);
    if (discount > 0) {
      final note = await _db.discountNoteForPeriod(ctx.period.id);
      lines.add(
        BillLine(
          code: 'discount',
          label: '本月优惠',
          amount: -discount,
          detail: note.isEmpty ? '心情减免' : note,
        ),
      );
    }

    final subtotal = _sum(lines);
    // 滞纳金：默认关闭（单价 0）；若以后加费率再算。当前不自动加。
    if (subtotal < 0) {
      // 不允许负合计：把优惠截断提示在 detail
      return [
        ...lines.where((e) => e.code != 'discount'),
        BillLine(
          code: 'discount',
          label: '本月优惠',
          amount: -(_sum(lines.where((e) => e.code != 'discount').toList())),
          detail: '已截断到 0（优惠不能超过应收）',
        ),
      ];
    }
    return lines;
  }

  double _sum(List<BillLine> lines) =>
      double.parse(lines.fold<double>(0, (a, b) => a + b.amount).toStringAsFixed(2));

  String _n(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }
}
