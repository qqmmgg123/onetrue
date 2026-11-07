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

/// 静默双向同步（LWW）：直连 Neon/Postgres。
/// 后台：先推 dirty 再拉；手动全量：先拉后推。
/// 未改脏跟线上；有本地改动按 updated_at；上传带乐观锁防旧盖新。
class SyncService {
  SyncService({
    AppDatabase? db,
    SyncSettings? settings,
  })  : _db = db ?? AppDatabase.instance,
        _settings = settings ?? SyncSettings.instance;

  final AppDatabase _db;
  final SyncSettings _settings;

  /// 互斥：同时只跑一路。静默遇忙则跳过；手动可中止静默并插队。
  static Completer<void>? _lock;
  static bool _abortFlag = false;
  static bool _runningFull = false;

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
  };

  /// [fullPull]=true：手动全量——先拉后推；未改脏跟线上，有本地改动按 updated_at 比新旧。
  Future<SyncReport> syncSilent({
    bool fullPull = false,
    SyncProgress? onProgress,
  }) async {
    void tip(String m) => onProgress?.call(m);

    tip('检查同步配置…');
    await _settings.load();
    if (!_settings.configured) {
      return SyncReport(error: 'sync_disabled');
    }

    // 静默：已有同步在跑直接跳过，不排队（避免拖慢「立即同步」）
    if (!fullPull && _lock != null) {
      return SyncReport();
    }

    // 手动：若后台静默在跑则中止并插队；若上一次也是手动则等待结束
    if (fullPull && _lock != null) {
      if (!_runningFull) {
        tip('正在结束后台同步…');
        _abortFlag = true;
      } else {
        tip('等待上一次同步结束…');
      }
      await _lock!.future;
    }

    final held = Completer<void>();
    _lock = held;
    _runningFull = fullPull;
    _abortFlag = false;
    final report = SyncReport();
    PostgreSQLConnection? conn;
    try {
      await _db.database;
      tip('连接 Neon 数据库…');
      conn = await _openWithRetry();
      if (_aborted) {
        tip('已让路');
        return report;
      }
      tip('检查远端是否为空库…');
      await _rematerializeIfRemoteEmpty(conn);

      if (fullPull) {
        tip('下载线上数据（全量）…');
        report.pulled = await _pullRemote(
          conn,
          full: true,
          onProgress: tip,
        );
        if (_aborted) {
          tip('已中止');
          return report;
        }
        tip('上传本地未同步改动…');
        final push = await _pushDirty(conn, onProgress: tip);
        report.pushed = push.$1;
        report.skipped = push.$2;
      } else {
        tip('上传本地改动…');
        final push = await _pushDirty(conn, onProgress: tip);
        report.pushed = push.$1;
        report.skipped = push.$2;
        if (_aborted) {
          tip('已中止');
          return report;
        }
        tip('下载线上更新…');
        report.pulled = await _pullRemote(conn, full: false, onProgress: tip);
      }

      if (_aborted) {
        tip('已中止');
        return report;
      }
      tip('写入同步时间…');
      await _db.setSyncState(
        'last_sync_at',
        DateTime.now().toUtc().toIso8601String(),
      );
      tip('同步完成');
    } catch (e, st) {
      debugPrint('sync failed: $e\n$st');
      report.error = '$e';
      tip('同步失败');
    } finally {
      try {
        await conn?.close();
      } catch (_) {}
      if (identical(_lock, held)) {
        _lock = null;
        _runningFull = false;
      }
      _abortFlag = false;
      held.complete();
    }
    return report;
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

  /// Neon 空库时，本地可能仍是 dirty=0（以前在 Supabase 标过已同步），需整表重推。
  Future<void> _rematerializeIfRemoteEmpty(PostgreSQLConnection conn) async {
    final rows = await conn.query(
      'SELECT COUNT(*)::int AS c FROM properties '
      'WHERE owner_id = CAST(@owner AS uuid)',
      substitutionValues: {'owner': _settings.ownerId},
    );
    final raw = rows.isEmpty ? 0 : rows.first[0];
    final remoteCount = raw is int ? raw : int.tryParse('$raw') ?? 0;
    if (remoteCount > 0) return;
    final local = await (await _db.database).rawQuery(
      'SELECT COUNT(*) AS c FROM properties WHERE deleted_at IS NULL',
    );
    final localCount = (local.first['c'] as int?) ?? 0;
    if (localCount <= 0) return;
    debugPrint('sync: remote empty, mark all dirty for Neon rematerialize');
    await _db.markAllSyncDirty();
  }

  Future<(int, int)> _pushDirty(
    PostgreSQLConnection conn, {
    SyncProgress? onProgress,
  }) async {
    var count = 0;
    var skipped = 0;
    for (final table in _syncOrder) {
      if (_aborted) break;
      final rows = await _db.dirtyRows(table);
      if (rows.isEmpty) continue;
      final label = _tableLabel[table] ?? table;
      onProgress?.call('上传$label（${rows.length} 条）…');
      for (final row in rows) {
        if (_aborted) break;
        // 先补推父行，避免 leases.room_id 等外键在远端不存在
        final okParents = await _ensureParentsRemote(conn, table, row);
        if (!okParents) {
          skipped++;
          continue;
        }
        final payload = await _toRemotePayload(table, row);
        if (payload == null) {
          skipped++;
          continue;
        }
        final wrote = await _upsertRemote(conn, table, payload);
        if (!wrote) {
          // 线上更新：不盖写，改为拉回线上并清掉本地 dirty
          onProgress?.call('线上$label更新，保留线上版本');
          await _pullOneByUuid(conn, table, '${payload['id']}');
          skipped++;
          continue;
        }
        await _db.markSynced(table, row['id'] as int);
        count++;
      }
    }
    return (count, skipped);
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
    // 父行若线上更新：不盖写，但外键目标已存在，视为成功
    await _upsertRemote(conn, table, payload);
    return true;
  }

  /// 乐观锁：仅当本地 updated_at ≥ 线上时才盖写；否则返回 false。
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
    final result = await conn.query(
      'INSERT INTO $table ($cols) VALUES ($ph) '
      'ON CONFLICT (id) DO UPDATE SET $updates '
      'WHERE $table.updated_at <= EXCLUDED.updated_at '
      'RETURNING id',
      substitutionValues: values,
    );
    return result.isNotEmpty;
  }

  Future<void> _pullOneByUuid(
    PostgreSQLConnection conn,
    String table,
    String uuid,
  ) async {
    final rows = await conn.query(
      'SELECT * FROM $table WHERE id = CAST(@id AS uuid) LIMIT 1',
      substitutionValues: {'id': uuid},
    );
    if (rows.isEmpty) return;
    await _applyRemoteRow(table, _mapRow(rows.first), preferRemoteIfClean: true);
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

  /// LWW：
  /// - 本地未改脏（dirty=0）：跟线上（修控制台改名但时间戳未变/未脏本地挡更新）
  /// - 本地有改动：仅当线上 updated_at 更新时才覆盖本地
  bool _shouldSkipPull(
    Map<String, Object?>? local,
    String remoteUpdated, {
    bool preferRemoteIfClean = true,
  }) {
    if (local == null) return false;
    final dirty = (local['dirty'] as int? ?? 0) == 1;
    if (preferRemoteIfClean && !dirty) return false;
    final localTs = _parseTs(local['updated_at']);
    final remoteTs = _parseTs(remoteUpdated);
    // 本地有未上传修改且不比线上旧 → 保留本地
    if (dirty && !localTs.isBefore(remoteTs)) return true;
    if (localTs.isAfter(remoteTs)) return true;
    return false;
  }

  DateTime _parseTs(Object? raw) {
    if (raw is DateTime) return raw.toUtc();
    final s = '${raw ?? ''}'.trim();
    if (s.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final parsed = DateTime.tryParse(s);
    if (parsed != null) return parsed.toUtc();
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
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
      'dirty': 0,
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

  Future<bool> _applyRemoteRow(
    String table,
    Map<String, dynamic> remote, {
    bool preferRemoteIfClean = true,
  }) async {
    final uuid = '${remote['id']}';
    final remoteUpdated = '${remote['updated_at']}';
    var local = await _db.rowByUuid(table, uuid);
    if (_shouldSkipPull(
      local,
      remoteUpdated,
      preferRemoteIfClean: preferRemoteIfClean,
    )) {
      return false;
    }

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
      default:
        return false;
    }
  }

  /// 游客广场：只读拉取已上架房源（不按当前 owner 过滤，不写入本地库）。
  /// 正式版应改为公开 API；一期测试仍直连 Neon。
  Future<List<MarketplaceListing>> fetchListedRooms({String? city}) async {
    await _settings.load();
    final url = _settings.databaseUrl.trim();
    if (url.isEmpty) {
      throw StateError('未配置数据库，无法浏览广场房源');
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
}
