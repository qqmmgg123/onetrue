import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

import '../config/baked_env.dart';
import '../sync/sync_settings.dart';
import 'auth_models.dart';

/// 邮箱 OTP 鉴权（Supabase Auth）。
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  AuthUser? currentUser;

  bool get isLoggedIn => currentUser != null;
  bool get isGuest => currentUser == null;
  bool get isLandlord => currentUser != null;

  /// 当前会话 JWT（调用 Edge Function 时带上）。
  String? get accessToken {
    if (!BakedEnv.hasSupabase) return null;
    return Supabase.instance.client.auth.currentSession?.accessToken;
  }

  SupabaseClient get _client {
    if (!BakedEnv.hasSupabase) {
      throw StateError('未配置 Supabase（SUPABASE_URL / SUPABASE_ANON_KEY）');
    }
    return Supabase.instance.client;
  }

  Future<void> loadSession() async {
    if (!BakedEnv.hasSupabase) {
      currentUser = null;
      return;
    }
    try {
      final session = _client.auth.currentSession;
      final user = session?.user;
      if (user == null || user.id.isEmpty) {
        currentUser = null;
        return;
      }
      currentUser = _fromSupabaseUser(user);
      await SyncSettings.instance.bindOwner(user.id);
    } catch (_) {
      currentUser = null;
    }
  }

  /// 向邮箱发送一次性验证码（sign-in / sign-up 共用）。
  Future<void> sendEmailOtp(String email) async {
    final e = email.trim();
    if (!_emailRe.hasMatch(e)) {
      throw StateError('请输入合法邮箱');
    }
    await _client.auth.signInWithOtp(
      email: e,
      shouldCreateUser: true,
    );
  }

  /// 校验邮箱 OTP 并建立会话。
  Future<AuthUser> verifyEmailOtp({
    required String email,
    required String token,
  }) async {
    final e = email.trim();
    final code = token.trim();
    if (!_emailRe.hasMatch(e)) {
      throw StateError('请输入合法邮箱');
    }
    if (code.isEmpty) {
      throw StateError('请输入验证码');
    }
    final res = await _client.auth.verifyOTP(
      email: e,
      token: code,
      type: OtpType.email,
    );
    final user = res.user ?? _client.auth.currentUser;
    if (user == null || user.id.isEmpty) {
      throw StateError('验证失败，请重试');
    }
    final authUser = _fromSupabaseUser(user);
    currentUser = authUser;
    await SyncSettings.instance.bindOwner(authUser.id);
    return authUser;
  }

  Future<void> logout() async {
    currentUser = null;
    if (BakedEnv.hasSupabase) {
      try {
        await _client.auth.signOut();
      } catch (_) {}
    }
    await SyncSettings.instance.clearOwner();
  }

  AuthUser _fromSupabaseUser(User user) {
    final meta = user.userMetadata ?? const <String, dynamic>{};
    final phone = '${user.phone ?? meta['phone'] ?? ''}'.trim();
    final name = '${meta['display_name'] ?? meta['full_name'] ?? ''}'.trim();
    return AuthUser(
      id: user.id,
      email: (user.email ?? '').trim(),
      phone: phone,
      displayName: name,
    );
  }
}
