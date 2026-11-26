import 'package:flutter/foundation.dart';

import '../auth/auth_models.dart';
import '../auth/auth_service.dart';
import '../billing/bill_models.dart';
import '../billing/billing_service.dart';
import '../data/app_database.dart';
import '../domain/models.dart';
import '../domain/note_title.dart';
import '../reminders/reminder_service.dart';
import '../social/social_api.dart';
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
  List<Note> notes = [];
  List<ArticleReadRecord> articleReads = [];

  /// 市集房源 / 文章。
  List<MarketplaceListing> marketplace = [];
  List<MarketplaceArticle> marketplaceArticles = [];
  bool marketplaceLoading = false;
  String? marketplaceError;
  String marketplaceCity = '';
  bool marketplaceCityReady = false;

  BillingService get billing => _billing;
  AppDatabase get db => _db;
  AuthService get auth => _auth;

  bool get isLandlord => _auth.isLandlord;
  bool get isGuest => _auth.isGuest;
  AuthUser? get user => _auth.currentUser;

  /// 近期阅读本机桶：仅登录用户的 userId。
  String get _readsScope {
    final id = user?.id.trim() ?? '';
    return id.isEmpty ? AppDatabase.kArticleReadScopeGuest : id;
  }

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
        // 打开即拉当前用户云端缓存（增量/全量）
        await refreshMyCache();
        await syncArticleReadsFromCloud();
      }
    } catch (e) {
      error = e.toString();
      loading = false;
      notifyListeners();
    }
  }

  /// 拉取当前登录用户云端数据覆盖本地缓存（市集不走这里）。
  Future<SyncReport> refreshMyCache({
    bool forceFull = false,
    void Function(String message)? onProgress,
  }) async {
    if (!_auth.isLandlord) {
      return SyncReport(error: 'sync_disabled');
    }
    final report = await SyncService(db: _db).refreshMyCache(
      forceFull: forceFull,
      onProgress: onProgress,
    );
    if (report.ok) {
      onProgress?.call('刷新界面…');
      await reload();
    }
    return report;
  }

  /// 本地业务写入后按行直推 Neon；失败抛错（需联网）。
  Future<void> _publish(List<SyncRef> refs) async {
    if (!_auth.isLandlord) return;
    if (refs.isEmpty) return;
    final report = await SyncService(db: _db).pushLocalRows(refs);
    if (!report.ok) {
      throw StateError(report.error ?? '上传失败，请检查网络后重试');
    }
  }

  Future<void> _publishLease(int leaseId) async {
    final sync = SyncService(db: _db);
    await _publish(await sync.refsForLease(leaseId));
  }

  Future<void> _publishPeriod(int periodId) async {
    final sync = SyncService(db: _db);
    final period = await _db.getPeriod(periodId);
    final refs = await sync.refsForPeriod(periodId);
    if (period != null) {
      refs.addAll(await sync.refsForLease(period.leaseId));
    }
    await _publish(refs);
  }

  Future<void> reload() async {
    if (isGuest) {
      properties = [];
      pending = [];
      notes = [];
      articleReads = [];
      loading = false;
      error = null;
      notifyListeners();
      return;
    }
    // 房产/账期数据仍保留在本地库（兼容旧版同步），UI 不再展示；提醒只排笔记。
    properties = await _db.listProperties();
    pending = const [];
    notes = await _db.listNotes();
    articleReads = await _db.listArticleReads(scope: _readsScope);
    await _reminders.reschedule(const [], notes: notes);
    loading = false;
    error = null;
    notifyListeners();
  }

  /// 登录用户：拉云端近期阅读覆盖本机用户缓存；游客跳过。
  Future<void> syncArticleReadsFromCloud() async {
    final uid = user?.id.trim() ?? '';
    if (uid.isEmpty) return;
    try {
      final cloud = await SocialApi.instance.fetchMyArticleReads();
      await _db.replaceUserArticleReads(userId: uid, items: cloud);
      articleReads = await _db.listArticleReads(scope: uid);
      notifyListeners();
    } catch (_) {
      /* 离线用本机用户缓存 */
    }
  }

  Future<void> refreshMarketplace({String? city}) async {
    if (city != null) {
      marketplaceCity = city.trim();
      marketplaceCityReady = true;
    }
    marketplaceLoading = true;
    marketplaceError = null;
    notifyListeners();
    try {
      final sync = SyncService(db: _db);
      List<MarketplaceArticle> articles = [];
      try {
        articles = await sync.fetchListedArticles();
      } catch (_) {
        articles = [];
      }
      marketplace = [];
      marketplaceArticles = articles;
    } catch (e) {
      marketplaceError = e.toString();
      marketplace = [];
      marketplaceArticles = [];
    } finally {
      marketplaceLoading = false;
      notifyListeners();
    }
  }

  /// 注册/登录成功后：可选认领本机旧数据，再全量拉取。
  Future<void> onLoggedIn({bool claimLocalData = false}) async {
    if (claimLocalData) {
      final report = await SyncService(db: _db).uploadAllLocal();
      if (!report.ok) {
        throw StateError(report.error ?? '认领本机数据上传失败');
      }
    } else if (await _db.hasLocalBusinessData()) {
      // 不认领则清空，避免旧 owner 数据混进新账号
      await _db.clearBusinessData();
    }
    await reload();
    await refreshMyCache(forceFull: true);
    // 不把游客本机阅读迁上云；只拉该账号云端阅读
    await syncArticleReadsFromCloud();
    notifyListeners();
  }

  Future<void> logout() async {
    await _auth.logout();
    await _db.clearBusinessData();
    properties = [];
    pending = [];
    notes = [];
    articleReads = [];
    notifyListeners();
    await refreshMarketplace();
  }

  Future<List<Note>> notesOf({String? kind}) => _db.listNotes(kind: kind);

  Future<int> addNote({
    required String kind,
    String title = '',
    required String body,
    String format = kNoteFormatPlain,
    DateTime? scheduleAt,
    DateTime? remindAt,
    String recurFreq = '',
    int recurInterval = 1,
    String? recurByday,
    DateTime? recurUntil,
    int? recurCount,
    int remindOffsetMin = 0,
    String city = '',
    String coverUrl = '',
    List<String> sourceNoteUuids = const [],
  }) async {
    final resolved = resolveNoteTitleForSave(
      kind: kind,
      title: title,
      body: body,
    );
    // 新备忘插到最前（比当前最小 sort_order 再小 1）
    var sortOrder = 0;
    if (kind == kNoteKindMemo) {
      final memos = notes.where((n) => n.kind == kNoteKindMemo);
      if (memos.isNotEmpty) {
        var minSo = memos.first.sortOrder;
        for (final m in memos) {
          if (m.sortOrder < minSo) minSo = m.sortOrder;
        }
        sortOrder = minSo - 1;
      }
    }
    final id = await _db.insertNote(
      kind: kind,
      title: resolved,
      body: body,
      format: format,
      scheduleAt: scheduleAt,
      remindAt: remindAt,
      recurFreq: recurFreq,
      recurInterval: recurInterval,
      recurByday: recurByday,
      recurUntil: recurUntil,
      recurCount: recurCount,
      remindOffsetMin: remindOffsetMin,
      city: city,
      coverUrl: coverUrl,
      sortOrder: sortOrder,
      sourceNoteUuids: sourceNoteUuids,
    );
    await _publish([(table: 'notes', id: id)]);
    await reload();
    return id;
  }

  Future<void> saveNote({
    required int id,
    String? kind,
    String? title,
    String? body,
    String? format,
    DateTime? scheduleAt,
    bool clearScheduleAt = false,
    DateTime? remindAt,
    bool clearRemindAt = false,
    String? recurFreq,
    int? recurInterval,
    String? recurByday,
    bool clearRecurByday = false,
    DateTime? recurUntil,
    bool clearRecurUntil = false,
    int? recurCount,
    bool clearRecurCount = false,
    int? remindOffsetMin,
    String? city,
    String? coverUrl,
    bool clearCoverUrl = false,
    int? sortOrder,
    List<String>? sourceNoteUuids,
  }) async {
    final existing = await _db.noteById(id);
    final nextKind = kind ?? existing?.kind ?? kNoteKindNote;
    final nextBody = body ?? existing?.body ?? '';
    final nextTitle = title != null
        ? resolveNoteTitleForSave(
            kind: nextKind,
            title: title,
            body: nextBody,
          )
        : title;
    await _db.updateNote(
      id: id,
      kind: kind,
      title: nextTitle,
      body: body,
      format: format,
      scheduleAt: scheduleAt,
      clearScheduleAt: clearScheduleAt,
      remindAt: remindAt,
      clearRemindAt: clearRemindAt,
      recurFreq: recurFreq,
      recurInterval: recurInterval,
      recurByday: recurByday,
      clearRecurByday: clearRecurByday,
      recurUntil: recurUntil,
      clearRecurUntil: clearRecurUntil,
      recurCount: recurCount,
      clearRecurCount: clearRecurCount,
      remindOffsetMin: remindOffsetMin,
      city: city,
      coverUrl: coverUrl,
      clearCoverUrl: clearCoverUrl,
      sortOrder: sortOrder,
      sourceNoteUuids: sourceNoteUuids,
    );
    await _publish([(table: 'notes', id: id)]);
    await reload();
  }

  /// 备忘拖拽排序（已弃用 UI；保留 API 兼容）。
  Future<void> reorderMemos(List<int> orderedIds) async {
    if (orderedIds.isEmpty) return;
    for (var i = 0; i < orderedIds.length; i++) {
      await _db.updateNote(id: orderedIds[i], sortOrder: i);
    }
    await _publish([
      for (final id in orderedIds) (table: 'notes', id: id),
    ]);
    await reload();
  }

  /// 备忘置顶 / 取消置顶。
  Future<void> setMemoPinned(int id, {required bool pinned}) async {
    await _db.updateNote(
      id: id,
      pinnedAt: pinned ? DateTime.now().toUtc() : null,
      clearPinnedAt: !pinned,
    );
    await _publish([(table: 'notes', id: id)]);
    await reload();
  }

  /// 备忘办结 / 取消办结。
  Future<void> setMemoCompleted(int id, {required bool completed}) async {
    await _db.updateNote(
      id: id,
      completedAt: completed ? DateTime.now().toUtc() : null,
      clearCompletedAt: !completed,
    );
    await _publish([(table: 'notes', id: id)]);
    await reload();
  }

  Future<void> removeNote(int id) async {
    await _db.deleteNote(id);
    await _publish([(table: 'notes', id: id)]);
    await reload();
    // 推荐流缓存需立刻刷新；近期/收藏是用户侧记录，保留，点开再提示已删除。
    await refreshMarketplace();
  }

  /// 从近期阅读移除（本机 + 云端）。
  Future<void> removeArticleRead(String noteUuid) async {
    final uid = user?.id.trim() ?? '';
    final nid = noteUuid.trim();
    if (uid.isEmpty || nid.isEmpty) return;
    await _db.deleteArticleRead(noteUuid: nid, scope: uid);
    articleReads = await _db.listArticleReads(scope: uid);
    notifyListeners();
    try {
      await SocialApi.instance.deleteArticleReadCloud(nid);
    } catch (_) {
      /* 离线稍后同步时可再清 */
    }
  }

  Future<void> setNoteListing({
    required int noteId,
    required bool listed,
    String? city,
  }) async {
    await _db.setNoteListed(noteId, listed: listed, city: city);
    await _publish([(table: 'notes', id: noteId)]);
    await reload();
  }

  /// 打开文章详情：仅登录用户记近期阅读（本机 + 云端）；游客不记。非作者则远端 +1 访问。
  Future<void> recordArticleOpen(MarketplaceArticle article) async {
    final uid = user?.id.trim() ?? '';
    if (uid.isNotEmpty) {
      await _db.upsertArticleRead(
        noteUuid: article.noteUuid,
        title: article.title,
        body: article.body,
        format: article.format,
        city: article.city,
        coverUrl: article.coverUrl,
        ownerId: article.ownerId,
        scope: uid,
      );
      articleReads = await _db.listArticleReads(scope: uid);
      notifyListeners();
      // ignore: unawaited_futures
      SocialApi.instance
          .upsertArticleReadCloud(
            noteUuid: article.noteUuid,
            title: article.title,
            body: article.body,
            format: article.format,
            city: article.city,
            coverUrl: article.coverUrl,
            ownerId: article.ownerId,
          )
          .catchError((_) {});
    }
    final viewer = user?.id;
    final owner = article.ownerId.trim();
    if (owner.isNotEmpty && viewer != null && viewer == owner) {
      return;
    }
    // ignore: unawaited_futures
    SyncService(db: _db).incrementArticleView(
      noteUuid: article.noteUuid,
      viewerId: viewer,
    );
  }

  ArticleReadRecord? get latestArticleRead =>
      articleReads.isEmpty ? null : articleReads.first;

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
    await _publish([(table: 'properties', id: id)]);
    await reload();
    return id;
  }

  Future<void> removeProperty(int id) async {
    await _db.deleteProperty(id);
    await _publish([(table: 'properties', id: id)]);
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
    await _publish([(table: 'properties', id: id)]);
    await reload();
  }

  Future<List<RoomSnapshot>> roomsOf(int propertyId) {
    return _db.roomsForProperty(propertyId);
  }

  Future<int> addRoom(int propertyId, String label) async {
    final id = await _db.insertRoom(propertyId, label);
    await _publish([(table: 'rooms', id: id)]);
    await reload();
    return id;
  }

  Future<void> renameRoom({
    required int id,
    required String label,
  }) async {
    await _db.updateRoomLabel(id: id, label: label);
    await _publish([(table: 'rooms', id: id)]);
    await reload();
  }

  Future<void> removeRoom(int id) async {
    await _db.deleteRoom(id);
    await _publish([(table: 'rooms', id: id)]);
    await reload();
  }

  Future<void> setRoomListing({
    required int roomId,
    required bool listed,
  }) async {
    await _db.setRoomListing(roomId: roomId, listed: listed);
    await _publish([(table: 'rooms', id: roomId)]);
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
    late final int id;
    if (leaseId == null) {
      id = await _db.saveNewLease(
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
      id = leaseId;
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
    // 新登记会结束同房旧约，一并推送该房全部租约树
    final db = await _db.database;
    final roomLeases = await db.query(
      'leases',
      columns: ['id'],
      where: 'room_id = ?',
      whereArgs: [roomId],
    );
    final sync = SyncService(db: _db);
    final refs = <SyncRef>[(table: 'rooms', id: roomId)];
    for (final row in roomLeases) {
      refs.addAll(await sync.refsForLease(row['id'] as int));
    }
    if (roomLeases.every((r) => r['id'] != id)) {
      refs.addAll(await sync.refsForLease(id));
    }
    await _publish(refs);
    await reload();
  }

  Future<void> setLeaseExtras({
    required int leaseId,
    required List<LeaseExtraItem> extras,
  }) async {
    await _db.replaceLeaseExtras(leaseId, extras);
    await _billing.syncOpenPeriodAmounts(leaseId);
    await _publishLease(leaseId);
    await reload();
  }

  Future<void> endLease({
    required int leaseId,
    DateTime? endDate,
  }) async {
    await _db.endLease(leaseId: leaseId, endDate: endDate);
    await _publishLease(leaseId);
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
    await _publishLease(leaseId);
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
    await _publishPeriod(openId);
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
    await _publishPeriod(periodId);
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
    await _publish([(table: 'rent_periods', id: periodId)]);
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
    await _publishPeriod(periodId);
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
    await _publishPeriod(periodId);
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
    await _publishPeriod(periodId);
    await reload();
    return previewBill(periodId);
  }

  Future<void> markPaid(int periodId) async {
    await _db.markPaid(periodId);
    await _publishPeriod(periodId);
    await reload();
  }

  Future<void> markUnpaid(int periodId) async {
    await _db.markUnpaid(periodId);
    await _publishPeriod(periodId);
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
