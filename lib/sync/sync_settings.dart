import 'package:shared_preferences/shared_preferences.dart';

import '../config/baked_env.dart';

/// Neon/Postgres 连接与本机 owner_id。
/// 多用户后：owner_id 由登录账号绑定；游客为空，不同步房东业务数据。
class SyncSettings {
  SyncSettings._();
  static final SyncSettings instance = SyncSettings._();

  static const _kEnabled = 'sync_enabled';
  static const _kDatabaseUrl = 'sync_database_url';
  static const _kOwner = 'sync_owner_id';
  // 旧版 Supabase 偏好，仅用于一次性迁移提示，不再写入。
  static const _kLegacyUrl = 'sync_supabase_url';
  static const _kLegacyAnon = 'sync_supabase_anon';

  bool enabled = false;
  String databaseUrl = '';
  String ownerId = '';

  bool get configured =>
      enabled &&
      databaseUrl.trim().isNotEmpty &&
      ownerId.trim().isNotEmpty;

  bool get providerKeysBundled => BakedEnv.hasSyncDb;

  /// 仅有数据库 URL（游客拉广场房源用）。
  bool get hasDatabaseUrl => databaseUrl.trim().isNotEmpty;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    if (BakedEnv.hasSyncDb) {
      databaseUrl = BakedEnv.databaseUrl.trim();
    } else {
      databaseUrl = prefs.getString(_kDatabaseUrl) ?? '';
    }

    // 多用户：owner 只来自登录绑定写入的 prefs，不再自动生成 UUID，
    // 也不再强制用 bake 的 SYNC_OWNER_ID 覆盖（避免多账号串号）。
    ownerId = prefs.getString(_kOwner) ?? '';

    if (prefs.containsKey(_kEnabled)) {
      enabled = prefs.getBool(_kEnabled) ?? false;
    } else if (BakedEnv.hasSyncDb) {
      enabled = BakedEnv.syncEnabled;
    } else {
      enabled = false;
    }

    // 未登录时即使 bake 了 syncEnabled，也不应推拉业务数据。
    if (ownerId.trim().isEmpty) {
      enabled = false;
    }

    if (prefs.containsKey(_kLegacyUrl) || prefs.containsKey(_kLegacyAnon)) {
      await prefs.remove(_kLegacyUrl);
      await prefs.remove(_kLegacyAnon);
    }
  }

  Future<void> save({
    required bool enabled,
    required String databaseUrl,
    String? ownerId,
  }) async {
    this.enabled = enabled && (ownerId ?? this.ownerId).trim().isNotEmpty;
    if (!BakedEnv.hasSyncDb) {
      this.databaseUrl = databaseUrl.trim();
    }
    if (ownerId != null && ownerId.trim().isNotEmpty) {
      this.ownerId = ownerId.trim();
    }
    if (this.ownerId.trim().isEmpty) {
      this.enabled = false;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, this.enabled);
    if (!BakedEnv.hasSyncDb) {
      await prefs.setString(_kDatabaseUrl, this.databaseUrl);
    }
    await prefs.setString(_kOwner, this.ownerId);
  }

  /// 登录后绑定 owner，并开启同步（若已配置 DATABASE_URL）。
  Future<void> bindOwner(String userId) async {
    final id = userId.trim();
    if (id.isEmpty) return;
    ownerId = id;
    enabled = hasDatabaseUrl;
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
