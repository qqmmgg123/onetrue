import 'package:flutter/foundation.dart';

import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
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
    AuthService? auth,
  })  : _db = db ?? AppDatabase.instance,
        _reminders = reminders ?? ReminderService.instance,
        _billing = billing ?? BillingService(),
        _auth = auth ?? AuthService.instance;

  final AppDatabase _db;
  final ReminderService _reminders;
  final BillingService _billing;
  final AuthService _auth;

  bool loading = true;
  String? error;
  List<Property> properties = [];
  List<DueItem> pending = [];

  /// 游客广场房源。
  List<MarketplaceListing> marketplace = [];
  bool marketplaceLoading = false;
  String? marketplaceError;
  String marketplaceCity = '';

  BillingService get billing => _billing;
  AppDatabase get db => _db;
  AuthService get auth => _auth;

  bool get isLandlord => _auth.isLandlord;
  bool get isGuest => _auth.isGuest;
  AuthUser? get user => _auth.currentUser;

  Future<void> bootstrap() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      await _reminders.init();
      await SyncSettings.instance.load();
      await _auth.loadSession();
      await reload();
      if (isGuest) {
        // ignore: unawaited_futures
        Future<void>.delayed(const Duration(seconds: 1), refreshMarketplace);
      } else {
        // ignore: unawaited_futures
        Future<void>.delayed(const Duration(seconds: 4), silentSync);
      }
    } catch (e) {
      error = e.toString();
      loading = false;
      notifyListeners();
    }
  }

  /// 打开 App / 手动触发。
  /// [fullPull] 手动同步：先拉后推；未改脏跟线上，有本地改动按时间戳比新旧。
  Future<SyncReport> silentSync({
    bool fullPull = false,
    void Function(String message)? onProgress,
  }) async {
    if (!_auth.isLandlord) {
      return SyncReport(error: 'sync_disabled');
    }
    final report = await SyncService(db: _db).syncSilent(
      fullPull: fullPull,
      onProgress: onProgress,
    );
    if (report.ok) {
      onProgress?.call('刷新界面…');
      await reload();
      if (fullPull && properties.isNotEmpty) {
        final names = properties.map((p) => p.name).join('、');
        onProgress?.call('当前房产：$names');
      }
    }
    return report;
  }

  Future<void> reload() async {
    if (isGuest) {
      properties = [];
      pending = [];
      loading = false;
      error = null;
      notifyListeners();
      return;
    }
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

  Future<void> refreshMarketplace({String? city}) async {
    if (city != null) marketplaceCity = city.trim();
    marketplaceLoading = true;
    marketplaceError = null;
    notifyListeners();
    try {
      marketplace = await SyncService(db: _db).fetchListedRooms(
        city: marketplaceCity.isEmpty ? null : marketplaceCity,
      );
    } catch (e) {
      marketplaceError = e.toString();
      marketplace = [];
    } finally {
      marketplaceLoading = false;
      notifyListeners();
    }
  }

  /// 注册/登录成功后：可选认领本机旧数据，再全量同步。
  Future<void> onLoggedIn({bool claimLocalData = false}) async {
    if (claimLocalData) {
      await _db.markAllSyncDirty();
    } else if (await _db.hasLocalBusinessData()) {
      // 不认领则清空，避免旧 owner 数据混进新账号
      await _db.clearBusinessData();
    }
    await reload();
    await silentSync(fullPull: true);
    notifyListeners();
  }

  Future<void> logout() async {
    await _auth.logout();
    await _db.clearBusinessData();
    properties = [];
    pending = [];
    notifyListeners();
    await refreshMarketplace();
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

  Future<int> addProperty(String name, String address, {String city = ''}) async {
    final id = await _db.insertProperty(name, address, city: city);
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
    String? city,
  }) async {
    await _db.updateProperty(
      id: id,
      name: name,
      address: address,
      city: city,
    );
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

  Future<void> renameRoom({
    required int id,
    required String label,
  }) async {
    await _db.updateRoomLabel(id: id, label: label);
    await reload();
  }

  Future<void> removeRoom(int id) async {
    await _db.deleteRoom(id);
    await reload();
  }

  Future<void> setRoomListing({
    required int roomId,
    required bool listed,
  }) async {
    await _db.setRoomListing(roomId: roomId, listed: listed);
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
    double? reading,
    int? periodId,
    double? previousReading,
    String note = '',
  }) async {
    if (reading == null && previousReading == null) {
      throw StateError('上期/本期读数至少提供一个');
    }
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

  /// 本月房租备注（不影响金额，显示在应收/账期列表）。
  Future<void> updatePeriodRemark({
    required int periodId,
    required String remark,
  }) async {
    final period = await _db.getPeriod(periodId);
    if (period == null) throw StateError('账期不存在');
    await _db.updatePeriodRemark(periodId: periodId, remark: remark);
    await reload();
  }

  /// 本月一次性额外费用（不是每月附加费）。
  Future<void> upsertPeriodFee({
    required int periodId,
    required String name,
    required double amount,
  }) async {
    final period = await _db.getPeriod(periodId);
    if (period == null) throw StateError('账期不存在');
    if (period.isPaid) throw StateError('已收款不能改额外费用');
    final invoice = await _db.latestInvoiceForPeriod(periodId);
    if (invoice != null) {
      throw StateError('已出单冻结，请先解除冻结再改额外费用');
    }
    await _db.upsertPeriodFee(periodId: periodId, name: name, amount: amount);
    await _billing.syncOpenPeriodAmounts(period.leaseId);
    await reload();
  }

  Future<void> removePeriodFee({
    required int periodId,
    required String name,
  }) async {
    await upsertPeriodFee(periodId: periodId, name: name, amount: 0);
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
    final propertyId = await _db.insertProperty(
      '示例小区',
      '本地测试，可删',
      city: '杭州',
    );
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
