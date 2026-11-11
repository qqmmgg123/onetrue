import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:postgres/postgres.dart';

import '../data/app_database.dart';
import '../domain/models.dart';
import 'neon_connection.dart';
import 'sync_settings.dart';

class SyncReport {
  SyncReport({
    this.pushed = 0,
    this.pulled = 0,
    this.skipped = 0,
    this.error,
  });

  int pushed;
  int pulled;
  int skipped;
  String? error;

  bool get ok => error == null;
}

typedef SyncProgress = void Function(String message);

/// 待上传的本地行（表名 + 本地 id）。
typedef SyncRef = ({String table, int id});

/// 服务端权威同步：本地 SQLite 仅缓存。
/// 写入后按行直推 Neon；打开/回前台只拉并覆盖本地。无 dirty 队列、无 LWW。
class SyncService {
  SyncService({
    AppDatabase? db,
    SyncSettings? settings,
  })  : _db = db ?? AppDatabase.instance,
        _settings = settings ?? SyncSettings.instance;

  final AppDatabase _db;
  final SyncSettings _settings;

  /// 互斥：同时只跑一路推/拉。
  static Completer<void>? _lock;
  static bool _abortFlag = false;

  bool get _aborted => _abortFlag;

  /// 有外键依赖，顺序不能乱。
  static const _syncOrder = [
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
    'notes',
  ];

  static const _tableLabel = {
    'properties': '房产',
    'rooms': '房间',
    'tenants': '租户',
    'leases': '租约',
    'lease_extras': '附加费',
    'rent_periods': '账期',
    'meter_readings': '抄表',
    'period_adjustments': '优惠/费用',
    'invoices': '清单',
    'payments': '收款',
    'notes': '笔记',
  };

  /// 打开/回前台/刷新：只拉「当前登录用户」数据覆盖本地缓存。
  /// [forceFull] 或无 last_sync_at / 游标过久 → 全量；否则按 updated_at 增量。
  Future<SyncReport> refreshMyCache({
    bool forceFull = false,
    SyncProgress? onProgress,
  }) async {
    void tip(String m) => onProgress?.call(m);
    tip('检查同步配置…');
    await _settings.load();
    if (!_settings.configured) {
      return SyncReport(error: 'sync_disabled');
    }

    if (_lock != null) {
      tip('等待上一次同步结束…');
      await _lock!.future;
    }

    final held = Completer<void>();
    _lock = held;
    _abortFlag = false;
    final report = SyncReport();
    PostgreSQLConnection? conn;
    try {
      await _db.database;
      tip('连接数据库…');
      conn = await _openWithRetry();

      final since = await _db.getSyncState('last_sync_at');
      var full = forceFull || since == null || since.isEmpty;
      if (!full) {
        final t = DateTime.tryParse(since);
        if (t == null ||
            DateTime.now().toUtc().difference(t.toUtc()).inDays >= 7) {
          full = true;
        }
      }
      tip(full ? '下载我的数据（全量）…' : '下载我的数据（增量）…');
      report.pulled = await _pullRemote(
        conn,
        full: full,
        onProgress: tip,
      );
      await _db.setSyncState(
        'last_sync_at',
        DateTime.now().toUtc().toIso8601String(),
      );
      tip('刷新完成');
    } catch (e, st) {
      debugPrint('refreshMyCache failed: $e\n$st');
      report.error = '$e';
      tip('刷新失败');
    } finally {
      try {
        await conn?.close();
      } catch (_) {}
      if (identical(_lock, held)) {
        _lock = null;
      }
      _abortFlag = false;
      held.complete();
    }
    return report;
  }

  /// 业务写入后：按行直推 Neon（含父行）。失败返回 error。
  Future<SyncReport> pushLocalRows(
    List<SyncRef> refs, {
    SyncProgress? onProgress,
  }) async {
    void tip(String m) => onProgress?.call(m);
    await _settings.load();
    if (!_settings.configured) {
      return SyncReport(error: '未登录或未配置同步，无法保存到云端');
    }
    if (refs.isEmpty) return SyncReport();

    if (_lock != null) {
      await _lock!.future;
    }
    final held = Completer<void>();
    _lock = held;
    _abortFlag = false;
    final report = SyncReport();
    PostgreSQLConnection? conn;
    try {
      tip('上传…');
      conn = await _openWithRetry();
      final ordered = _orderedUnique(refs);
      for (final ref in ordered) {
        if (_aborted) break;
        final label = _tableLabel[ref.table] ?? ref.table;
        tip('上传$label…');
        final ok = await _upsertLocalById(conn, ref.table, ref.id);
        if (ok) {
          report.pushed++;
        } else {
          report.skipped++;
        }
      }
      if (report.pushed == 0 && report.skipped > 0) {
        report.error = '部分数据未能上传，请稍后重试';
      }
      tip('上传完成');
    } catch (e, st) {
      debugPrint('pushLocalRows failed: $e\n$st');
      report.error = '$e';
    } finally {
      try {
        await conn?.close();
      } catch (_) {}
      if (identical(_lock, held)) {
        _lock = null;
      }
      _abortFlag = false;
      held.complete();
    }
    return report;
  }

  /// 登录认领：按表顺序上传全部本地业务行。
  Future<SyncReport> uploadAllLocal({SyncProgress? onProgress}) async {
    final refs = <SyncRef>[];
    final db = await _db.database;
    for (final table in _syncOrder) {
      final rows = await db.query(table, columns: ['id']);
      for (final r in rows) {
        refs.add((table: table, id: r['id'] as int));
      }
    }
    onProgress?.call('上传本机数据（${refs.length} 条）…');
    return pushLocalRows(refs, onProgress: onProgress);
  }

  /// 租约整树（含租户/附加费/账期及账期子表），供登记/改约后上传。
  Future<List<SyncRef>> refsForLease(int leaseId) async {
    final db = await _db.database;
    final leases = await db.query(
      'leases',
      where: 'id = ?',
      whereArgs: [leaseId],
      limit: 1,
    );
    if (leases.isEmpty) return const [];
    final lease = leases.first;
    final refs = <SyncRef>[
      (table: 'leases', id: leaseId),
      (table: 'tenants', id: lease['tenant_id'] as int),
      (table: 'rooms', id: lease['room_id'] as int),
    ];
    for (final r in await db.query(
      'lease_extras',
      columns: ['id'],
      where: 'lease_id = ?',
      whereArgs: [leaseId],
    )) {
      refs.add((table: 'lease_extras', id: r['id'] as int));
    }
    final periods = await db.query(
      'rent_periods',
      columns: ['id'],
      where: 'lease_id = ?',
      whereArgs: [leaseId],
    );
    for (final p in periods) {
      refs.addAll(await refsForPeriod(p['id'] as int));
    }
    for (final r in await db.query(
      'meter_readings',
      columns: ['id'],
      where: 'lease_id = ? AND period_id IS NULL',
      whereArgs: [leaseId],
    )) {
      refs.add((table: 'meter_readings', id: r['id'] as int));
    }
    return refs;
  }

  /// 账期及其抄表/调账/清单/收款。
  Future<List<SyncRef>> refsForPeriod(int periodId) async {
    final refs = <SyncRef>[(table: 'rent_periods', id: periodId)];
    final db = await _db.database;
    for (final table in [
      'meter_readings',
      'period_adjustments',
      'invoices',
      'payments',
    ]) {
      final rows = await db.query(
        table,
        columns: ['id'],
        where: 'period_id = ?',
        whereArgs: [periodId],
      );
      for (final r in rows) {
        refs.add((table: table, id: r['id'] as int));
      }
    }
    return refs;
  }

  List<SyncRef> _orderedUnique(List<SyncRef> refs) {
    final seen = <String>{};
    final list = <SyncRef>[];
    for (final r in refs) {
      final key = '${r.table}:${r.id}';
      if (seen.add(key)) list.add(r);
    }
    list.sort((a, b) {
      final ai = _syncOrder.indexOf(a.table);
      final bi = _syncOrder.indexOf(b.table);
      final ao = ai < 0 ? 999 : ai;
      final bo = bi < 0 ? 999 : bi;
      if (ao != bo) return ao.compareTo(bo);
      return a.id.compareTo(b.id);
    });
    return list;
  }

  Future<PostgreSQLConnection> _openWithRetry() async {
    Object? last;
    for (var i = 0; i < 3; i++) {
      try {
        final ep = NeonEndpoint.parse(_settings.databaseUrl);
        return await ep.open();
      } catch (e) {
        last = e;
        await Future<void>.delayed(Duration(milliseconds: 400 * (i + 1)));
      }
    }
    throw StateError('连接 Neon 失败（已重试）：$last');
  }

  Future<bool> _ensureParentsRemote(
    PostgreSQLConnection conn,
    String table,
    Map<String, Object?> row,
  ) async {
    switch (table) {
      case 'rooms':
        return _upsertLocalById(conn, 'properties', row['property_id'] as int);
      case 'leases':
        return await _upsertLocalById(conn, 'rooms', row['room_id'] as int) &&
            await _upsertLocalById(conn, 'tenants', row['tenant_id'] as int);
      case 'lease_extras':
      case 'rent_periods':
        return _upsertLocalById(conn, 'leases', row['lease_id'] as int);
      case 'meter_readings':
        if (!await _upsertLocalById(conn, 'leases', row['lease_id'] as int)) {
          return false;
        }
        final pid = row['period_id'] as int?;
        if (pid != null) {
          return _upsertLocalById(conn, 'rent_periods', pid);
        }
        return true;
      case 'period_adjustments':
      case 'invoices':
      case 'payments':
        return _upsertLocalById(conn, 'rent_periods', row['period_id'] as int);
      default:
        return true;
    }
  }

  Future<bool> _upsertLocalById(
    PostgreSQLConnection conn,
    String table,
    int localId,
  ) async {
    final rows = await (await _db.database).query(
      table,
      where: 'id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final row = rows.first;
    if (!await _ensureParentsRemote(conn, table, row)) return false;
    final payload = await _toRemotePayload(table, row);
    if (payload == null) return false;
    await _upsertRemote(conn, table, payload);
    return true;
  }

  /// 直写远端：冲突则覆盖（服务端权威写入，无乐观锁）。
  Future<bool> _upsertRemote(
    PostgreSQLConnection conn,
    String table,
    Map<String, dynamic> payload,
  ) async {
    final keys = payload.keys.toList();
    final cols = keys.join(', ');
    final ph = List.generate(keys.length, (i) => '@p$i').join(', ');
    final values = <String, dynamic>{};
    for (var i = 0; i < keys.length; i++) {
      values['p$i'] = _pgValue(payload[keys[i]]);
    }
    final updates = keys
        .where((k) => k != 'id')
        .map((k) => '$k = EXCLUDED.$k')
        .join(', ');
    await conn.query(
      'INSERT INTO $table ($cols) VALUES ($ph) '
      'ON CONFLICT (id) DO UPDATE SET $updates',
      substitutionValues: values,
    );
    return true;
  }

  Object? _pgValue(Object? v) {
    if (v == null) return null;
    if (v is DateTime || v is num || v is bool) return v;
    return '$v';
  }

  Future<int> _pullRemote(
    PostgreSQLConnection conn, {
    bool full = false,
    SyncProgress? onProgress,
  }) async {
    final since = full ? null : await _db.getSyncState('last_sync_at');
    var count = 0;
    var tableIndex = 0;
    for (final table in _syncOrder) {
      if (_aborted) break;
      tableIndex++;
      final label = _tableLabel[table] ?? table;
      onProgress?.call(
        full
            ? '下载$label（$tableIndex/${_syncOrder.length}）…'
            : '检查线上$label更新…',
      );
      final PostgreSQLResult rows;
      if (since != null && since.isNotEmpty) {
        // 减 2 分钟容错：避免时钟/毫秒精度漏拉
        rows = await conn.query(
          'SELECT * FROM $table '
          'WHERE owner_id = CAST(@owner AS uuid) '
          'AND updated_at > (CAST(@since AS timestamptz) - interval \'2 minutes\') '
          'ORDER BY updated_at ASC',
          substitutionValues: {
            'owner': _settings.ownerId,
            'since': since,
          },
        );
      } else {
        rows = await conn.query(
          'SELECT * FROM $table '
          'WHERE owner_id = CAST(@owner AS uuid) '
          'ORDER BY updated_at ASC',
          substitutionValues: {'owner': _settings.ownerId},
        );
      }
      var n = 0;
      final renamed = <String>[];
      for (final row in rows) {
        if (_aborted) break;
        final map = _mapRow(row);
        final applied = await _applyRemoteRow(table, map);
        if (applied) {
          count++;
          n++;
          if (table == 'properties') {
            final name = '${map['name'] ?? ''}';
            if (name.isNotEmpty) renamed.add(name);
          }
        }
      }
      if (table == 'properties' && renamed.isNotEmpty) {
        onProgress?.call('房产：${renamed.join('、')}');
      }
      if (n > 0) {
        onProgress?.call('已更新$label $n 条');
      }
    }
    return count;
  }

  Map<String, dynamic> _mapRow(PostgreSQLResultRow row) {
    final out = <String, dynamic>{};
    row.toColumnMap().forEach((key, value) {
      out[key] = _normalizeRemote(value);
    });
    return out;
  }

  Object? _normalizeRemote(Object? v) {
    if (v == null) return null;
    if (v is DateTime) return v.toUtc().toIso8601String();
    if (v is BigInt) return v.toInt();
    // numeric / decimal
    if (v is double || v is int) return v;
    return v;
  }

  Future<Map<String, dynamic>?> _toRemotePayload(
    String table,
    Map<String, Object?> row,
  ) async {
    final uuid = row['uuid'] as String?;
    if (uuid == null || uuid.isEmpty) return null;
    final updatedAt = row['updated_at'] as String? ??
        DateTime.now().toUtc().toIso8601String();
    final base = <String, dynamic>{
      'id': uuid,
      'updated_at': updatedAt,
      'deleted_at': row['deleted_at'],
      'owner_id': _settings.ownerId,
    };

    switch (table) {
      case 'properties':
        return {
          ...base,
          'name': row['name'],
          'address': row['address'] ?? '',
          'city': row['city'] ?? '',
        };
      case 'rooms':
        final prop = await _uuidOf('properties', row['property_id'] as int);
        if (prop == null) return null;
        return {
          ...base,
          'property_id': prop,
          'label': row['label'],
          'video_url': row['video_url'] ?? '',
          'video_poster_url': row['video_poster_url'] ?? '',
          'listing_status': row['listing_status'] ?? 'draft',
          'listed_at': row['listed_at'],
        };
      case 'tenants':
        return {
          ...base,
          'name': row['name'],
          'phone': row['phone'] ?? '',
        };
      case 'notes':
        return {
          ...base,
          'kind': row['kind'] ?? 'note',
          'title': row['title'] ?? '',
          'body': row['body'] ?? '',
          'format': row['format'] ?? 'plain',
          'schedule_at': row['schedule_at'],
          'remind_at': row['remind_at'],
          'recur_freq': row['recur_freq'] ?? '',
          'recur_interval': row['recur_interval'] ?? 1,
          'recur_byday': row['recur_byday'],
          'recur_until': row['recur_until'],
          'recur_count': row['recur_count'],
          'remind_offset_min': row['remind_offset_min'] ?? 0,
          'listing_status': row['listing_status'] ?? 'draft',
          'listed_at': row['listed_at'],
          'city': row['city'] ?? '',
          'parent_uuid': row['parent_uuid'],
          'sort_order': row['sort_order'] ?? 0,
          'source_note_uuids': row['source_note_uuids'] ?? '[]',
        };
      case 'leases':
        final room = await _uuidOf('rooms', row['room_id'] as int);
        final tenant = await _uuidOf('tenants', row['tenant_id'] as int);
        if (room == null || tenant == null) return null;
        return {
          ...base,
          'room_id': room,
          'tenant_id': tenant,
          'start_date': row['start_date'],
          'end_date': row['end_date'],
          'rent_due_day': row['rent_due_day'],
          'base_rent': row['base_rent'],
          'deposit': row['deposit'],
          'status': row['status'],
          'electric_price': row['electric_price'] ?? 0,
          'water_price': row['water_price'] ?? 0,
          'gas_price': row['gas_price'] ?? 0,
          'fixed_extra': row['fixed_extra'] ?? 0,
          'fixed_extra_label': row['fixed_extra_label'] ?? '固定杂费',
        };
      case 'lease_extras':
        final lease = await _uuidOf('leases', row['lease_id'] as int);
        if (lease == null) return null;
        return {
          ...base,
          'lease_id': lease,
          'name': row['name'],
          'amount': row['amount'],
          'sort_order': row['sort_order'] ?? 0,
        };
      case 'rent_periods':
        final lease = await _uuidOf('leases', row['lease_id'] as int);
        if (lease == null) return null;
        return {
          ...base,
          'lease_id': lease,
          'period_start': row['period_start'],
          'period_end': row['period_end'],
          'due_date': row['due_date'],
          'amount': row['amount'],
          'status': row['status'],
          'remark': row['remark'] ?? '',
        };
      case 'meter_readings':
        final lease = await _uuidOf('leases', row['lease_id'] as int);
        if (lease == null) return null;
        String? periodUuid;
        final pid = row['period_id'] as int?;
        if (pid != null) {
          periodUuid = await _uuidOf('rent_periods', pid);
          if (periodUuid == null) return null;
        }
        return {
          ...base,
          'lease_id': lease,
          'kind': row['kind'],
          'reading': row['reading'],
          'recorded_at': row['recorded_at'],
          'period_id': periodUuid,
          'note': row['note'] ?? '',
        };
      case 'period_adjustments':
        final period = await _uuidOf('rent_periods', row['period_id'] as int);
        if (period == null) return null;
        return {
          ...base,
          'period_id': period,
          'type': row['type'] ?? 'discount',
          'amount': row['amount'],
          'note': row['note'] ?? '',
        };
      case 'invoices':
        final period = await _uuidOf('rent_periods', row['period_id'] as int);
        if (period == null) return null;
        return {
          ...base,
          'period_id': period,
          'total': row['total'],
          'lines_json': row['lines_json'],
          'issued_at': row['issued_at'],
        };
      case 'payments':
        final period = await _uuidOf('rent_periods', row['period_id'] as int);
        if (period == null) return null;
        return {
          ...base,
          'period_id': period,
          'amount': row['amount'],
          'paid_at': row['paid_at'],
          'note': row['note'] ?? '',
        };
      default:
        return null;
    }
  }

  Future<String?> _uuidOf(String table, int localId) async {
    final rows = await (await _db.database).query(
      table,
      columns: ['uuid'],
      where: 'id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['uuid'] as String?;
  }

  Future<int?> _localIdOfUuid(String table, String uuid) async {
    final row = await _db.rowByUuid(table, uuid);
    if (row == null) return null;
    return row['id'] as int?;
  }

  Future<bool> _upsertByUuid(
    String table,
    String uuid,
    Map<String, Object?> data,
    Map<String, Object?>? local,
  ) async {
    final db = await _db.database;
    final row = {
      ...data,
      'uuid': uuid,
    };
    if (local == null) {
      await db.insert(table, row);
    } else {
      await db.update(
        table,
        row,
        where: 'id = ?',
        whereArgs: [local['id']],
      );
    }
    return true;
  }

  String _asDate(Object? v) {
    if (v == null) return '';
    final s = '$v';
    if (s.length >= 10) return s.substring(0, 10);
    return s;
  }

  /// 远程覆盖本地缓存（服务端权威）。
  Future<bool> _applyRemoteRow(
    String table,
    Map<String, dynamic> remote,
  ) async {
    final uuid = '${remote['id']}';
    final remoteUpdated = '${remote['updated_at']}';
    var local = await _db.rowByUuid(table, uuid);
    final db = await _db.database;

    switch (table) {
      case 'properties':
        return _upsertByUuid(
          table,
          uuid,
          {
            'name': remote['name'],
            'address': remote['address'] ?? '',
            'city': remote['city'] ?? '',
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
          },
          local,
        );
      case 'rooms':
        final propId =
            await _localIdOfUuid('properties', '${remote['property_id']}');
        if (propId == null) return false;
        return _upsertByUuid(
          table,
          uuid,
          {
            'property_id': propId,
            'label': remote['label'],
            'video_url': remote['video_url'] ?? '',
            'video_poster_url': remote['video_poster_url'] ?? '',
            'listing_status': remote['listing_status'] ?? 'draft',
            'listed_at': remote['listed_at'] == null
                ? null
                : _normalizeRemote(remote['listed_at']),
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
          },
          local,
        );
      case 'tenants':
        return _upsertByUuid(
          table,
          uuid,
          {
            'name': remote['name'],
            'phone': remote['phone'] ?? '',
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
          },
          local,
        );
      case 'leases':
        final roomId = await _localIdOfUuid('rooms', '${remote['room_id']}');
        final tenantId =
            await _localIdOfUuid('tenants', '${remote['tenant_id']}');
        if (roomId == null || tenantId == null) return false;
        return _upsertByUuid(
          table,
          uuid,
          {
            'room_id': roomId,
            'tenant_id': tenantId,
            'start_date': _asDate(remote['start_date']),
            'end_date': remote['end_date'] == null
                ? null
                : _asDate(remote['end_date']),
            'rent_due_day': remote['rent_due_day'],
            'base_rent': remote['base_rent'],
            'deposit': remote['deposit'],
            'status': remote['status'],
            'electric_price': remote['electric_price'] ?? 0,
            'water_price': remote['water_price'] ?? 0,
            'gas_price': remote['gas_price'] ?? 0,
            'fixed_extra': remote['fixed_extra'] ?? 0,
            'fixed_extra_label': remote['fixed_extra_label'] ?? '固定杂费',
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
          },
          local,
        );
      case 'lease_extras':
        final leaseId = await _localIdOfUuid('leases', '${remote['lease_id']}');
        if (leaseId == null) return false;
        return _upsertByUuid(
          table,
          uuid,
          {
            'lease_id': leaseId,
            'name': remote['name'],
            'amount': remote['amount'],
            'sort_order': remote['sort_order'] ?? 0,
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
          },
          local,
        );
      case 'rent_periods':
        final leaseId = await _localIdOfUuid('leases', '${remote['lease_id']}');
        if (leaseId == null) return false;
        if (local == null) {
          final dup = await db.query(
            'rent_periods',
            where: 'lease_id = ? AND period_start = ?',
            whereArgs: [leaseId, _asDate(remote['period_start'])],
            limit: 1,
          );
          if (dup.isNotEmpty) local = dup.first;
        }
        return _upsertByUuid(
          table,
          uuid,
          {
            'lease_id': leaseId,
            'period_start': _asDate(remote['period_start']),
            'period_end': _asDate(remote['period_end']),
            'due_date': _asDate(remote['due_date']),
            'amount': remote['amount'],
            'status': remote['status'],
            'remark': remote['remark'] ?? '',
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
          },
          local,
        );
      case 'meter_readings':
        final leaseId = await _localIdOfUuid('leases', '${remote['lease_id']}');
        if (leaseId == null) return false;
        int? periodId;
        if (remote['period_id'] != null) {
          periodId =
              await _localIdOfUuid('rent_periods', '${remote['period_id']}');
          if (periodId == null) return false;
        }
        return _upsertByUuid(
          table,
          uuid,
          {
            'lease_id': leaseId,
            'kind': remote['kind'],
            'reading': remote['reading'],
            'recorded_at': remote['recorded_at'],
            'period_id': periodId,
            'note': remote['note'] ?? '',
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
          },
          local,
        );
      case 'period_adjustments':
        final periodId =
            await _localIdOfUuid('rent_periods', '${remote['period_id']}');
        if (periodId == null) return false;
        if (local == null) {
          final dup = await db.query(
            'period_adjustments',
            where: 'period_id = ? AND type = ?',
            whereArgs: [periodId, remote['type'] ?? 'discount'],
            limit: 1,
          );
          if (dup.isNotEmpty) local = dup.first;
        }
        return _upsertByUuid(
          table,
          uuid,
          {
            'period_id': periodId,
            'type': remote['type'] ?? 'discount',
            'amount': remote['amount'],
            'note': remote['note'] ?? '',
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
          },
          local,
        );
      case 'invoices':
        final periodId =
            await _localIdOfUuid('rent_periods', '${remote['period_id']}');
        if (periodId == null) return false;
        return _upsertByUuid(
          table,
          uuid,
          {
            'period_id': periodId,
            'total': remote['total'],
            'lines_json': remote['lines_json'],
            'issued_at': remote['issued_at'],
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
          },
          local,
        );
      case 'payments':
        final periodId =
            await _localIdOfUuid('rent_periods', '${remote['period_id']}');
        if (periodId == null) return false;
        return _upsertByUuid(
          table,
          uuid,
          {
            'period_id': periodId,
            'amount': remote['amount'],
            'paid_at': remote['paid_at'],
            'note': remote['note'] ?? '',
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
          },
          local,
        );
      case 'notes':
        return _upsertByUuid(
          table,
          uuid,
          {
            'kind': remote['kind'] ?? 'note',
            'title': remote['title'] ?? '',
            'body': remote['body'] ?? '',
            'format': remote['format'] ?? 'plain',
            'schedule_at': remote['schedule_at'],
            'remind_at': remote['remind_at'],
            'recur_freq': remote['recur_freq'] ?? '',
            'recur_interval': remote['recur_interval'] ?? 1,
            'recur_byday': remote['recur_byday'],
            'recur_until': remote['recur_until'],
            'recur_count': remote['recur_count'],
            'remind_offset_min': remote['remind_offset_min'] ?? 0,
            'listing_status': remote['listing_status'] ?? 'draft',
            'listed_at': remote['listed_at'],
            'city': remote['city'] ?? '',
            'parent_uuid': remote['parent_uuid']?.toString(),
            'sort_order': remote['sort_order'] ?? 0,
            'source_note_uuids': remote['source_note_uuids'] is String
                ? remote['source_note_uuids']
                : '${remote['source_note_uuids'] ?? '[]'}',
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
          },
          local,
        );
      default:
        return false;
    }
  }

  /// 市集：只读拉取已上架房源（不按当前 owner 过滤，不写入本地库）。
  Future<List<MarketplaceListing>> fetchListedRooms({String? city}) async {
    await _settings.load();
    final url = _settings.databaseUrl.trim();
    if (url.isEmpty) {
      throw StateError('未配置数据库，无法浏览市集房源');
    }
    final conn = await NeonEndpoint.parse(url).open();
    try {
      final cityFilter = city?.trim() ?? '';
      final rows = await conn.query(
        '''
        SELECT
          r.id AS room_id,
          p.id AS property_id,
          p.name AS property_name,
          p.city AS city,
          p.address AS address,
          r.label AS room_label,
          r.video_url AS video_url,
          r.video_poster_url AS video_poster_url,
          r.listed_at AS listed_at
        FROM rooms r
        JOIN properties p ON p.id = r.property_id
        WHERE r.deleted_at IS NULL
          AND p.deleted_at IS NULL
          AND r.listing_status = 'listed'
          AND (@city = '' OR p.city = @city)
        ORDER BY r.listed_at DESC NULLS LAST, r.updated_at DESC
        LIMIT 200
        ''',
        substitutionValues: {'city': cityFilter},
      );
      return rows.map((row) {
        DateTime? listedAt;
        final raw = row[8];
        if (raw is DateTime) {
          listedAt = raw.toUtc();
        } else if (raw != null) {
          listedAt = DateTime.tryParse('$raw');
        }
        return MarketplaceListing(
          roomUuid: '${row[0]}',
          propertyUuid: '${row[1]}',
          propertyName: '${row[2] ?? ''}',
          city: '${row[3] ?? ''}',
          address: '${row[4] ?? ''}',
          roomLabel: '${row[5] ?? ''}',
          videoUrl: '${row[6] ?? ''}',
          videoPosterUrl: '${row[7] ?? ''}',
          listedAt: listedAt,
        );
      }).toList();
    } finally {
      await conn.close();
    }
  }

  /// 市集：已上架文章。
  Future<List<MarketplaceArticle>> fetchListedArticles({
    String? city,
    String? ownerId,
  }) async {
    await _settings.load();
    final url = _settings.databaseUrl.trim();
    if (url.isEmpty) {
      throw StateError('未配置数据库，无法浏览市集文章');
    }
    final conn = await NeonEndpoint.parse(url).open();
    try {
      final cityFilter = city?.trim() ?? '';
      final ownerFilter = ownerId?.trim() ?? '';
      final rows = await conn.query(
        '''
        SELECT
          n.id,
          n.title,
          n.body,
          n.format,
          n.city,
          n.listed_at,
          n.owner_id,
          COALESCE(s.view_count, 0)
        FROM notes n
        LEFT JOIN note_stats s ON s.note_id = n.id
        WHERE n.deleted_at IS NULL
          AND n.kind = 'article'
          AND n.listing_status = 'listed'
          AND (@city = '' OR n.city = @city OR n.city = '')
          AND (@owner = '' OR n.owner_id::text = @owner)
        ORDER BY n.listed_at DESC NULLS LAST, n.updated_at DESC
        LIMIT 200
        ''',
        substitutionValues: {
          'city': cityFilter,
          'owner': ownerFilter,
        },
      );
      return rows.map(_articleFromRow).toList();
    } finally {
      await conn.close();
    }
  }

  MarketplaceArticle _articleFromRow(dynamic row) {
    DateTime? listedAt;
    final raw = row[5];
    if (raw is DateTime) {
      listedAt = raw.toUtc();
    } else if (raw != null) {
      listedAt = DateTime.tryParse('$raw');
    }
    final vc = row[7];
    return MarketplaceArticle(
      noteUuid: '${row[0]}',
      title: '${row[1] ?? ''}',
      body: '${row[2] ?? ''}',
      format: '${row[3] ?? 'plain'}',
      city: '${row[4] ?? ''}',
      listedAt: listedAt,
      ownerId: '${row[6] ?? ''}',
      viewCount: vc is int ? vc : int.tryParse('$vc') ?? 0,
    );
  }

  /// 非作者访问：累计文章浏览次数。
  Future<void> incrementArticleView({
    required String noteUuid,
    String? viewerId,
  }) async {
    final id = noteUuid.trim();
    if (id.isEmpty) return;
    await _settings.load();
    final url = _settings.databaseUrl.trim();
    if (url.isEmpty) return;
    final conn = await NeonEndpoint.parse(url).open();
    try {
      final viewer = viewerId?.trim() ?? '';
      await conn.execute(
        '''
        INSERT INTO note_stats (note_id, view_count)
        SELECT n.id, 1
        FROM notes n
        WHERE n.id = @id::uuid
          AND n.deleted_at IS NULL
          AND n.kind = 'article'
          AND (@viewer = '' OR n.owner_id::text IS DISTINCT FROM @viewer)
        ON CONFLICT (note_id) DO UPDATE
        SET view_count = note_stats.view_count + 1
        WHERE EXISTS (
          SELECT 1 FROM notes n2
          WHERE n2.id = note_stats.note_id
            AND (@viewer = '' OR n2.owner_id::text IS DISTINCT FROM @viewer)
        )
        ''',
        substitutionValues: {'id': id, 'viewer': viewer},
      );
    } catch (_) {
      // 远端未建 note_stats 时不挡阅读
    } finally {
      await conn.close();
    }
  }

  /// 某作者的上架房源（陋室）。
  Future<List<MarketplaceListing>> fetchListedRoomsByOwner(String ownerId) async {
    final oid = ownerId.trim();
    if (oid.isEmpty) return const [];
    await _settings.load();
    final url = _settings.databaseUrl.trim();
    if (url.isEmpty) return const [];
    final conn = await NeonEndpoint.parse(url).open();
    try {
      final rows = await conn.query(
        '''
        SELECT
          r.id AS room_id,
          p.id AS property_id,
          p.name AS property_name,
          p.city AS city,
          p.address AS address,
          r.label AS room_label,
          r.video_url AS video_url,
          r.video_poster_url AS video_poster_url,
          r.listed_at AS listed_at
        FROM rooms r
        JOIN properties p ON p.id = r.property_id
        WHERE r.deleted_at IS NULL
          AND p.deleted_at IS NULL
          AND r.listing_status = 'listed'
          AND r.owner_id::text = @owner
        ORDER BY r.listed_at DESC NULLS LAST, r.updated_at DESC
        LIMIT 200
        ''',
        substitutionValues: {'owner': oid},
      );
      return rows.map((row) {
        DateTime? listedAt;
        final raw = row[8];
        if (raw is DateTime) {
          listedAt = raw.toUtc();
        } else if (raw != null) {
          listedAt = DateTime.tryParse('$raw');
        }
        return MarketplaceListing(
          roomUuid: '${row[0]}',
          propertyUuid: '${row[1]}',
          propertyName: '${row[2] ?? ''}',
          city: '${row[3] ?? ''}',
          address: '${row[4] ?? ''}',
          roomLabel: '${row[5] ?? ''}',
          videoUrl: '${row[6] ?? ''}',
          videoPosterUrl: '${row[7] ?? ''}',
          listedAt: listedAt,
        );
      }).toList();
    } finally {
      await conn.close();
    }
  }
}
