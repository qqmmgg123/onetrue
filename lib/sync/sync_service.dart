import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/app_database.dart';
import 'sync_settings.dart';

class SyncReport {
  SyncReport({
    this.pushed = 0,
    this.pulled = 0,
    this.error,
  });

  int pushed;
  int pulled;
  String? error;

  bool get ok => error == null;
}

/// 静默双向同步（LWW）：先推 dirty，再拉远端更新。
/// 首期覆盖：properties / rooms / tenants / leases / lease_extras。
class SyncService {
  SyncService({
    AppDatabase? db,
    SyncSettings? settings,
  })  : _db = db ?? AppDatabase.instance,
        _settings = settings ?? SyncSettings.instance;

  final AppDatabase _db;
  final SyncSettings _settings;

  static const _inventoryOrder = [
    'properties',
    'rooms',
    'tenants',
    'leases',
    'lease_extras',
  ];

  Future<SyncReport> syncSilent() async {
    await _settings.load();
    if (!_settings.configured) {
      return SyncReport(error: 'sync_disabled');
    }
    // 确保本地库已到 v5
    await _db.database;
    final report = SyncReport();
    try {
      report.pushed = await _pushDirty();
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

  Future<int> _pushDirty() async {
    var count = 0;
    for (final table in _inventoryOrder) {
      final rows = await _db.dirtyRows(table);
      for (final row in rows) {
        final payload = await _toRemotePayload(table, row);
        if (payload == null) continue;
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
    return count;
  }

  Future<int> _pullRemote() async {
    final since = await _db.getSyncState('last_sync_at');
    var count = 0;
    for (final table in _inventoryOrder) {
      final q = StringBuffer(
        'owner_id=eq.${_settings.ownerId}&order=updated_at.asc',
      );
      if (since != null && since.isNotEmpty) {
        q.write('&updated_at=gt.$since');
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
    final deletedAt = row['deleted_at'];
    final base = <String, dynamic>{
      'id': uuid,
      'updated_at': updatedAt,
      'deleted_at': deletedAt,
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
        return {
          ...base,
          'property_id': prop,
          'label': row['label'],
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

  Future<bool> _applyRemoteRow(String table, Map<String, dynamic> remote) async {
    final uuid = '${remote['id']}';
    final remoteUpdated = '${remote['updated_at']}';
    final local = await _db.rowByUuid(table, uuid);
    if (local != null) {
      final localUpdated = local['updated_at'] as String? ?? '';
      if (localUpdated.compareTo(remoteUpdated) >= 0 &&
          (local['dirty'] as int? ?? 0) == 1) {
        // 本地更新且未上传：先不覆盖（下次推送赢）
        return false;
      }
      if (localUpdated.compareTo(remoteUpdated) >= 0) {
        return false;
      }
    }

    final db = await _db.database;
    switch (table) {
      case 'properties':
        if (local == null) {
          await db.insert('properties', {
            'uuid': uuid,
            'name': remote['name'],
            'address': remote['address'] ?? '',
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
            'dirty': 0,
          });
        } else {
          await db.update(
            'properties',
            {
              'name': remote['name'],
              'address': remote['address'] ?? '',
              'updated_at': remoteUpdated,
              'deleted_at': remote['deleted_at'],
              'dirty': 0,
            },
            where: 'id = ?',
            whereArgs: [local['id']],
          );
        }
        return true;
      case 'rooms':
        final propId =
            await _localIdOfUuid('properties', '${remote['property_id']}');
        if (propId == null) return false;
        if (local == null) {
          await db.insert('rooms', {
            'uuid': uuid,
            'property_id': propId,
            'label': remote['label'],
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
            'dirty': 0,
          });
        } else {
          await db.update(
            'rooms',
            {
              'property_id': propId,
              'label': remote['label'],
              'updated_at': remoteUpdated,
              'deleted_at': remote['deleted_at'],
              'dirty': 0,
            },
            where: 'id = ?',
            whereArgs: [local['id']],
          );
        }
        return true;
      case 'tenants':
        if (local == null) {
          await db.insert('tenants', {
            'uuid': uuid,
            'name': remote['name'],
            'phone': remote['phone'] ?? '',
            'updated_at': remoteUpdated,
            'deleted_at': remote['deleted_at'],
            'dirty': 0,
          });
        } else {
          await db.update(
            'tenants',
            {
              'name': remote['name'],
              'phone': remote['phone'] ?? '',
              'updated_at': remoteUpdated,
              'deleted_at': remote['deleted_at'],
              'dirty': 0,
            },
            where: 'id = ?',
            whereArgs: [local['id']],
          );
        }
        return true;
      case 'leases':
        final roomId = await _localIdOfUuid('rooms', '${remote['room_id']}');
        final tenantId =
            await _localIdOfUuid('tenants', '${remote['tenant_id']}');
        if (roomId == null || tenantId == null) return false;
        final data = {
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
          'dirty': 0,
        };
        if (local == null) {
          await db.insert('leases', {'uuid': uuid, ...data});
        } else {
          await db.update(
            'leases',
            data,
            where: 'id = ?',
            whereArgs: [local['id']],
          );
        }
        return true;
      case 'lease_extras':
        final leaseId = await _localIdOfUuid('leases', '${remote['lease_id']}');
        if (leaseId == null) return false;
        final data = {
          'lease_id': leaseId,
          'name': remote['name'],
          'amount': remote['amount'],
          'sort_order': remote['sort_order'] ?? 0,
          'updated_at': remoteUpdated,
          'deleted_at': remote['deleted_at'],
          'dirty': 0,
        };
        if (local == null) {
          await db.insert('lease_extras', {'uuid': uuid, ...data});
        } else {
          await db.update(
            'lease_extras',
            data,
            where: 'id = ?',
            whereArgs: [local['id']],
          );
        }
        return true;
      default:
        return false;
    }
  }
}
