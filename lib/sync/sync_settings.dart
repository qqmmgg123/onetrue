import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Supabase 连接与本机 owner_id（多端同一账号需手动共用此 id，后续可改登录）。
class SyncSettings {
  SyncSettings._();
  static final SyncSettings instance = SyncSettings._();

  static const _kEnabled = 'sync_enabled';
  static const _kUrl = 'sync_supabase_url';
  static const _kAnon = 'sync_supabase_anon';
  static const _kOwner = 'sync_owner_id';

  bool enabled = false;
  String supabaseUrl = '';
  String anonKey = '';
  String ownerId = '';

  bool get configured =>
      enabled &&
      supabaseUrl.trim().isNotEmpty &&
      anonKey.trim().isNotEmpty &&
      ownerId.trim().isNotEmpty;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool(_kEnabled) ?? false;
    supabaseUrl = prefs.getString(_kUrl) ?? '';
    anonKey = prefs.getString(_kAnon) ?? '';
    ownerId = prefs.getString(_kOwner) ?? '';
    if (ownerId.isEmpty) {
      ownerId = const Uuid().v4();
      await prefs.setString(_kOwner, ownerId);
    }
  }

  Future<void> save({
    required bool enabled,
    required String supabaseUrl,
    required String anonKey,
    String? ownerId,
  }) async {
    this.enabled = enabled;
    this.supabaseUrl = supabaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    this.anonKey = anonKey.trim();
    if (ownerId != null && ownerId.trim().isNotEmpty) {
      this.ownerId = ownerId.trim();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, this.enabled);
    await prefs.setString(_kUrl, this.supabaseUrl);
    await prefs.setString(_kAnon, this.anonKey);
    await prefs.setString(_kOwner, this.ownerId);
  }
}
