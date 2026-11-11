import 'package:shared_preferences/shared_preferences.dart';

import '../config/baked_env.dart';

/// Supabase 同步与本机 owner_id。
/// owner_id 由登录会话绑定；游客为空，不同步个人笔记。
class SyncSettings {
  SyncSettings._();
  static final SyncSettings instance = SyncSettings._();

  static const _kEnabled = 'sync_enabled';
  static const _kOwner = 'sync_owner_id';
  // 旧版偏好清理
  static const _kDatabaseUrl = 'sync_database_url';
  static const _kLegacyUrl = 'sync_supabase_url';
  static const _kLegacyAnon = 'sync_supabase_anon';

  bool enabled = false;
  String ownerId = '';

  bool get configured =>
      enabled && BakedEnv.hasSupabase && ownerId.trim().isNotEmpty;

  bool get providerKeysBundled => BakedEnv.hasSupabase;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    ownerId = prefs.getString(_kOwner) ?? '';

    if (prefs.containsKey(_kEnabled)) {
      enabled = prefs.getBool(_kEnabled) ?? false;
    } else if (BakedEnv.hasSupabase) {
      enabled = BakedEnv.syncEnabled;
    } else {
      enabled = false;
    }

    // 未登录时即使 bake 了 syncEnabled，也不应推拉业务数据。
    if (ownerId.trim().isEmpty || !BakedEnv.hasSupabase) {
      enabled = false;
    }

    // 清理旧 Neon / 手填 URL 偏好
    for (final k in [_kDatabaseUrl, _kLegacyUrl, _kLegacyAnon]) {
      if (prefs.containsKey(k)) await prefs.remove(k);
    }
  }

  Future<void> save({
    required bool enabled,
    String? ownerId,
    // 兼容旧设置页签名；已忽略
    String? databaseUrl,
  }) async {
    this.enabled = enabled &&
        BakedEnv.hasSupabase &&
        (ownerId ?? this.ownerId).trim().isNotEmpty;
    if (ownerId != null && ownerId.trim().isNotEmpty) {
      this.ownerId = ownerId.trim();
    }
    if (this.ownerId.trim().isEmpty || !BakedEnv.hasSupabase) {
      this.enabled = false;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, this.enabled);
    await prefs.setString(_kOwner, this.ownerId);
  }

  /// 登录后绑定 owner，并开启同步（若已配置 Supabase）。
  Future<void> bindOwner(String userId) async {
    final id = userId.trim();
    if (id.isEmpty) return;
    ownerId = id;
    enabled = BakedEnv.hasSupabase;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kOwner, ownerId);
    await prefs.setBool(_kEnabled, enabled);
  }

  /// 退出登录：清空 owner，关闭业务同步。
  Future<void> clearOwner() async {
    ownerId = '';
    enabled = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kOwner);
    await prefs.setBool(_kEnabled, false);
  }
}
