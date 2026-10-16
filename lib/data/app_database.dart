import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../agent/agent_models.dart';
import '../agent/chat_memory.dart';
import '../billing/bill_models.dart';
import '../billing/period_generator.dart' hide dateOnly;
import '../domain/models.dart';
import '../ui/format.dart';

const _uuid = Uuid();

class MeterPair {
  const MeterPair({required this.previous, required this.current});
  final double previous;
  final double current;
}

class PeriodContext {
  const PeriodContext({
    required this.period,
    required this.lease,
    required this.roomLabel,
    required this.propertyName,
    required this.tenantName,
    this.extras = const [],
  });

  final RentPeriod period;
  final Lease lease;
  final String roomLabel;
  final String propertyName;
  final String tenantName;
  final List<LeaseExtraItem> extras;
}

class StoredInvoice {
  const StoredInvoice({
    required this.id,
    required this.periodId,
    required this.total,
    required this.issuedAt,
    required this.lines,
  });

  final int id;
  final int periodId;
  final double total;
  final DateTime issuedAt;
  final List<BillLine> lines;
}

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'rent_agent.db');
    _db = await openDatabase(
      path,
      version: 5,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, _) async {
        await _createV1(db);
        await _upgradeToV2(db);
        await _upgradeToV3(db);
        await _upgradeToV4(db);
        await _upgradeToV5(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _upgradeToV2(db);
        if (oldVersion < 3) await _upgradeToV3(db);
        if (oldVersion < 4) await _upgradeToV4(db);
        if (oldVersion < 5) await _upgradeToV5(db);
      },
    );
    return _db!;
  }

  Future<void> _createV1(Database db) async {
    await db.execute('''
      CREATE TABLE properties (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        address TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE rooms (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        property_id INTEGER NOT NULL,
        label TEXT NOT NULL,
        FOREIGN KEY (property_id) REFERENCES properties(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE tenants (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE leases (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        room_id INTEGER NOT NULL,
        tenant_id INTEGER NOT NULL,
        start_date TEXT NOT NULL,
        end_date TEXT,
        rent_due_day INTEGER NOT NULL,
        base_rent REAL NOT NULL,
        deposit REAL NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'active',
        FOREIGN KEY (room_id) REFERENCES rooms(id) ON DELETE CASCADE,
        FOREIGN KEY (tenant_id) REFERENCES tenants(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE rent_periods (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        lease_id INTEGER NOT NULL,
        period_start TEXT NOT NULL,
        period_end TEXT NOT NULL,
        due_date TEXT NOT NULL,
        amount REAL NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        UNIQUE(lease_id, period_start),
        FOREIGN KEY (lease_id) REFERENCES leases(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        period_id INTEGER NOT NULL,
        amount REAL NOT NULL,
        paid_at TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        FOREIGN KEY (period_id) REFERENCES rent_periods(id) ON DELETE CASCADE
      )
    ''');
  }

  Future<void> _upgradeToV2(Database db) async {
    Future<void> tryExec(String sql) async {
      try {
        await db.execute(sql);
      } catch (_) {}
    }

    await tryExec(
      "ALTER TABLE leases ADD COLUMN electric_price REAL NOT NULL DEFAULT 0",
    );
    await tryExec(
      "ALTER TABLE leases ADD COLUMN water_price REAL NOT NULL DEFAULT 0",
    );
    await tryExec(
      "ALTER TABLE leases ADD COLUMN gas_price REAL NOT NULL DEFAULT 0",
    );
    await tryExec(
      "ALTER TABLE leases ADD COLUMN fixed_extra REAL NOT NULL DEFAULT 0",
    );
    await tryExec(
      "ALTER TABLE leases ADD COLUMN fixed_extra_label TEXT NOT NULL DEFAULT '固定杂费'",
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS meter_readings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        lease_id INTEGER NOT NULL,
        kind TEXT NOT NULL,
        reading REAL NOT NULL,
        recorded_at TEXT NOT NULL,
        period_id INTEGER,
        note TEXT NOT NULL DEFAULT '',
        FOREIGN KEY (lease_id) REFERENCES leases(id) ON DELETE CASCADE,
        FOREIGN KEY (period_id) REFERENCES rent_periods(id) ON DELETE SET NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS period_adjustments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        period_id INTEGER NOT NULL,
        type TEXT NOT NULL DEFAULT 'discount',
        amount REAL NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        UNIQUE(period_id, type),
        FOREIGN KEY (period_id) REFERENCES rent_periods(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS invoices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        period_id INTEGER NOT NULL,
        total REAL NOT NULL,
        lines_json TEXT NOT NULL,
        issued_at TEXT NOT NULL,
        FOREIGN KEY (period_id) REFERENCES rent_periods(id) ON DELETE CASCADE
      )
    ''');
  }

  Future<void> _upgradeToV3(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chat_sessions (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '新对话',
        sticky_json TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chat_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        role TEXT NOT NULL,
        text TEXT NOT NULL,
        pending_json TEXT,
        confirmed INTEGER,
        created_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES chat_sessions(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_chat_messages_session '
      'ON chat_messages(session_id, id)',
    );
  }

  Future<void> _upgradeToV4(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lease_extras (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        lease_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        amount REAL NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (lease_id) REFERENCES leases(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_lease_extras_lease ON lease_extras(lease_id)',
    );
    // 把旧的单笔固定杂费迁成一项
    await db.execute('''
      INSERT INTO lease_extras (lease_id, name, amount, sort_order)
      SELECT id,
             COALESCE(NULLIF(fixed_extra_label, ''), '固定杂费'),
             fixed_extra,
             0
      FROM leases
      WHERE fixed_extra > 0
        AND NOT EXISTS (
          SELECT 1 FROM lease_extras e WHERE e.lease_id = leases.id
        )
    ''');
  }

  /// 同步元数据：uuid 跨端主键，updated_at/LWW，deleted_at 软删，dirty 待上传。
  Future<void> _upgradeToV5(Database db) async {
    const tables = [
      'properties',
      'rooms',
      'tenants',
      'leases',
      'lease_extras',
      'rent_periods',
      'meter_readings',
      'period_adjustments',
      'invoices',
      'payments',
    ];
    for (final t in tables) {
      await _tryExec(db, 'ALTER TABLE $t ADD COLUMN uuid TEXT');
      await _tryExec(db, 'ALTER TABLE $t ADD COLUMN updated_at TEXT');
      await _tryExec(db, 'ALTER TABLE $t ADD COLUMN deleted_at TEXT');
      await _tryExec(
        db,
        'ALTER TABLE $t ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1',
      );
    }
    final now = DateTime.now().toUtc().toIso8601String();
    for (final t in tables) {
      final rows = await db.query(t, columns: ['id', 'uuid']);
      for (final r in rows) {
        final id = r['id'] as int;
        final existing = r['uuid'] as String?;
        await db.update(
          t,
          {
            if (existing == null || existing.isEmpty) 'uuid': _uuid.v4(),
            'updated_at': now,
            'dirty': 1,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await _tryExec(
        db,
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_${t}_uuid ON $t(uuid)',
      );
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  Future<void> _tryExec(Database db, String sql) async {
    try {
      await db.execute(sql);
    } catch (_) {}
  }

  Map<String, Object?> _newSyncCols() => {
        'uuid': _uuid.v4(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'dirty': 1,
      };

  Map<String, Object?> _touchSyncCols() => {
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'dirty': 1,
      };

  Future<void> markSynced(String table, int localId) async {
    await (await database).update(
      table,
      {'dirty': 0},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  Future<String?> getSyncState(String key) async {
    final rows = await (await database).query(
      'sync_state',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setSyncState(String key, String value) async {
    await (await database).insert(
      'sync_state',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> dirtyRows(String table) async {
    return (await database).query(
      table,
      where: 'dirty = 1',
      orderBy: 'id ASC',
    );
  }

  Future<Map<String, Object?>?> rowByUuid(String table, String uuid) async {
    final rows = await (await database).query(
      table,
      where: 'uuid = ?',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  Future<List<Property>> listProperties() async {
    final rows = await (await database).query(
      'properties',
      where: 'deleted_at IS NULL',
      orderBy: 'id DESC',
    );
    return rows
        .map(
          (r) => Property(
            id: r['id'] as int,
            name: r['name'] as String,
            address: r['address'] as String,
          ),
        )
        .toList();
  }

  Future<int> insertProperty(String name, String address) async {
    return (await database).insert('properties', {
      'name': name,
      'address': address,
      ..._newSyncCols(),
    });
  }

  Future<void> deleteProperty(int id) async {
    await (await database).update(
      'properties',
      {
        'deleted_at': DateTime.now().toUtc().toIso8601String(),
        ..._touchSyncCols(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateProperty({
    required int id,
    required String name,
    String? address,
  }) async {
    final patch = <String, Object?>{'name': name, ..._touchSyncCols()};
    if (address != null) patch['address'] = address;
    await (await database).update(
      'properties',
      patch,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<RoomSnapshot>> roomsForProperty(int propertyId) async {
    final db = await database;
    final rooms = await db.query(
      'rooms',
      where: 'property_id = ? AND deleted_at IS NULL',
      whereArgs: [propertyId],
      orderBy: 'label COLLATE NOCASE',
    );
    final result = <RoomSnapshot>[];
    for (final row in rooms) {
      final room = Room(
        id: row['id'] as int,
        propertyId: row['property_id'] as int,
        label: row['label'] as String,
      );
      final leaseRows = await db.query(
        'leases',
        where: "room_id = ? AND status = 'active' AND deleted_at IS NULL",
        whereArgs: [room.id],
        orderBy: 'id DESC',
        limit: 1,
      );
      Lease? lease;
      Tenant? tenant;
      if (leaseRows.isNotEmpty) {
        final lid = leaseRows.first['id'] as int;
        lease = _leaseFrom(leaseRows.first, await extrasForLease(lid));
        final tenantRows = await db.query(
          'tenants',
          where: 'id = ?',
          whereArgs: [lease.tenantId],
        );
        if (tenantRows.isNotEmpty) {
          tenant = _tenantFrom(tenantRows.first);
        }
      }
      result.add(RoomSnapshot(room: room, lease: lease, tenant: tenant));
    }
    return result;
  }

  Future<int> insertRoom(int propertyId, String label) async {
    return (await database).insert('rooms', {
      'property_id': propertyId,
      'label': label,
      ..._newSyncCols(),
    });
  }

  Future<void> deleteRoom(int id) async {
    await (await database).update(
      'rooms',
      {
        'deleted_at': DateTime.now().toUtc().toIso8601String(),
        ..._touchSyncCols(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Room?> getRoom(int id) async {
    final rows = await (await database).query(
      'rooms',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Room(
      id: r['id'] as int,
      propertyId: r['property_id'] as int,
      label: r['label'] as String,
    );
  }

  /// 按房号模糊匹配（忽略大小写），可带小区名缩小范围。
  Future<List<RoomSnapshot>> findRoomsByLabel(
    String label, {
    String? propertyName,
  }) async {
    final db = await database;
    final rooms = await db.rawQuery('''
      SELECT r.id, r.property_id, r.label, p.name AS property_name
      FROM rooms r
      JOIN properties p ON p.id = r.property_id
      WHERE r.label LIKE ? COLLATE NOCASE
        AND (? IS NULL OR p.name LIKE ? COLLATE NOCASE)
      ORDER BY r.label
    ''', ['%$label%', propertyName, propertyName == null ? null : '%$propertyName%']);

    final result = <RoomSnapshot>[];
    for (final row in rooms) {
      final room = Room(
        id: row['id'] as int,
        propertyId: row['property_id'] as int,
        label: row['label'] as String,
      );
      final lease = await activeLeaseForRoom(room.id);
      Tenant? tenant;
      if (lease != null) {
        tenant = await getTenant(lease.tenantId);
      }
      result.add(RoomSnapshot(room: room, lease: lease, tenant: tenant));
    }
    return result;
  }

  Future<Property?> findPropertyByName(String name) async {
    final rows = await (await database).query(
      'properties',
      where: 'name LIKE ? COLLATE NOCASE',
      whereArgs: ['%$name%'],
      orderBy: 'id DESC',
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Property(
      id: r['id'] as int,
      name: r['name'] as String,
      address: r['address'] as String,
    );
  }

  Future<List<Map<String, Object?>>> inventorySummary() async {
    return (await database).rawQuery('''
      SELECT
        p.id AS property_id,
        p.name AS property_name,
        r.id AS room_id,
        r.label AS room_label,
        l.id AS lease_id,
        l.rent_due_day,
        l.base_rent,
        t.name AS tenant_name,
        t.phone AS tenant_phone
      FROM properties p
      LEFT JOIN rooms r ON r.property_id = p.id
      LEFT JOIN leases l ON l.room_id = r.id AND l.status = 'active'
      LEFT JOIN tenants t ON t.id = l.tenant_id
      ORDER BY p.id DESC, r.label COLLATE NOCASE
    ''');
  }

  Future<Property?> getProperty(int id) async {
    final rows = await (await database).query(
      'properties',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Property(
      id: r['id'] as int,
      name: r['name'] as String,
      address: r['address'] as String,
    );
  }

  Future<Lease?> activeLeaseForRoom(int roomId) async {
    final rows = await (await database).query(
      'leases',
      where: "room_id = ? AND status = 'active' AND deleted_at IS NULL",
      whereArgs: [roomId],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final id = rows.first['id'] as int;
    return _leaseFrom(rows.first, await extrasForLease(id));
  }

  Future<Tenant?> getTenant(int id) async {
    final rows = await (await database).query(
      'tenants',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return _tenantFrom(rows.first);
  }

  Future<List<RentPeriod>> periodsForLease(int leaseId) async {
    final rows = await (await database).query(
      'rent_periods',
      where: 'lease_id = ?',
      whereArgs: [leaseId],
      orderBy: 'due_date DESC',
    );
    return rows.map(_periodFrom).toList();
  }

  Future<List<LeaseExtraItem>> extrasForLease(int leaseId) async {
    final rows = await (await database).query(
      'lease_extras',
      where: 'lease_id = ?',
      whereArgs: [leaseId],
      orderBy: 'sort_order ASC, id ASC',
    );
    return rows
        .map(
          (r) => LeaseExtraItem(
            id: r['id'] as int,
            name: r['name'] as String,
            amount: (r['amount'] as num).toDouble(),
            sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList();
  }

  Future<void> replaceLeaseExtras(int leaseId, List<LeaseExtraItem> extras) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('lease_extras', where: 'lease_id = ?', whereArgs: [leaseId]);
      var i = 0;
      for (final e in extras) {
        final name = e.name.trim();
        if (name.isEmpty || e.amount == 0) continue;
        await txn.insert('lease_extras', {
          'lease_id': leaseId,
          'name': name,
          'amount': e.amount,
          'sort_order': e.sortOrder != 0 ? e.sortOrder : i,
          ..._newSyncCols(),
        });
        i++;
      }
      // 同步旧列，便于兼容查询
      final sum = extras.fold<double>(0, (a, b) => a + b.amount);
      final label = extras.isEmpty
          ? '固定杂费'
          : extras.map((e) => e.name).join('、');
      await txn.update(
        'leases',
        {
          'fixed_extra': sum,
          'fixed_extra_label': label.length > 40 ? '${label.substring(0, 40)}…' : label,
        },
        where: 'id = ?',
        whereArgs: [leaseId],
      );
    });
  }

  Future<int> saveNewLease({
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
    double fixedExtra = 0,
    String fixedExtraLabel = '固定杂费',
  }) async {
    final items = extras.isNotEmpty
        ? extras
        : (fixedExtra > 0
            ? [LeaseExtraItem(name: fixedExtraLabel, amount: fixedExtra)]
            : <LeaseExtraItem>[]);
    final db = await database;
    return db.transaction((txn) async {
      final existing = await txn.query(
        'leases',
        where: "room_id = ? AND status = 'active'",
        whereArgs: [roomId],
      );
      for (final row in existing) {
        await txn.update(
          'leases',
          {'status': 'ended', 'end_date': ymd(DateTime.now())},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
      final tenantId = await txn.insert('tenants', {
        'name': tenantName,
        'phone': tenantPhone,
        ..._newSyncCols(),
      });
      final sum = items.fold<double>(0, (a, b) => a + b.amount);
      final label = items.isEmpty
          ? '固定杂费'
          : items.map((e) => e.name).join('、');
      final leaseId = await txn.insert('leases', {
        'room_id': roomId,
        'tenant_id': tenantId,
        'start_date': ymd(startDate),
        'end_date': endDate == null ? null : ymd(endDate),
        'rent_due_day': rentDueDay,
        'base_rent': baseRent,
        'deposit': deposit,
        'status': 'active',
        'electric_price': electricPrice,
        'water_price': waterPrice,
        'gas_price': gasPrice,
        'fixed_extra': sum,
        'fixed_extra_label': label,
        ..._newSyncCols(),
      });
      var i = 0;
      for (final e in items) {
        if (e.name.trim().isEmpty || e.amount == 0) continue;
        await txn.insert('lease_extras', {
          'lease_id': leaseId,
          'name': e.name.trim(),
          'amount': e.amount,
          'sort_order': i++,
          ..._newSyncCols(),
        });
      }
      await _insertMissingPeriods(txn, leaseId, startDate, endDate, rentDueDay, baseRent);
      return leaseId;
    });
  }

  Future<void> updateLease({
    required int leaseId,
    required String tenantName,
    required String tenantPhone,
    required DateTime startDate,
    DateTime? endDate,
    required int rentDueDay,
    required double baseRent,
    required double deposit,
    double? electricPrice,
    double? waterPrice,
    double? gasPrice,
    List<LeaseExtraItem>? extras,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final leaseRows = await txn.query(
        'leases',
        where: 'id = ?',
        whereArgs: [leaseId],
      );
      if (leaseRows.isEmpty) return;
      final old = leaseRows.first;
      final tenantId = old['tenant_id'] as int;
      await txn.update(
        'tenants',
        {'name': tenantName, 'phone': tenantPhone},
        where: 'id = ?',
        whereArgs: [tenantId],
      );
      await txn.update(
        'leases',
        {
          'start_date': ymd(startDate),
          'end_date': endDate == null ? null : ymd(endDate),
          'rent_due_day': rentDueDay,
          'base_rent': baseRent,
          'deposit': deposit,
          'electric_price': electricPrice ?? old['electric_price'] ?? 0,
          'water_price': waterPrice ?? old['water_price'] ?? 0,
          'gas_price': gasPrice ?? old['gas_price'] ?? 0,
        },
        where: 'id = ?',
        whereArgs: [leaseId],
      );
      // 仅起止/收租日变化时重建未收账期；改附加费/单价/租户不要删账期（否则抄表 period_id 会断）。
      final oldStart = parseYmd(old['start_date'] as String)!;
      final oldEnd = parseYmd(old['end_date'] as String?);
      final oldDue = old['rent_due_day'] as int;
      final scheduleChanged = ymd(startDate) != ymd(oldStart) ||
          (endDate == null ? null : ymd(endDate)) !=
              (oldEnd == null ? null : ymd(oldEnd)) ||
          rentDueDay != oldDue;
      if (scheduleChanged) {
        await txn.delete(
          'rent_periods',
          where: "lease_id = ? AND status != 'paid'",
          whereArgs: [leaseId],
        );
        await _insertMissingPeriods(
          txn,
          leaseId,
          startDate,
          endDate,
          rentDueDay,
          baseRent,
        );
      } else if ((baseRent - (old['base_rent'] as num).toDouble()).abs() >
          0.001) {
        // 只改房租：刷新未出单金额，保留账期 id
        final open = await txn.query(
          'rent_periods',
          where: "lease_id = ? AND status = 'pending'",
          whereArgs: [leaseId],
        );
        for (final p in open) {
          await txn.update(
            'rent_periods',
            {'amount': baseRent},
            where: 'id = ?',
            whereArgs: [p['id']],
          );
        }
      }
    });
    if (extras != null) {
      await replaceLeaseExtras(leaseId, extras);
    }
  }

  Future<void> updateLeaseMeterRates({
    required int leaseId,
    required double electricPrice,
    required double waterPrice,
    required double gasPrice,
  }) async {
    await (await database).update(
      'leases',
      {
        'electric_price': electricPrice,
        'water_price': waterPrice,
        'gas_price': gasPrice,
      },
      where: 'id = ?',
      whereArgs: [leaseId],
    );
  }

  Future<void> endLease({
    required int leaseId,
    DateTime? endDate,
  }) async {
    final end = endDate ?? DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    await (await database).update(
      'leases',
      {'status': 'ended', 'end_date': ymd(end)},
      where: 'id = ?',
      whereArgs: [leaseId],
    );
  }

  Future<void> _insertMissingPeriods(
    Transaction txn,
    int leaseId,
    DateTime startDate,
    DateTime? endDate,
    int rentDueDay,
    double baseRent,
  ) async {
    final drafts = generateRentPeriods(
      leaseStart: startDate,
      leaseEnd: endDate,
      dueDay: rentDueDay,
      amount: baseRent,
    );
    for (final draft in drafts) {
      await txn.insert(
        'rent_periods',
        {
          'lease_id': leaseId,
          'period_start': ymd(draft.periodStart),
          'period_end': ymd(draft.periodEnd),
          'due_date': ymd(draft.dueDate),
          'amount': draft.amount,
          'status': 'pending',
          ..._newSyncCols(),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<List<DueItem>> pendingDues() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT
        p.id, p.lease_id, p.period_start, p.period_end, p.due_date, p.amount, p.status,
        r.label AS room_label,
        pr.name AS property_name,
        t.name AS tenant_name,
        t.phone AS tenant_phone
      FROM rent_periods p
      JOIN leases l ON l.id = p.lease_id
      JOIN rooms r ON r.id = l.room_id
      JOIN properties pr ON pr.id = r.property_id
      JOIN tenants t ON t.id = l.tenant_id
      WHERE p.status IN ('pending', 'invoiced') AND l.status = 'active'
      ORDER BY p.due_date ASC
    ''');
    return rows
        .map(
          (r) => DueItem(
            period: _periodFrom(r),
            roomLabel: r['room_label'] as String,
            propertyName: r['property_name'] as String,
            tenantName: r['tenant_name'] as String,
            tenantPhone: r['tenant_phone'] as String,
          ),
        )
        .toList();
  }

  Future<void> markPaid(int periodId, {String note = ''}) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'rent_periods',
        where: 'id = ?',
        whereArgs: [periodId],
      );
      if (rows.isEmpty) return;
      final amount = rows.first['amount'] as num;
      await txn.update(
        'rent_periods',
        {'status': 'paid'},
        where: 'id = ?',
        whereArgs: [periodId],
      );
      await txn.insert('payments', {
        'period_id': periodId,
        'amount': amount,
        'paid_at': DateTime.now().toIso8601String(),
        'note': note,
      });
    });
  }

  Future<void> markUnpaid(int periodId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'payments',
        where: 'period_id = ?',
        whereArgs: [periodId],
      );
      await txn.update(
        'rent_periods',
        {'status': 'pending'},
        where: 'id = ?',
        whereArgs: [periodId],
      );
    });
  }

  Future<Lease?> getLease(int id) async {
    final rows = await (await database).query(
      'leases',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return _leaseFrom(rows.first, await extrasForLease(id));
  }

  Future<RentPeriod?> getPeriod(int id) async {
    final rows = await (await database).query(
      'rent_periods',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return _periodFrom(rows.first);
  }

  Future<PeriodContext?> periodContext(int periodId) async {
    final rows = await (await database).rawQuery('''
      SELECT
        p.id, p.lease_id, p.period_start, p.period_end, p.due_date, p.amount, p.status,
        l.room_id, l.tenant_id, l.start_date, l.end_date, l.rent_due_day,
        l.base_rent, l.deposit, l.status AS lease_status,
        l.electric_price, l.water_price, l.gas_price, l.fixed_extra, l.fixed_extra_label,
        r.label AS room_label,
        pr.name AS property_name,
        t.name AS tenant_name
      FROM rent_periods p
      JOIN leases l ON l.id = p.lease_id
      JOIN rooms r ON r.id = l.room_id
      JOIN properties pr ON pr.id = r.property_id
      JOIN tenants t ON t.id = l.tenant_id
      WHERE p.id = ?
    ''', [periodId]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    final leaseId = r['lease_id'] as int;
    final extras = await extrasForLease(leaseId);
    return PeriodContext(
      period: _periodFrom(r),
      lease: _leaseFrom(r, extras, leaseIdOverride: leaseId),
      roomLabel: r['room_label'] as String,
      propertyName: r['property_name'] as String,
      tenantName: r['tenant_name'] as String,
      extras: extras,
    );
  }

  Future<int?> latestOpenPeriodIdForLease(int leaseId) async {
    // 兼容旧调用：改为「当前应操作的账期」（本月优先），避免抄表/优惠打到很早以前的未结期。
    return currentBillingPeriodIdForLease(leaseId);
  }

  /// 对话/抄表/优惠用：优先含今天的未结账期，否则到期日最接近今天的未结账期。
  Future<int?> currentBillingPeriodIdForLease(int leaseId) async {
    final periods = await periodsForLease(leaseId);
    final open = periods.where((p) => p.isOpen).toList();
    if (open.isEmpty) return null;
    final today = dateOnly(DateTime.now());
    for (final p in open) {
      if (!today.isBefore(p.periodStart) && !today.isAfter(p.periodEnd)) {
        return p.id;
      }
    }
    open.sort((a, b) {
      final da = a.dueDate.difference(today).inDays.abs();
      final db = b.dueDate.difference(today).inDays.abs();
      if (da != db) return da.compareTo(db);
      return b.periodStart.compareTo(a.periodStart);
    });
    return open.first.id;
  }

  Future<int> insertMeterReading({
    required int leaseId,
    required String kind,
    required double reading,
    int? periodId,
    String note = '',
    DateTime? recordedAt,
  }) async {
    return (await database).insert('meter_readings', {
      'lease_id': leaseId,
      'kind': kind,
      'reading': reading,
      'recorded_at': (recordedAt ?? DateTime.now()).toIso8601String(),
      'period_id': periodId,
      'note': note,
      ..._newSyncCols(),
    });
  }

  /// 同一账期同一表种只保留一条「本期」读数（覆盖更新）。
  Future<int> upsertPeriodMeterReading({
    required int leaseId,
    required String kind,
    required double reading,
    required int periodId,
    String note = '',
  }) async {
    final db = await database;
    final existing = await db.query(
      'meter_readings',
      where: 'lease_id = ? AND kind = ? AND period_id = ?',
      whereArgs: [leaseId, kind, periodId],
      orderBy: 'recorded_at DESC',
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final id = existing.first['id'] as int;
      await db.update(
        'meter_readings',
        {
          'reading': reading,
          'recorded_at': DateTime.now().toIso8601String(),
          'note': note,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      return id;
    }
    return insertMeterReading(
      leaseId: leaseId,
      kind: kind,
      reading: reading,
      periodId: periodId,
      note: note,
    );
  }

  /// 为账期写入/覆盖「上期+本期」读数对，保证清单能算用量。
  Future<void> setPeriodMeterPair({
    required int leaseId,
    required String kind,
    required int periodId,
    required double current,
    double? previous,
  }) async {
    final period = await getPeriod(periodId);
    if (period == null) throw StateError('账期不存在');
    final db = await database;
    final prevNote = '上期#$periodId';

    // 清掉本账期本期、本账期上期标签，以及旧版无账期 id 的「上期读数」
    await db.delete(
      'meter_readings',
      where: 'lease_id = ? AND kind = ? AND period_id = ?',
      whereArgs: [leaseId, kind, periodId],
    );
    await db.delete(
      'meter_readings',
      where: 'lease_id = ? AND kind = ? AND note = ?',
      whereArgs: [leaseId, kind, prevNote],
    );
    await db.delete(
      'meter_readings',
      where: "lease_id = ? AND kind = ? AND note = '上期读数'",
      whereArgs: [leaseId, kind],
    );

    var prev = previous;
    if (prev == null) {
      // 自动上期：其他账期的「本期」，或更早读数（排除其它账期的上期标签）
      final prior = await db.query(
        'meter_readings',
        where: "lease_id = ? AND kind = ? AND recorded_at < ? "
            "AND (note IS NULL OR note NOT LIKE '上期#%')",
        whereArgs: [
          leaseId,
          kind,
          period.periodStart.toIso8601String(),
        ],
        orderBy: 'recorded_at DESC',
        limit: 1,
      );
      if (prior.isNotEmpty) {
        prev = (prior.first['reading'] as num).toDouble();
      }
    }

    if (prev != null) {
      await insertMeterReading(
        leaseId: leaseId,
        kind: kind,
        reading: prev,
        note: prevNote,
        // 时间戳卡在账期起点前，且带专用 note，展示时优先认这个
        recordedAt: period.periodStart.subtract(const Duration(seconds: 1)),
      );
    }
    await insertMeterReading(
      leaseId: leaseId,
      kind: kind,
      reading: current,
      periodId: periodId,
      note: '本期',
      recordedAt: period.periodEnd.isAfter(DateTime.now())
          ? DateTime.now()
          : period.periodEnd,
    );
  }

  Future<void> deleteInvoicesForPeriod(int periodId) async {
    await (await database).delete(
      'invoices',
      where: 'period_id = ?',
      whereArgs: [periodId],
    );
  }

  Future<List<MeterReading>> recentMeterReadings(int leaseId, {int limit = 20}) async {
    final rows = await (await database).query(
      'meter_readings',
      where: 'lease_id = ?',
      whereArgs: [leaseId],
      orderBy: 'recorded_at DESC',
      limit: limit,
    );
    return rows
        .map(
          (r) => MeterReading(
            id: r['id'] as int,
            leaseId: r['lease_id'] as int,
            kind: r['kind'] as String,
            reading: (r['reading'] as num).toDouble(),
            recordedAt: DateTime.parse(r['recorded_at'] as String),
            periodId: r['period_id'] as int?,
            note: r['note'] as String? ?? '',
          ),
        )
        .toList();
  }

  /// 本期：挂本账期 period_id；上期：优先本账期专用 note「上期#id」（避免被旧读数盖住）。
  Future<MeterPair?> meterPairForPeriod(
    int leaseId,
    String kind,
    RentPeriod period,
  ) async {
    final db = await database;
    final currentRows = await db.query(
      'meter_readings',
      where: 'lease_id = ? AND kind = ? AND period_id = ?',
      whereArgs: [leaseId, kind, period.id],
      orderBy: 'recorded_at DESC',
      limit: 1,
    );
    if (currentRows.isEmpty) {
      return null;
    }
    final currentReading = (currentRows.first['reading'] as num).toDouble();

    final taggedPrev = await db.query(
      'meter_readings',
      where: 'lease_id = ? AND kind = ? AND note = ?',
      whereArgs: [leaseId, kind, '上期#${period.id}'],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (taggedPrev.isNotEmpty) {
      return MeterPair(
        previous: (taggedPrev.first['reading'] as num).toDouble(),
        current: currentReading,
      );
    }

    final currentAt = currentRows.first['recorded_at'] as String;
    final prevRows = await db.query(
      'meter_readings',
      where: "lease_id = ? AND kind = ? AND recorded_at < ? "
          "AND (note IS NULL OR note NOT LIKE '上期#%')",
      whereArgs: [leaseId, kind, currentAt],
      orderBy: 'recorded_at DESC',
      limit: 1,
    );
    if (prevRows.isEmpty) {
      return MeterPair(previous: currentReading, current: currentReading);
    }
    return MeterPair(
      previous: (prevRows.first['reading'] as num).toDouble(),
      current: currentReading,
    );
  }

  Future<void> upsertDiscount({
    required int periodId,
    required double amount,
    String note = '',
  }) async {
    final db = await database;
    if (amount <= 0) {
      await db.delete(
        'period_adjustments',
        where: "period_id = ? AND type = 'discount'",
        whereArgs: [periodId],
      );
      return;
    }
    await db.insert(
      'period_adjustments',
      {
        'period_id': periodId,
        'type': 'discount',
        'amount': amount,
        'note': note,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<double> discountForPeriod(int periodId) async {
    final rows = await (await database).query(
      'period_adjustments',
      where: "period_id = ? AND type = 'discount'",
      whereArgs: [periodId],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return (rows.first['amount'] as num).toDouble();
  }

  Future<String> discountNoteForPeriod(int periodId) async {
    final rows = await (await database).query(
      'period_adjustments',
      where: "period_id = ? AND type = 'discount'",
      whereArgs: [periodId],
      limit: 1,
    );
    if (rows.isEmpty) return '';
    return rows.first['note'] as String? ?? '';
  }

  Future<int> insertInvoice({
    required int periodId,
    required double total,
    required String linesJson,
  }) async {
    return (await database).insert('invoices', {
      'period_id': periodId,
      'total': total,
      'lines_json': linesJson,
      'issued_at': DateTime.now().toIso8601String(),
      ..._newSyncCols(),
    });
  }

  Future<StoredInvoice?> latestInvoiceForPeriod(int periodId) async {
    final rows = await (await database).query(
      'invoices',
      where: 'period_id = ?',
      whereArgs: [periodId],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    final list = (jsonDecode(r['lines_json'] as String) as List)
        .map((e) => BillLine.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return StoredInvoice(
      id: r['id'] as int,
      periodId: r['period_id'] as int,
      total: (r['total'] as num).toDouble(),
      issuedAt: DateTime.parse(r['issued_at'] as String),
      lines: list,
    );
  }

  Future<void> updatePeriodAmountStatus(
    int periodId, {
    required double amount,
    required String status,
  }) async {
    await (await database).update(
      'rent_periods',
      {'amount': amount, 'status': status},
      where: 'id = ?',
      whereArgs: [periodId],
    );
  }

  Lease _leaseFrom(
    Map<String, Object?> r,
    List<LeaseExtraItem> extras, {
    int? leaseIdOverride,
  }) {
    final id = leaseIdOverride ?? (r['id'] as int? ?? r['lease_id'] as int);
    final status = (r['lease_status'] as String?) ?? (r['status'] as String);
    return Lease(
      id: id,
      roomId: r['room_id'] as int,
      tenantId: r['tenant_id'] as int,
      startDate: parseYmd(r['start_date'] as String)!,
      endDate: parseYmd(r['end_date'] as String?),
      rentDueDay: r['rent_due_day'] as int,
      baseRent: (r['base_rent'] as num).toDouble(),
      deposit: (r['deposit'] as num).toDouble(),
      status: status,
      electricPrice: (r['electric_price'] as num?)?.toDouble() ?? 0,
      waterPrice: (r['water_price'] as num?)?.toDouble() ?? 0,
      gasPrice: (r['gas_price'] as num?)?.toDouble() ?? 0,
      extras: extras,
      fixedExtra: (r['fixed_extra'] as num?)?.toDouble() ?? 0,
      fixedExtraLabel: (r['fixed_extra_label'] as String?) ?? '固定杂费',
    );
  }

  Tenant _tenantFrom(Map<String, Object?> r) => Tenant(
        id: r['id'] as int,
        name: r['name'] as String,
        phone: r['phone'] as String,
      );

  RentPeriod _periodFrom(Map<String, Object?> r) => RentPeriod(
        id: r['id'] as int,
        leaseId: r['lease_id'] as int,
        periodStart: parseYmd(r['period_start'] as String)!,
        periodEnd: parseYmd(r['period_end'] as String)!,
        dueDate: parseYmd(r['due_date'] as String)!,
        amount: (r['amount'] as num).toDouble(),
        status: r['status'] as String,
      );

  // --- chat sessions ---

  Future<List<ChatSession>> listChatSessions() async {
    final rows = await (await database).query(
      'chat_sessions',
      orderBy: 'updated_at DESC',
    );
    return rows.map(_sessionFrom).toList();
  }

  Future<ChatSession?> getChatSession(String id) async {
    final rows = await (await database).query(
      'chat_sessions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _sessionFrom(rows.first);
  }

  Future<void> upsertChatSession(ChatSession session) async {
    await (await database).insert(
      'chat_sessions',
      {
        'id': session.id,
        'title': session.title,
        'sticky_json': session.sticky.encode(),
        'created_at': session.createdAt.toIso8601String(),
        'updated_at': session.updatedAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateChatSessionSticky(String id, SessionSticky sticky) async {
    await (await database).update(
      'chat_sessions',
      {
        'sticky_json': sticky.encode(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateChatSessionTitle(String id, String title) async {
    await (await database).update(
      'chat_sessions',
      {
        'title': title,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> touchChatSession(String id) async {
    await (await database).update(
      'chat_sessions',
      {'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteChatSession(String id) async {
    final db = await database;
    await db.delete('chat_messages', where: 'session_id = ?', whereArgs: [id]);
    await db.delete('chat_sessions', where: 'id = ?', whereArgs: [id]);
  }

  /// 滚动清理聊天占用：按会话数/每会话条数裁剪，不按「自然月」一刀切。
  /// [preserveSessionId] 当前正在用的会话不会被删。
  Future<ChatPruneReport> pruneChatStorage({
    String? preserveSessionId,
    int maxSessions = 40,
    int maxMessagesPerSession = 250,
  }) async {
    final db = await database;
    var deletedSessions = 0;
    var trimmedMessages = 0;

    // 会话按 updated_at DESC；保留最近若干个，并始终保住当前会话
    final sessions = await listChatSessions();
    final keep = <String>{};
    for (final s in sessions) {
      if (keep.length >= maxSessions) break;
      keep.add(s.id);
    }
    if (preserveSessionId != null) keep.add(preserveSessionId);
    for (final s in sessions) {
      if (keep.contains(s.id)) continue;
      await deleteChatSession(s.id);
      deletedSessions++;
    }

    final remaining = await listChatSessions();
    for (final s in remaining) {
      final countRows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM chat_messages WHERE session_id = ?',
        [s.id],
      );
      final count = (countRows.first['c'] as num?)?.toInt() ?? 0;
      if (count <= maxMessagesPerSession) continue;

      final overflow = count - maxMessagesPerSession;
      await db.rawDelete(
        '''
        DELETE FROM chat_messages WHERE id IN (
          SELECT id FROM chat_messages
          WHERE session_id = ?
          ORDER BY id ASC
          LIMIT ?
        )
        ''',
        [s.id, overflow],
      );
      trimmedMessages += overflow;

      final sticky = s.sticky;
      const tip = '（较早闲聊已自动清理，关键信息仍记在便签里）';
      if (sticky.summary == null || !sticky.summary!.contains('已自动清理')) {
        sticky.summary = (sticky.summary == null || sticky.summary!.isEmpty)
            ? tip
            : '${sticky.summary}\n$tip';
        await updateChatSessionSticky(s.id, sticky);
      }
    }

    return ChatPruneReport(
      deletedSessions: deletedSessions,
      trimmedMessages: trimmedMessages,
    );
  }

  Future<List<StoredChatMessage>> listChatMessages(String sessionId) async {
    final rows = await (await database).query(
      'chat_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'id ASC',
    );
    return rows.map(_messageFrom).toList();
  }

  Future<int> insertChatMessage(StoredChatMessage m) async {
    return (await database).insert('chat_messages', {
      'session_id': m.sessionId,
      'role': m.role.name,
      'text': m.text,
      'pending_json': m.pending == null
          ? null
          : jsonEncode({
              'id': m.pending!.id,
              'tool': m.pending!.tool,
              'args': m.pending!.args,
              'summary': m.pending!.summary,
            }),
      'confirmed': m.confirmed == null
          ? null
          : (m.confirmed! ? 1 : 0),
      'created_at': m.createdAt.toIso8601String(),
    });
  }

  Future<void> updateChatMessageConfirmation({
    required int id,
    required bool confirmed,
  }) async {
    await (await database).update(
      'chat_messages',
      {'confirmed': confirmed ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  ChatSession _sessionFrom(Map<String, Object?> r) => ChatSession(
        id: r['id'] as String,
        title: r['title'] as String,
        sticky: SessionSticky.decode(r['sticky_json'] as String?),
        createdAt: DateTime.parse(r['created_at'] as String),
        updatedAt: DateTime.parse(r['updated_at'] as String),
      );

  StoredChatMessage _messageFrom(Map<String, Object?> r) {
    PendingAction? pending;
    final raw = r['pending_json'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        final j = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        pending = PendingAction(
          id: j['id'] as String,
          tool: j['tool'] as String,
          args: Map<String, dynamic>.from(j['args'] as Map? ?? {}),
          summary: j['summary'] as String? ?? '',
        );
      } catch (_) {}
    }
    final conf = r['confirmed'] as int?;
    return StoredChatMessage(
      id: r['id'] as int,
      sessionId: r['session_id'] as String,
      role: ChatRole.values.firstWhere(
        (e) => e.name == r['role'],
        orElse: () => ChatRole.assistant,
      ),
      text: r['text'] as String,
      pending: pending,
      confirmed: conf == null ? null : conf == 1,
      createdAt: DateTime.parse(r['created_at'] as String),
    );
  }
}
