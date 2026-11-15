import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/baked_env.dart';
import '../data/app_database.dart';
import '../domain/models.dart';
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
/// 通过 Supabase PostgREST 同步 `notes`（RLS 按 auth.uid）。
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

  static const _syncOrder = ['notes'];

  SupabaseClient get _client {
    if (!BakedEnv.hasSupabase) {
      throw StateError('未配置 Supabase，无法同步');
    }
    return Supabase.instance.client;
  }

  /// 打开/回前台/刷新：只拉「当前登录用户」笔记覆盖本地缓存。
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
    try {
      await _db.database;
      tip('连接云端…');

      final since = await _db.getSyncState('last_sync_at');
      var full = forceFull || since == null || since.isEmpty;
      if (!full) {
        final t = DateTime.tryParse(since);
        if (t == null ||
            DateTime.now().toUtc().difference(t.toUtc()).inDays >= 7) {
          full = true;
        }
      }
      tip(full ? '下载我的笔记（全量）…' : '下载我的笔记（增量）…');
      report.pulled = await _pullRemote(
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
      if (identical(_lock, held)) {
        _lock = null;
      }
      _abortFlag = false;
      held.complete();
    }
    return report;
  }

  /// 业务写入后：按行直推（仅 notes）。
  Future<SyncReport> pushLocalRows(
    List<SyncRef> refs, {
    SyncProgress? onProgress,
  }) async {
    void tip(String m) => onProgress?.call(m);
    await _settings.load();
    if (!_settings.configured) {
      return SyncReport(error: '未登录或未配置同步，无法保存到云端');
    }
    final noteRefs = refs.where((r) => r.table == 'notes').toList();
    if (noteRefs.isEmpty) return SyncReport();

    if (_lock != null) {
      await _lock!.future;
    }
    final held = Completer<void>();
    _lock = held;
    _abortFlag = false;
    final report = SyncReport();
    try {
      tip('上传…');
      final ordered = _orderedUnique(noteRefs);
      var failed = 0;
      for (final ref in ordered) {
        if (_aborted) break;
        tip('上传笔记…');
        // 1=已推 0=LWW跳过（远程不旧） -1=失败
        final code = await _upsertLocalById(ref.id);
        if (code > 0) {
          report.pushed++;
        } else if (code == 0) {
          report.skipped++;
        } else {
          failed++;
          report.skipped++;
        }
      }
      if (failed > 0 && report.pushed == 0) {
        report.error = '部分数据未能上传，请稍后重试';
      }
      tip('上传完成');
    } catch (e, st) {
      debugPrint('pushLocalRows failed: $e\n$st');
      report.error = '$e';
    } finally {
      if (identical(_lock, held)) {
        _lock = null;
      }
      _abortFlag = false;
      held.complete();
    }
    return report;
  }

  /// 登录认领：上传全部本地笔记。
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

  /// 兼容旧调用：房源树已不再同步，返回空。
  Future<List<SyncRef>> refsForLease(int leaseId) async => const [];

  /// 兼容旧调用：账期树已不再同步，返回空。
  Future<List<SyncRef>> refsForPeriod(int periodId) async => const [];

  List<SyncRef> _orderedUnique(List<SyncRef> refs) {
    final seen = <String>{};
    final list = <SyncRef>[];
    for (final r in refs) {
      final key = '${r.table}:${r.id}';
      if (seen.add(key)) list.add(r);
    }
    list.sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  /// 比较 updated_at：正数表示 a 更新。
  int _cmpUpdated(Object? a, Object? b) {
    final da = DateTime.tryParse('${_normalizeRemote(a) ?? ''}');
    final db = DateTime.tryParse('${_normalizeRemote(b) ?? ''}');
    if (da == null && db == null) return 0;
    if (da == null) return -1;
    if (db == null) return 1;
    return da.toUtc().compareTo(db.toUtc());
  }

  /// 按 uuid 上传；远程已更新且不旧于本地则跳过，避免归户/离线把远端新数据打旧。
  /// 返回：1 已推送，0 跳过（远程更新或不需传），-1 失败。
  Future<int> _upsertLocalById(int localId) async {
    final rows = await (await _db.database).query(
      'notes',
      where: 'id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return -1;
    final payload = await _toRemotePayload(rows.first);
    if (payload == null) return -1;
    final uuid = '${payload['id']}';
    final localUpdated = payload['updated_at'];

    try {
      final remote = await _client
          .from('notes')
          .select()
          .eq('id', uuid)
          .maybeSingle();
      if (remote != null) {
        final remoteUpdated = remote['updated_at'];
        // 远程 >= 本地：保留远程，并回写本地缓存（防重复/混乱）
        if (_cmpUpdated(remoteUpdated, localUpdated) >= 0) {
          await _applyRemoteRow(
            Map<String, dynamic>.from(remote),
            force: true,
          );
          return 0;
        }
      }
    } catch (e) {
      debugPrint('upsert LWW check failed for $uuid: $e');
    }

    await _client.from('notes').upsert(payload);
    return 1;
  }

  Future<int> _pullRemote({
    bool full = false,
    SyncProgress? onProgress,
  }) async {
    final since = full ? null : await _db.getSyncState('last_sync_at');
    onProgress?.call(full ? '下载笔记…' : '检查线上笔记更新…');

    var query = _client.from('notes').select().eq('owner_id', _settings.ownerId);
    if (since != null && since.isNotEmpty) {
      final cursor = DateTime.tryParse(since)?.toUtc();
      if (cursor != null) {
        final sinceAdj = cursor.subtract(const Duration(minutes: 2));
        query = query.gt('updated_at', sinceAdj.toIso8601String());
      }
    }
    final rows = await query.order('updated_at', ascending: true);
    var count = 0;
    for (final row in rows as List) {
      if (_aborted) break;
      final map = Map<String, dynamic>.from(row as Map);
      final applied = await _applyRemoteRow(map);
      if (applied) count++;
    }
    if (count > 0) {
      onProgress?.call('已更新笔记 $count 条');
    }
    return count;
  }

  Object? _normalizeRemote(Object? v) {
    if (v == null) return null;
    if (v is DateTime) return v.toUtc().toIso8601String();
    if (v is BigInt) return v.toInt();
    return v;
  }

  Future<Map<String, dynamic>?> _toRemotePayload(
    Map<String, Object?> row,
  ) async {
    final uuid = row['uuid'] as String?;
    if (uuid == null || uuid.isEmpty) return null;
    final updatedAt = row['updated_at'] as String? ??
        DateTime.now().toUtc().toIso8601String();

    Object? sourceUuids = row['source_note_uuids'] ?? '[]';
    if (sourceUuids is String) {
      try {
        sourceUuids = jsonDecode(sourceUuids);
      } catch (_) {
        sourceUuids = [];
      }
    }

    return {
      'id': uuid,
      'updated_at': updatedAt,
      'deleted_at': row['deleted_at'],
      'owner_id': _settings.ownerId,
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
      'source_note_uuids': sourceUuids,
    };
  }

  Future<bool> _upsertByUuid(
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
      await db.insert('notes', row);
    } else {
      await db.update(
        'notes',
        row,
        where: 'id = ?',
        whereArgs: [local['id']],
      );
    }
    return true;
  }

  /// 拉取远程行：默认 LWW（本地更新则跳过）；[force] 用于推送冲突时强制对齐远程。
  Future<bool> _applyRemoteRow(
    Map<String, dynamic> remote, {
    bool force = false,
  }) async {
    final uuid = '${remote['id']}';
    final remoteUpdated = '${_normalizeRemote(remote['updated_at'])}';
    final local = await _db.rowByUuid('notes', uuid);

    if (!force && local != null) {
      final localUpdated = local['updated_at'];
      // 本地严格更新 → 保留本地，等下次推送；同版本跳过避免无意义写库
      if (_cmpUpdated(localUpdated, remoteUpdated) >= 0) {
        return false;
      }
    }

    final sourceRaw = remote['source_note_uuids'];
    final sourceStr = sourceRaw is String
        ? sourceRaw
        : jsonEncode(sourceRaw ?? []);

    return _upsertByUuid(
      uuid,
      {
        'kind': remote['kind'] ?? 'note',
        'title': remote['title'] ?? '',
        'body': remote['body'] ?? '',
        'format': remote['format'] ?? 'plain',
        'schedule_at': remote['schedule_at'] == null
            ? null
            : _normalizeRemote(remote['schedule_at']),
        'remind_at': remote['remind_at'] == null
            ? null
            : _normalizeRemote(remote['remind_at']),
        'recur_freq': remote['recur_freq'] ?? '',
        'recur_interval': remote['recur_interval'] ?? 1,
        'recur_byday': remote['recur_byday'],
        'recur_until': remote['recur_until'] == null
            ? null
            : _normalizeRemote(remote['recur_until']),
        'deleted_at': remote['deleted_at'] == null
            ? null
            : _normalizeRemote(remote['deleted_at']),
        'listed_at': remote['listed_at'] == null
            ? null
            : _normalizeRemote(remote['listed_at']),
        'city': remote['city'] ?? '',
        'parent_uuid': remote['parent_uuid']?.toString(),
        'sort_order': remote['sort_order'] ?? 0,
        'source_note_uuids': sourceStr,
        'updated_at': remoteUpdated,
        'recur_count': remote['recur_count'],
        'remind_offset_min': remote['remind_offset_min'] ?? 0,
        'listing_status': remote['listing_status'] ?? 'draft',
      },
      local,
    );
  }

  /// 市集房源已下线（notes-only）；保留 API 兼容。
  Future<List<MarketplaceListing>> fetchListedRooms({String? city}) async {
    return const [];
  }

  Future<List<MarketplaceListing>> fetchListedRoomsByOwner(
    String ownerId,
  ) async {
    return const [];
  }

  /// 市集：已上架文章（anon/authenticated 可读 listed articles）。
  Future<List<MarketplaceArticle>> fetchListedArticles({
    String? city,
    String? ownerId,
  }) async {
    await _settings.load();
    if (!BakedEnv.hasSupabase) {
      throw StateError('未配置 Supabase，无法浏览市集文章');
    }

    final cityFilter = city?.trim() ?? '';
    final ownerFilter = ownerId?.trim() ?? '';

    var query = _client
        .from('notes')
        .select(
          'id, title, body, format, city, listed_at, owner_id, '
          'note_stats(view_count, recommend_count, comment_count)',
        )
        .is_('deleted_at', null)
        .eq('kind', 'article')
        .eq('listing_status', 'listed');

    if (ownerFilter.isNotEmpty) {
      query = query.eq('owner_id', ownerFilter);
    }
    if (cityFilter.isNotEmpty) {
      // PostgREST：city = filter OR city = ''
      query = query.or('city.eq.$cityFilter,city.eq.');
    }

    final rows = await query
        .order('listed_at', ascending: false)
        .limit(200);

    final list = (rows as List).map((row) {
      final map = Map<String, dynamic>.from(row as Map);
      return _articleFromMap(map);
    }).toList();
    // 热度排序：推荐/评论/浏览 + 新鲜度
    list.sort((a, b) => b.hotScore.compareTo(a.hotScore));
    return list;
  }

  MarketplaceArticle _articleFromMap(Map<String, dynamic> map) {
    DateTime? listedAt;
    final raw = map['listed_at'];
    if (raw is DateTime) {
      listedAt = raw.toUtc();
    } else if (raw != null) {
      listedAt = DateTime.tryParse('$raw');
    }
    var viewCount = 0;
    var recommendCount = 0;
    var commentCount = 0;
    final stats = map['note_stats'];
    Map? statsMap;
    if (stats is Map) {
      statsMap = stats;
    } else if (stats is List && stats.isNotEmpty && stats.first is Map) {
      statsMap = stats.first as Map;
    }
    if (statsMap != null) {
      viewCount = statsMap['view_count'] is int
          ? statsMap['view_count'] as int
          : int.tryParse('${statsMap['view_count']}') ?? 0;
      recommendCount = statsMap['recommend_count'] is int
          ? statsMap['recommend_count'] as int
          : int.tryParse('${statsMap['recommend_count']}') ?? 0;
      commentCount = statsMap['comment_count'] is int
          ? statsMap['comment_count'] as int
          : int.tryParse('${statsMap['comment_count']}') ?? 0;
    }
    return MarketplaceArticle(
      noteUuid: '${map['id'] ?? ''}',
      title: '${map['title'] ?? ''}',
      body: '${map['body'] ?? ''}',
      format: '${map['format'] ?? 'plain'}',
      city: '${map['city'] ?? ''}',
      listedAt: listedAt,
      ownerId: '${map['owner_id'] ?? ''}',
      viewCount: viewCount,
      recommendCount: recommendCount,
      commentCount: commentCount,
    );
  }

  /// 非作者访问：累计文章浏览次数。
  Future<void> incrementArticleView({
    required String noteUuid,
    String? viewerId,
  }) async {
    final id = noteUuid.trim();
    if (id.isEmpty || !BakedEnv.hasSupabase) return;
    final viewer = viewerId?.trim() ?? '';
    try {
      final note = await _client
          .from('notes')
          .select('id, owner_id, deleted_at, kind, listing_status')
          .eq('id', id)
          .maybeSingle();
      if (note == null) return;
      if (note['deleted_at'] != null) return;
      if ('${note['kind']}' != 'article') return;
      if ('${note['listing_status']}' != 'listed') return;
      if (viewer.isNotEmpty && '${note['owner_id']}' == viewer) return;

      final existing = await _client
          .from('note_stats')
          .select('view_count')
          .eq('note_id', id)
          .maybeSingle();
      if (existing == null) {
        await _client.from('note_stats').insert({
          'note_id': id,
          'view_count': 1,
        });
      } else {
        final vc = existing['view_count'];
        final n = vc is int ? vc : int.tryParse('$vc') ?? 0;
        await _client
            .from('note_stats')
            .update({'view_count': n + 1}).eq('note_id', id);
      }
    } catch (_) {
      // 远端策略未就绪时不挡阅读
    }
  }
}
