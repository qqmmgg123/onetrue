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

  // —— profiles ——

  Future<UserProfile?> fetchProfile(String userId) async {
    final id = userId.trim();
    if (id.isEmpty) return null;
    final row = await _client
        .from('profiles')
        .select('id, nickname, avatar_url')
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
        .select('id, nickname, avatar_url')
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
        .select('id, nickname, avatar_url')
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

  /// 关注的人最新上架文章（按 listed_at 倒序）。
  Future<List<MarketplaceArticle>> fetchFollowingArticles({int limit = 100}) async {
    final ids = await followingIds();
    if (ids.isEmpty) return const [];
    final rows = await _client
        .from('notes')
        .select(
          'id, title, body, format, city, listed_at, owner_id, '
          'note_stats(view_count, recommend_count, comment_count)',
        )
        .is_('deleted_at', null)
        .eq('kind', 'article')
        .eq('listing_status', 'listed')
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

  /// 我的收藏：按收藏时间倒序。
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

    final rows = await _client
        .from('notes')
        .select(
          'id, title, body, format, city, listed_at, owner_id, '
          'note_stats(view_count, recommend_count, comment_count)',
        )
        .in_('id', ids)
        .is_('deleted_at', null);
    final byId = <String, MarketplaceArticle>{};
    for (final r in (rows as List)) {
      final a = _articleFromMap(Map<String, dynamic>.from(r as Map));
      if (a.noteUuid.isNotEmpty) byId[a.noteUuid] = a;
    }
    // 保持收藏时间顺序
    return ids.map((id) => byId[id]).whereType<MarketplaceArticle>().toList();
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

    // 通知：回复优先通知被回复者；否则通知作者（自己评自己不通知）
    final notifyUid = rid.isNotEmpty ? rid : noteOwnerId.trim();
    if (notifyUid.isNotEmpty && notifyUid != uid) {
      try {
        await _client.from('social_notifications').insert({
          'user_id': notifyUid,
          'actor_id': uid,
          'kind': pid.isNotEmpty ? 'reply' : 'comment',
          'note_id': noteId.trim(),
          'comment_id': '${(row as Map)['id']}',
          'body': text.length > 80 ? '${text.substring(0, 80)}…' : text,
        });
      } catch (_) {}
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

  // —— 近期阅读（仅登录用户；游客永不写此表）——

  Future<List<ArticleReadRecord>> fetchMyArticleReads({int limit = 100}) async {
    final uid = _uid;
    if (uid == null) return const [];
    final rows = await _client
        .from('user_article_reads')
        .select(
          'note_id, title, body, format, city, owner_id, last_read_at',
        )
        .eq('user_id', uid)
        .order('last_read_at', ascending: false)
        .limit(limit);
    return (rows as List).map((r) {
      final m = Map<String, dynamic>.from(r as Map);
      final at = m['last_read_at'];
      return ArticleReadRecord(
        noteUuid: '${m['note_id'] ?? ''}',
        title: '${m['title'] ?? ''}',
        body: '${m['body'] ?? ''}',
        format: '${m['format'] ?? 'plain'}',
        city: '${m['city'] ?? ''}',
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
    String ownerId = '',
    DateTime? lastReadAt,
  }) async {
    final uid = _uid;
    final nid = noteUuid.trim();
    if (uid == null) throw StateError('请先登录');
    if (nid.isEmpty) throw StateError('无效文章');
    final at = (lastReadAt ?? DateTime.now()).toUtc().toIso8601String();
    await _client.from('user_article_reads').upsert({
      'user_id': uid,
      'note_id': nid,
      'title': title,
      'body': body,
      'format': format,
      'city': city,
      'owner_id': ownerId.trim().isEmpty ? null : ownerId.trim(),
      'last_read_at': at,
    }, onConflict: 'user_id,note_id');
  }
}
