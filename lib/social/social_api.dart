import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/baked_env.dart';
import '../domain/models.dart';
import 'social_models.dart';

/// PostgREST 社交读写（profiles / follows / recommends / comments / notifications）。
class SocialApi {
  SocialApi._();
  static final SocialApi instance = SocialApi._();

  SupabaseClient get _client {
    if (!BakedEnv.hasSupabase) {
      throw StateError('未配置 Supabase');
    }
    return Supabase.instance.client;
  }

  String? get _uid => _client.auth.currentUser?.id;

  // —— admonitions（谏言）——

  Future<List<AdmonitionItem>> fetchAdmonitions({int limit = 30}) async {
    final rows = await _client
        .from('notes')
        .select('id, title, body, format, listed_at')
        .eq('kind', 'admonition')
        .eq('listing_status', 'listed')
        .is_('deleted_at', null)
        .order('listed_at', ascending: false)
        .limit(limit);
    final out = <AdmonitionItem>[];
    for (final r in (rows as List)) {
      final item = AdmonitionItem.fromMap(Map<String, dynamic>.from(r as Map));
      if (item.id.isNotEmpty) out.add(item);
    }
    return out;
  }

  // —— profiles ——

  Future<UserProfile?> fetchProfile(String userId) async {
    final id = userId.trim();
    if (id.isEmpty) return null;
    final row = await _client
        .from('profiles')
        .select('id, nickname, avatar_url, is_admin')
        .eq('id', id)
        .maybeSingle();
    if (row == null) return null;
    return UserProfile.fromMap(Map<String, dynamic>.from(row as Map));
  }

  Future<Map<String, UserProfile>> fetchProfiles(Iterable<String> ids) async {
    final list = ids.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
    if (list.isEmpty) return {};
    final rows = await _client
        .from('profiles')
        .select('id, nickname, avatar_url, is_admin')
        .in_('id', list);
    final out = <String, UserProfile>{};
    for (final r in (rows as List)) {
      final p = UserProfile.fromMap(Map<String, dynamic>.from(r as Map));
      if (p.id.isNotEmpty) out[p.id] = p;
    }
    return out;
  }

  Future<UserProfile> upsertMyProfile({
    String? nickname,
    String? avatarUrl,
  }) async {
    final uid = _uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('请先登录');
    }
    final payload = <String, dynamic>{
      'id': uid,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (nickname != null) payload['nickname'] = nickname.trim();
    if (avatarUrl != null) payload['avatar_url'] = avatarUrl.trim();
    final row = await _client
        .from('profiles')
        .upsert(payload)
        .select('id, nickname, avatar_url, is_admin')
        .single();
    return UserProfile.fromMap(Map<String, dynamic>.from(row as Map));
  }

  /// 登录后确保有档案；空昵称时用 [fallbackNickname]。
  Future<UserProfile> ensureProfile({String fallbackNickname = ''}) async {
    final uid = _uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('请先登录');
    }
    final existing = await fetchProfile(uid);
    if (existing != null && existing.nickname.trim().isNotEmpty) {
      return existing;
    }
    final nick = fallbackNickname.trim().isNotEmpty
        ? fallbackNickname.trim()
        : (existing?.nickname.trim().isNotEmpty == true
            ? existing!.nickname
            : '用户${uid.substring(0, 4)}');
    return upsertMyProfile(
      nickname: nick,
      avatarUrl: existing?.avatarUrl,
    );
  }

  // —— follows ——

  Future<bool> isFollowing(String targetUserId) async {
    final uid = _uid;
    final tid = targetUserId.trim();
    if (uid == null || tid.isEmpty || uid == tid) return false;
    final row = await _client
        .from('follows')
        .select('follower_id')
        .eq('follower_id', uid)
        .eq('following_id', tid)
        .maybeSingle();
    return row != null;
  }

  Future<void> follow(String targetUserId) async {
    final uid = _uid;
    final tid = targetUserId.trim();
    if (uid == null) throw StateError('请先登录');
    if (tid.isEmpty || tid == uid) throw StateError('不能留意自己');
    await _client.from('follows').upsert({
      'follower_id': uid,
      'following_id': tid,
    });
    try {
      await _client.from('social_notifications').insert({
        'user_id': tid,
        'actor_id': uid,
        'kind': 'follow',
        'body': '留意了你',
      });
    } catch (_) {}
  }

  Future<void> unfollow(String targetUserId) async {
    final uid = _uid;
    final tid = targetUserId.trim();
    if (uid == null || tid.isEmpty) return;
    await _client
        .from('follows')
        .delete()
        .eq('follower_id', uid)
        .eq('following_id', tid);
  }

  Future<List<String>> followingIds() async {
    final uid = _uid;
    if (uid == null) return const [];
    final rows = await _client
        .from('follows')
        .select('following_id')
        .eq('follower_id', uid)
        .order('created_at', ascending: false);
    return (rows as List)
        .map((r) => '${(r as Map)['following_id'] ?? ''}')
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 关注的人最新文章（按 listed_at 倒序；不再要求 listed）。
  Future<List<MarketplaceArticle>> fetchFollowingArticles({int limit = 100}) async {
    final ids = await followingIds();
    if (ids.isEmpty) return const [];
    final rows = await _client
        .from('notes')
        .select(
          'id, title, body, format, city, cover_url, listed_at, owner_id, '
          'note_stats(view_count, recommend_count, comment_count)',
        )
        .is_('deleted_at', null)
        .eq('kind', 'article')
        .in_('owner_id', ids)
        .order('listed_at', ascending: false)
        .limit(limit);
    return (rows as List).map((r) {
      return _articleFromMap(Map<String, dynamic>.from(r as Map));
    }).toList();
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
      viewCount = _asInt(statsMap['view_count']);
      recommendCount = _asInt(statsMap['recommend_count']);
      commentCount = _asInt(statsMap['comment_count']);
    }
    return MarketplaceArticle(
      noteUuid: '${map['id'] ?? ''}',
      title: '${map['title'] ?? ''}',
      body: '${map['body'] ?? ''}',
      format: '${map['format'] ?? 'plain'}',
      city: '${map['city'] ?? ''}',
      coverUrl: '${map['cover_url'] ?? ''}',
      listedAt: listedAt,
      ownerId: '${map['owner_id'] ?? ''}',
      viewCount: viewCount,
      recommendCount: recommendCount,
      commentCount: commentCount,
    );
  }

  int _asInt(dynamic v) => v is int ? v : int.tryParse('$v') ?? 0;

  // —— recommends ——

  Future<bool> hasRecommended(String noteId) async {
    final uid = _uid;
    final nid = noteId.trim();
    if (uid == null || nid.isEmpty) return false;
    final row = await _client
        .from('article_recommends')
        .select('note_id')
        .eq('note_id', nid)
        .eq('user_id', uid)
        .maybeSingle();
    return row != null;
  }

  Future<int> recommendCount(String noteId) async {
    final nid = noteId.trim();
    if (nid.isEmpty) return 0;
    final row = await _client
        .from('note_stats')
        .select('recommend_count')
        .eq('note_id', nid)
        .maybeSingle();
    if (row == null) return 0;
    return _asInt((row as Map)['recommend_count']);
  }

  /// 切换推荐；返回是否已推荐、以及最新数量。
  /// 排序加权：recommend*5 + comment*3 + view + 时间新鲜度（客户端市集可按 recommend 优先）。
  Future<({bool recommended, int count})> toggleRecommend({
    required String noteId,
    required String ownerId,
  }) async {
    final uid = _uid;
    final nid = noteId.trim();
    if (uid == null) throw StateError('请先登录');
    if (nid.isEmpty) throw StateError('无效文章');
    if (ownerId.trim() == uid) {
      throw StateError('不能推荐自己的文章');
    }

    final existed = await hasRecommended(nid);
    if (existed) {
      await _client
          .from('article_recommends')
          .delete()
          .eq('note_id', nid)
          .eq('user_id', uid);
      await _bumpRecommend(nid, -1);
    } else {
      await _client.from('article_recommends').upsert({
        'note_id': nid,
        'user_id': uid,
      });
      await _bumpRecommend(nid, 1);
      try {
        await _client.from('social_notifications').insert({
          'user_id': ownerId,
          'actor_id': uid,
          'kind': 'recommend',
          'note_id': nid,
          'body': '推荐了你的文章',
        });
      } catch (_) {}
    }
    final count = await recommendCount(nid);
    return (recommended: !existed, count: count);
  }

  // —— favorites（收藏）——

  Future<bool> hasFavorited(String noteId) async {
    final uid = _uid;
    final nid = noteId.trim();
    if (uid == null || nid.isEmpty) return false;
    final row = await _client
        .from('article_favorites')
        .select('note_id')
        .eq('note_id', nid)
        .eq('user_id', uid)
        .maybeSingle();
    return row != null;
  }

  /// 切换收藏；返回是否已收藏。
  Future<bool> toggleFavorite(String noteId) async {
    final uid = _uid;
    final nid = noteId.trim();
    if (uid == null) throw StateError('请先登录');
    if (nid.isEmpty) throw StateError('无效文章');
    final existed = await hasFavorited(nid);
    if (existed) {
      await _client
          .from('article_favorites')
          .delete()
          .eq('note_id', nid)
          .eq('user_id', uid);
      return false;
    }
    await _client.from('article_favorites').upsert({
      'note_id': nid,
      'user_id': uid,
    });
    return true;
  }

  /// 原文是否仍可作为文章打开。优先 RPC；失败则本地探测。
  Future<ArticleAvailability> resolveArticleAvailability(
    String noteId, {
    bool hintDeleted = false,
    bool hintDelisted = false,
  }) async {
    if (hintDeleted) return ArticleAvailability.deleted;
    if (hintDelisted) return ArticleAvailability.delisted;
    final nid = noteId.trim();
    if (nid.isEmpty || !BakedEnv.hasSupabase) {
      return ArticleAvailability.delisted;
    }
    try {
      final raw = await _client.rpc(
        'article_availability',
        params: {'p_id': nid},
      );
      final s = '$raw'.trim().toLowerCase();
      if (s == 'ok') return ArticleAvailability.ok;
      if (s == 'deleted') return ArticleAvailability.deleted;
      if (s == 'delisted' || s == 'missing') {
        return ArticleAvailability.delisted;
      }
    } catch (_) {
      /* RPC 未部署时走探测 */
    }
    try {
      final row = await _client
          .from('notes')
          .select('id, kind, deleted_at')
          .eq('id', nid)
          .maybeSingle();
      if (row != null) {
        if (row['deleted_at'] != null) return ArticleAvailability.deleted;
        if ('${row['kind']}' != 'article') return ArticleAvailability.delisted;
        return ArticleAvailability.ok;
      }
    } catch (_) {}
    // 他人侧 RLS 不可见：删文或已改类型都当「已下架」更贴近阅读入口
    return ArticleAvailability.delisted;
  }

  /// 我的收藏：按收藏时间倒序。删文/改类型后仍保留记录（stub），点开再提示。
  Future<List<MarketplaceArticle>> fetchMyFavorites({int limit = 200}) async {
    final uid = _uid;
    if (uid == null) return const [];
    final favRows = await _client
        .from('article_favorites')
        .select('note_id, created_at')
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(limit);
    final ids = (favRows as List)
        .map((r) => '${(r as Map)['note_id'] ?? ''}')
        .where((e) => e.isNotEmpty)
        .toList();
    if (ids.isEmpty) return const [];

    // 含 kind：作者自己改类型后仍能读到行，标成下架 stub。
    final rows = await _client
        .from('notes')
        .select(
          'id, title, body, format, city, cover_url, listed_at, owner_id, kind, '
          'note_stats(view_count, recommend_count, comment_count)',
        )
        .in_('id', ids)
        .is_('deleted_at', null);
    final byId = <String, MarketplaceArticle>{};
    for (final r in (rows as List)) {
      final map = Map<String, dynamic>.from(r as Map);
      final id = '${map['id'] ?? ''}';
      if (id.isEmpty) continue;
      if ('${map['kind']}' != 'article') {
        byId[id] = MarketplaceArticle(
          noteUuid: id,
          title: '${map['title'] ?? ''}'.trim().isEmpty
              ? '已下架的文章'
              : '${map['title']}',
          body: '',
          format: 'plain',
          ownerId: '${map['owner_id'] ?? ''}',
          delisted: true,
        );
        continue;
      }
      byId[id] = _articleFromMap(map);
    }
    return [
      for (final id in ids)
        byId[id] ??
            MarketplaceArticle(
              noteUuid: id,
              title: '已删除的文章',
              body: '',
              format: 'plain',
              deleted: true,
            ),
    ];
  }

  Future<void> _bumpRecommend(String noteId, int delta) async {
    final row = await _client
        .from('note_stats')
        .select('recommend_count')
        .eq('note_id', noteId)
        .maybeSingle();
    if (row == null) {
      await _client.from('note_stats').upsert({
        'note_id': noteId,
        'view_count': 0,
        'recommend_count': delta > 0 ? delta : 0,
        'comment_count': 0,
      });
      return;
    }
    final cur = _asInt((row as Map)['recommend_count']);
    final next = (cur + delta).clamp(0, 1 << 30);
    await _client
        .from('note_stats')
        .update({'recommend_count': next}).eq('note_id', noteId);
  }

  // —— comments ——

  Future<List<ArticleComment>> listComments(String noteId) async {
    final nid = noteId.trim();
    if (nid.isEmpty) return const [];
    final rows = await _client
        .from('article_comments')
        .select(
          'id, note_id, author_id, parent_id, reply_to_user_id, body, created_at',
        )
        .eq('note_id', nid)
        .is_('deleted_at', null)
        .order('created_at', ascending: true)
        .limit(500);
    final list = (rows as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    final authorIds = list.map((m) => '${m['author_id']}').toSet();
    for (final m in list) {
      final r = '${m['reply_to_user_id'] ?? ''}';
      if (r.isNotEmpty) authorIds.add(r);
    }
    final profiles = await fetchProfiles(authorIds);
    return list.map((m) {
      final aid = '${m['author_id']}';
      final rid = '${m['reply_to_user_id'] ?? ''}';
      final ap = profiles[aid];
      final rp = rid.isEmpty ? null : profiles[rid];
      DateTime created;
      final raw = m['created_at'];
      if (raw is DateTime) {
        created = raw.toLocal();
      } else {
        created = DateTime.tryParse('$raw')?.toLocal() ?? DateTime.now();
      }
      final parent = '${m['parent_id'] ?? ''}';
      return ArticleComment(
        id: '${m['id']}',
        noteId: '${m['note_id']}',
        authorId: aid,
        parentId: parent.isEmpty ? null : parent,
        replyToUserId: rid.isEmpty ? null : rid,
        body: '${m['body'] ?? ''}',
        createdAt: created,
        authorNickname: ap?.displayName ?? '',
        authorAvatarUrl: ap?.avatarUrl ?? '',
        replyToNickname: rp?.displayName ?? '',
      );
    }).toList();
  }

  Future<ArticleComment> addComment({
    required String noteId,
    required String body,
    required String noteOwnerId,
    String? parentId,
    String? replyToUserId,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('请先登录');
    final text = body.trim();
    if (text.isEmpty) throw StateError('评点不能为空');
    final payload = <String, dynamic>{
      'note_id': noteId.trim(),
      'author_id': uid,
      'body': text,
    };
    final pid = parentId?.trim() ?? '';
    if (pid.isNotEmpty) payload['parent_id'] = pid;
    final rid = replyToUserId?.trim() ?? '';
    if (rid.isNotEmpty) payload['reply_to_user_id'] = rid;

    final row = await _client
        .from('article_comments')
        .insert(payload)
        .select(
          'id, note_id, author_id, parent_id, reply_to_user_id, body, created_at',
        )
        .single();

    await _bumpComment(noteId.trim(), 1);

    // 留言：顶层评点 → 通知文章作者（不含回复）
    // 回复：仅通知明确被回书的人（reply_to_user_id）
    try {
      String notifyUid = '';
      String kind = '';
      if (pid.isEmpty) {
        kind = 'comment';
        notifyUid = noteOwnerId.trim();
        if (notifyUid.isEmpty) {
          final note = await _client
              .from('notes')
              .select('owner_id')
              .eq('id', noteId.trim())
              .maybeSingle();
          notifyUid = '${note?['owner_id'] ?? ''}'.trim();
        }
      } else if (rid.isNotEmpty) {
        kind = 'reply';
        notifyUid = rid;
      }
      if (notifyUid.isNotEmpty && notifyUid != uid && kind.isNotEmpty) {
        await _client.from('social_notifications').insert({
          'user_id': notifyUid,
          'actor_id': uid,
          'kind': kind,
          'note_id': noteId.trim(),
          'comment_id': '${(row as Map)['id']}',
          'body': text.length > 80 ? '${text.substring(0, 80)}…' : text,
        });
      }
    } catch (e, st) {
      debugPrint('social_notifications insert failed: $e\n$st');
    }

    final me = await fetchProfile(uid);
    final map = Map<String, dynamic>.from(row as Map);
    return ArticleComment(
      id: '${map['id']}',
      noteId: '${map['note_id']}',
      authorId: uid,
      parentId: pid.isEmpty ? null : pid,
      replyToUserId: rid.isEmpty ? null : rid,
      body: text,
      createdAt: DateTime.tryParse('${map['created_at']}')?.toLocal() ??
          DateTime.now(),
      authorNickname: me?.displayName ?? '',
      authorAvatarUrl: me?.avatarUrl ?? '',
    );
  }

  Future<void> _bumpComment(String noteId, int delta) async {
    final row = await _client
        .from('note_stats')
        .select('comment_count')
        .eq('note_id', noteId)
        .maybeSingle();
    if (row == null) {
      await _client.from('note_stats').upsert({
        'note_id': noteId,
        'view_count': 0,
        'recommend_count': 0,
        'comment_count': delta > 0 ? delta : 0,
      });
      return;
    }
    final cur = _asInt((row as Map)['comment_count']);
    final next = (cur + delta).clamp(0, 1 << 30);
    await _client
        .from('note_stats')
        .update({'comment_count': next}).eq('note_id', noteId);
  }

  // —— notifications ——

  Future<List<SocialNotificationItem>> listMyNotifications({int limit = 100}) async {
    final uid = _uid;
    if (uid == null) return const [];
    final rows = await _client
        .from('social_notifications')
        .select(
          'id, kind, actor_id, body, created_at, note_id, comment_id, read_at',
        )
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(limit);
    final list = (rows as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    final actorIds = list.map((m) => '${m['actor_id']}').toSet();
    final noteIds = list
        .map((m) => '${m['note_id'] ?? ''}')
        .where((e) => e.isNotEmpty)
        .toSet();
    final profiles = await fetchProfiles(actorIds);
    final titles = <String, String>{};
    if (noteIds.isNotEmpty) {
      final notes = await _client
          .from('notes')
          .select('id, title')
          .in_('id', noteIds.toList());
      for (final n in (notes as List)) {
        final m = Map<String, dynamic>.from(n as Map);
        titles['${m['id']}'] = '${m['title'] ?? ''}';
      }
    }
    return list.map((m) {
      final aid = '${m['actor_id']}';
      final nid = '${m['note_id'] ?? ''}';
      DateTime created;
      final raw = m['created_at'];
      if (raw is DateTime) {
        created = raw.toLocal();
      } else {
        created = DateTime.tryParse('$raw')?.toLocal() ?? DateTime.now();
      }
      DateTime? readAt;
      final rr = m['read_at'];
      if (rr != null) {
        readAt = rr is DateTime ? rr.toLocal() : DateTime.tryParse('$rr')?.toLocal();
      }
      return SocialNotificationItem(
        id: '${m['id']}',
        kind: '${m['kind']}',
        actorId: aid,
        body: '${m['body'] ?? ''}',
        createdAt: created,
        noteId: nid.isEmpty ? null : nid,
        commentId: '${m['comment_id'] ?? ''}'.isEmpty
            ? null
            : '${m['comment_id']}',
        readAt: readAt,
        actorNickname: profiles[aid]?.displayName ?? '',
        noteTitle: titles[nid] ?? '',
      );
    }).toList();
  }

  Future<void> markNotificationsRead(Iterable<String> ids) async {
    final uid = _uid;
    if (uid == null) return;
    final list = ids.where((e) => e.trim().isNotEmpty).toList();
    if (list.isEmpty) return;
    await _client.from('social_notifications').update({
      'read_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('user_id', uid).in_('id', list);
  }

  /// 从留言与回复中移除一条提醒（不删评点/文章）。
  Future<void> deleteNotification(String id) async {
    final uid = _uid;
    final nid = id.trim();
    if (uid == null) throw StateError('请先登录');
    if (nid.isEmpty) return;
    await _client
        .from('social_notifications')
        .delete()
        .eq('user_id', uid)
        .eq('id', nid);
  }

  // —— 近期阅读（仅登录用户；游客永不写此表）——

  Future<List<ArticleReadRecord>> fetchMyArticleReads({int limit = 100}) async {
    final uid = _uid;
    if (uid == null) return const [];
    // 近期是用户侧快照；封面优先快照 cover_url，否则回落 notes.cover_url。
    List rows;
    try {
      rows = await _client
          .from('user_article_reads')
          .select(
            'note_id, title, body, format, city, cover_url, owner_id, '
            'last_read_at, notes(cover_url)',
          )
          .eq('user_id', uid)
          .order('last_read_at', ascending: false)
          .limit(limit) as List;
    } catch (_) {
      rows = await _client
          .from('user_article_reads')
          .select(
            'note_id, title, body, format, city, owner_id, '
            'last_read_at, notes(cover_url)',
          )
          .eq('user_id', uid)
          .order('last_read_at', ascending: false)
          .limit(limit) as List;
    }
    return rows.map((r) {
      final m = Map<String, dynamic>.from(r as Map);
      final at = m['last_read_at'];
      final snapCover = '${m['cover_url'] ?? ''}'.trim();
      final note = m['notes'];
      final noteCover = note is Map
          ? '${note['cover_url'] ?? ''}'.trim()
          : '';
      return ArticleReadRecord(
        noteUuid: '${m['note_id'] ?? ''}',
        title: '${m['title'] ?? ''}',
        body: '${m['body'] ?? ''}',
        format: '${m['format'] ?? 'plain'}',
        city: '${m['city'] ?? ''}',
        coverUrl: snapCover.isNotEmpty ? snapCover : noteCover,
        ownerId: '${m['owner_id'] ?? ''}',
        lastReadAt: at is DateTime
            ? at.toUtc()
            : (DateTime.tryParse('$at')?.toUtc() ?? DateTime.now().toUtc()),
      );
    }).where((e) => e.noteUuid.isNotEmpty).toList();
  }

  Future<void> upsertArticleReadCloud({
    required String noteUuid,
    required String title,
    required String body,
    required String format,
    String city = '',
    String coverUrl = '',
    String ownerId = '',
    DateTime? lastReadAt,
  }) async {
    final uid = _uid;
    final nid = noteUuid.trim();
    if (uid == null) throw StateError('请先登录');
    if (nid.isEmpty) throw StateError('无效文章');
    final at = (lastReadAt ?? DateTime.now()).toUtc().toIso8601String();
    final payload = <String, dynamic>{
      'user_id': uid,
      'note_id': nid,
      'title': title,
      'body': body,
      'format': format,
      'city': city,
      'owner_id': ownerId.trim().isEmpty ? null : ownerId.trim(),
      'last_read_at': at,
      'cover_url': coverUrl.trim(),
    };
    try {
      await _client
          .from('user_article_reads')
          .upsert(payload, onConflict: 'user_id,note_id');
    } catch (_) {
      // 云端尚未加 cover_url 列时降级写入，列表仍可通过 notes 联表显示封面
      payload.remove('cover_url');
      await _client
          .from('user_article_reads')
          .upsert(payload, onConflict: 'user_id,note_id');
    }
  }

  Future<void> deleteArticleReadCloud(String noteUuid) async {
    final uid = _uid;
    final nid = noteUuid.trim();
    if (uid == null) throw StateError('请先登录');
    if (nid.isEmpty) return;
    await _client
        .from('user_article_reads')
        .delete()
        .eq('user_id', uid)
        .eq('note_id', nid);
  }
}
