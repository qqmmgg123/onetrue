import 'package:flutter/foundation.dart';

import '../billing/bill_models.dart';
import '../billing/billing_service.dart';
import '../data/app_database.dart';
import '../domain/models.dart';
import '../reminders/reminder_service.dart';
import '../sync/sync_service.dart';
import '../sync/sync_settings.dart';
import '../ui/format.dart';

class AppStore extends ChangeNotifier {
  AppStore({
    AppDatabase? db,
    ReminderService? reminders,
    BillingService? billing,
  })  : _db = db ?? AppDatabase.instance,
        _reminders = reminders ?? ReminderService.instance,
        _billing = billing ?? BillingService();

  final AppDatabase _db;
  final ReminderService _reminders;
  final BillingService _billing;

  bool loading = true;
  String? error;
  List<Property> properties = [];
  List<DueItem> pending = [];

  BillingService get billing => _billing;
  AppDatabase get db => _db;

  Future<void> bootstrap() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      await _reminders.init();
      await SyncSettings.instance.load();
      await reload();
      // 不挡首屏：后台静默同步
      // ignore: unawaited_futures
      silentSync();
    } catch (e) {
      error = e.toString();
      loading = false;
      notifyListeners();
    }
  }

  /// 打开 App / 手动触发：推本地 dirty + 拉远端更新。
  Future<SyncReport> silentSync() async {
    final report = await SyncService(db: _db).syncSilent();
    if (report.ok && (report.pushed > 0 || report.pulled > 0)) {
      await reload();
    }
    return report;
  }

  Future<void> reload() async {
    properties = await _db.listProperties();
    for (final p in properties) {
      final rooms = await _db.roomsForProperty(p.id);
      for (final snap in rooms) {
        if (snap.lease != null) {
          await _billing.syncOpenPeriodAmounts(snap.lease!.id);
        }
      }
    }
    pending = await _db.pendingDues();
    await _reminders.reschedule(pending);
    loading = false;
    error = null;
    notifyListeners();
  }

  List<DueItem> get overdue {
    final today = dateOnly(DateTime.now());
    return pending.where((e) => e.period.dueDate.isBefore(today)).toList();
  }

  List<DueItem> get dueToday {
    final today = dateOnly(DateTime.now());
    return pending.where((e) => e.period.dueDate == today).toList();
  }

  List<DueItem> get upcoming14 {
    final today = dateOnly(DateTime.now());
    final until = today.add(const Duration(days: 14));
    return pending
        .where(
          (e) =>
              e.period.dueDate.isAfter(today) &&
              !e.period.dueDate.isAfter(until),
        )
        .toList();
  }

  Future<int> addProperty(String name, String address) async {
    final id = await _db.insertProperty(name, address);
    await reload();
    return id;
  }

  Future<void> removeProperty(int id) async {
    await _db.deleteProperty(id);
    await reload();
  }

  Future<void> renameProperty({
    required int id,
    required String name,
    String? address,
  }) async {
    await _db.updateProperty(id: id, name: name, address: address);
    await reload();
  }

  Future<List<RoomSnapshot>> roomsOf(int propertyId) {
    return _db.roomsForProperty(propertyId);
  }

  Future<int> addRoom(int propertyId, String label) async {
    final id = await _db.insertRoom(propertyId, label);
    await reload();
    return id;
  }

  Future<void> removeRoom(int id) async {
    await _db.deleteRoom(id);
    await reload();
  }

  Future<void> saveLease({
    int? leaseId,
    required int roomId,
    required String tenantName,
    required String tenantPhone,
    required DateTime startDate,
    DateTime? endDate,
    required int rentDueDay,
    required double baseRent,
    required double deposit,
    double electricPrice = 0,
    double waterPrice = 0,
    double gasPrice = 0,
    List<LeaseExtraItem> extras = const [],
  }) async {
    if (leaseId == null) {
      await _db.saveNewLease(
        roomId: roomId,
        tenantName: tenantName,
        tenantPhone: tenantPhone,
        startDate: startDate,
        endDate: endDate,
        rentDueDay: rentDueDay,
        baseRent: baseRent,
        deposit: deposit,
        electricPrice: electricPrice,
        waterPrice: waterPrice,
        gasPrice: gasPrice,
        extras: extras,
      );
    } else {
      await _db.updateLease(
        leaseId: leaseId,
        tenantName: tenantName,
        tenantPhone: tenantPhone,
        startDate: startDate,
        endDate: endDate,
        rentDueDay: rentDueDay,
        baseRent: baseRent,
        deposit: deposit,
        electricPrice: electricPrice,
        waterPrice: waterPrice,
        gasPrice: gasPrice,
        extras: extras,
      );
      await _billing.syncOpenPeriodAmounts(leaseId);
    }
    await reload();
  }

  Future<void> setLeaseExtras({
    required int leaseId,
    required List<LeaseExtraItem> extras,
  }) async {
    await _db.replaceLeaseExtras(leaseId, extras);
    await _billing.syncOpenPeriodAmounts(leaseId);
    await reload();
  }

  Future<void> endLease({
    required int leaseId,
    DateTime? endDate,
  }) async {
    await _db.endLease(leaseId: leaseId, endDate: endDate);
    await reload();
  }

  Future<void> setMeterRates({
    required int leaseId,
    required double electricPrice,
    required double waterPrice,
    required double gasPrice,
  }) async {
    await _db.updateLeaseMeterRates(
      leaseId: leaseId,
      electricPrice: electricPrice,
      waterPrice: waterPrice,
      gasPrice: gasPrice,
    );
    await _billing.syncOpenPeriodAmounts(leaseId);
    await reload();
  }

  Future<void> recordMeterReading({
    required int leaseId,
    required String kind,
    required double reading,
    int? periodId,
    double? previousReading,
    String note = '',
  }) async {
    final openId = periodId ?? await _db.latestOpenPeriodIdForLease(leaseId);
    if (openId == null) {
      throw StateError('没有可抄表的账期');
    }
    final invoice = await _db.latestInvoiceForPeriod(openId);
    if (invoice != null) {
      throw StateError('该账期已出单冻结，请先解除冻结再改抄表');
    }
    await _db.setPeriodMeterPair(
      leaseId: leaseId,
      kind: kind,
      periodId: openId,
      current: reading,
      previous: previousReading,
    );
    await _billing.syncOpenPeriodAmounts(leaseId);
    await reload();
  }

  Future<void> applyDiscount({
    required int periodId,
    required double amount,
    String note = '',
  }) async {
    final period = await _db.getPeriod(periodId);
    if (period == null) throw StateError('账期不存在');
    if (period.isPaid) throw StateError('已收款不能改优惠');
    final invoice = await _db.latestInvoiceForPeriod(periodId);
    if (invoice != null) {
      throw StateError('已出单冻结，请先解除冻结再改优惠');
    }
    await _db.upsertDiscount(periodId: periodId, amount: amount, note: note);
    await _billing.syncOpenPeriodAmounts(period.leaseId);
    await reload();
  }

  Future<BillPreview> previewBill(int periodId) =>
      _billing.previewPeriod(periodId);

  Future<BillPreview> issueBill(int periodId) async {
    final bill = await _billing.issuePeriod(periodId);
    await reload();
    return bill;
  }

  /// 删除冻结清单，账期回到试算，可再改抄表/优惠。
  Future<BillPreview> unfreezeBill(int periodId) async {
    final period = await _db.getPeriod(periodId);
    if (period == null) throw StateError('账期不存在');
    if (period.isPaid) throw StateError('已收款不能解除冻结');
    await _db.deleteInvoicesForPeriod(periodId);
    await _db.updatePeriodAmountStatus(
      periodId,
      amount: period.amount,
      status: 'pending',
    );
    await _billing.syncOpenPeriodAmounts(period.leaseId);
    await reload();
    return previewBill(periodId);
  }

  Future<void> markPaid(int periodId) async {
    await _db.markPaid(periodId);
    await reload();
  }

  Future<void> markUnpaid(int periodId) async {
    await _db.markUnpaid(periodId);
    await reload();
  }

  Future<void> seedDemo() async {
    final today = dateOnly(DateTime.now());
    final propertyId = await _db.insertProperty('示例小区', '本地测试，可删');
    final roomId = await _db.insertRoom(propertyId, '302');
    final leaseId = await _db.saveNewLease(
      roomId: roomId,
      tenantName: '张三',
      tenantPhone: '13800000000',
      startDate: DateTime(today.year, today.month, 1),
      rentDueDay: today.day,
      baseRent: 2800,
      deposit: 2800,
      electricPrice: 1.2,
      waterPrice: 5,
      extras: const [LeaseExtraItem(name: '物业费', amount: 150)],
    );
    await _db.insertMeterReading(
      leaseId: leaseId,
      kind: 'electric',
      reading: 1180,
      note: '上期',
      recordedAt: DateTime(today.year, today.month, 1),
    );
    final periodId = await _db.latestOpenPeriodIdForLease(leaseId);
    await _db.insertMeterReading(
      leaseId: leaseId,
      kind: 'electric',
      reading: 1234,
      periodId: periodId,
      note: '本期',
    );
    await reload();
  }

  Future<void> testNotification() {
    return _reminders.showTestInSeconds(8);
  }
}
