import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/app_database.dart';
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

/// 静默双向同步（LWW）：先推 dirty，再拉远端更新。
class SyncService {
  SyncService({
    AppDatabase? db,
    SyncSettings? settings,
  })  : _db = db ?? AppDatabase.instance,
        _settings = settings ?? SyncSettings.instance;

  final AppDatabase _db;
  final SyncSettings _settings;

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

  Future<SyncReport> syncSilent() async {
    await _settings.load();
    if (!_settings.configured) {
      return SyncReport(error: 'sync_disabled');
    }
    await _db.database;
    final report = SyncReport();
    try {
      final push = await _pushDirty();
      report.pushed = push.$1;
      report.skipped = push.$2;
      report.pulled = await _pullRemote();
      await _db.setSyncState(
        'last_sync_at',
        DateTime.now().toUtc().toIso8601String(),
      );
    } catch (e, st) {
      debugPrint('sync failed: $e\n$st');
      report.error = '$e';
    }
    return report;
  }

  Uri _tableUri(String table, [String query = '']) {
    final base = '${_settings.supabaseUrl}/rest/v1/$table';
    return Uri.parse(query.isEmpty ? base : '$base?$query');
  }

  Map<String, String> get _headers => {
        'apikey': _settings.anonKey,
        'Authorization': 'Bearer ${_settings.anonKey}',
        'Content-Type': 'application/json',
        'Prefer': 'resolution=merge-duplicates,return=minimal',
      };

  Future<(int, int)> _pushDirty() async {
    var count = 0;
    var skipped = 0;
    for (final table in _syncOrder) {
      final rows = await _db.dirtyRows(table);
      for (final row in rows) {
        final payload = await _toRemotePayload(table, row);
        if (payload == null) {
          skipped++;
          continue;
        }
        final res = await http.post(
          _tableUri(table, 'on_conflict=id'),
          headers: {
            ..._headers,
            'Prefer': 'resolution=merge-duplicates,return=minimal',
          },
          body: jsonEncode(payload),
        );
        if (res.statusCode >= 200 && res.statusCode < 300) {
          await _db.markSynced(table, row['id'] as int);
          count++;
        } else {
          throw StateError('推送 $table 失败 ${res.statusCode}: ${res.body}');
        }
      }
    }
    return (count, skipped);
  }

  Future<int> _pullRemote() async {
    final since = await _db.getSyncState('last_sync_at');
    var count = 0;
    for (final table in _syncOrder) {
      final q = StringBuffer(
        'owner_id=eq.${_settings.ownerId}&order=updated_at.asc',
      );
      if (since != null && since.isNotEmpty) {
        q.write('&updated_at=gt.${Uri.encodeComponent(since)}');
      }
      final res = await http.get(
        _tableUri(table, q.toString()),
        headers: _headers,
      );
      if (res.statusCode >= 400) {
        throw StateError('拉取 $table 失败 ${res.statusCode}: ${res.body}');
      }
      final list = jsonDecode(res.body);
      if (list is! List) continue;
      for (final raw in list) {
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw);
        final applied = await _applyRemoteRow(table, map);
        if (applied) count++;
      }
    }
    return count;
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
        };
      case 'rooms':
        final prop = await _uuidOf('properties', row['property_id'] as int);
        if (prop == null) return null;
        return {...base, 'property_id': prop, 'label': row['label']};
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

  bool _shouldSkipPull(Map<String, Object?>? local, String remoteUpdated) {
    if (local == null) return false;
    final localUpdated = local['updated_at'] as String? ?? '';
    if (localUpdated.compareTo(remoteUpdated) >= 0 &&
        (local['dirty'] as int? ?? 0) == 1) {
      return true;
    }
    return localUpdated.compareTo(remoteUpdated) >= 0;
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

  Future<bool> _applyRemoteRow(String table, Map<String, dynamic> remote) async {
    final uuid = '${remote['id']}';
    final remoteUpdated = '${remote['updated_at']}';
    var local = await _db.rowByUuid(table, uuid);
    if (_shouldSkipPull(local, remoteUpdated)) return false;

    final db = await _db.database;

    switch (table) {
      case 'properties':
        return _upsertByUuid(
          table,
          uuid,
          {
            'name': remote['name'],
            'address': remote['address'] ?? '',
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
            'start_date': remote['start_date'],
            'end_date': remote['end_date'],
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
        // 本地 UNIQUE(lease_id, period_start)：合并同账期不同 uuid
        if (local == null) {
          final dup = await db.query(
            'rent_periods',
            where: 'lease_id = ? AND period_start = ?',
            whereArgs: [leaseId, remote['period_start']],
            limit: 1,
          );
          if (dup.isNotEmpty) local = dup.first;
        }
        return _upsertByUuid(
          table,
          uuid,
          {
            'lease_id': leaseId,
            'period_start': remote['period_start'],
            'period_end': remote['period_end'],
            'due_date': remote['due_date'],
            'amount': remote['amount'],
            'status': remote['status'],
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
}
