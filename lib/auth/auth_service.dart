import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

import '../config/baked_env.dart';
import '../social/social_api.dart';
import '../sync/sync_settings.dart';
import 'auth_models.dart';

/// 邮箱 OTP / 密码鉴权（Supabase Auth）+ 社交档案。
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  AuthUser? currentUser;

  bool get isLoggedIn => currentUser != null;
  bool get isGuest => currentUser == null;
  bool get isLandlord => currentUser != null;

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
      currentUser = await _hydrateUser(user);
      await SyncSettings.instance.bindOwner(user.id);
    } catch (_) {
      currentUser = null;
    }
  }

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

  /// 注册结果：可能需要邮箱 OTP 确认。
  /// - [sessionReady] true：已登录
  /// - [needsOtp] true：等待邮箱验证码
  Future<({bool sessionReady, bool needsOtp})> signUpWithPassword({
    required String email,
    required String password,
    required String nickname,
  }) async {
    final e = email.trim();
    final p = password.trim();
    final nick = nickname.trim();
    if (!_emailRe.hasMatch(e)) {
      throw StateError('请输入合法邮箱');
    }
    if (p.length < 6) {
      throw StateError('密码至少 6 位');
    }
    if (nick.isEmpty) {
      throw StateError('请填写昵称');
    }
    final res = await _client.auth.signUp(
      email: e,
      password: p,
      data: {'display_name': nick, 'full_name': nick},
    );
    final session = res.session ?? _client.auth.currentSession;
    final user = res.user ?? session?.user;
    if (session != null && user != null && user.id.isNotEmpty) {
      await SyncSettings.instance.bindOwner(user.id);
      try {
        await SocialApi.instance.upsertMyProfile(nickname: nick);
      } catch (_) {}
      currentUser = await _hydrateUser(user);
      return (sessionReady: true, needsOtp: false);
    }
    // 开启「Confirm email」时无 session，需验证码
    return (sessionReady: false, needsOtp: true);
  }

  Future<void> resendSignupOtp(String email) async {
    final e = email.trim();
    if (!_emailRe.hasMatch(e)) {
      throw StateError('请输入合法邮箱');
    }
    await _client.auth.resend(
      type: OtpType.signup,
      email: e,
    );
  }

  /// 邮箱 + 密码登录；[nickname] 会写入/补全 profiles。
  Future<AuthUser> signInWithPassword({
    required String email,
    required String password,
    String nickname = '',
  }) async {
    final e = email.trim();
    final p = password.trim();
    if (!_emailRe.hasMatch(e)) {
      throw StateError('请输入合法邮箱');
    }
    if (p.isEmpty) {
      throw StateError('请输入密码');
    }
    final res = await _client.auth.signInWithPassword(email: e, password: p);
    final user = res.user ?? _client.auth.currentUser;
    if (user == null || user.id.isEmpty) {
      throw StateError('登录失败，请检查邮箱或密码');
    }
    await SyncSettings.instance.bindOwner(user.id);
    final nick = nickname.trim();
    try {
      if (nick.isNotEmpty) {
        await SocialApi.instance.upsertMyProfile(nickname: nick);
      } else {
        await SocialApi.instance.ensureProfile(
          fallbackNickname: _metaName(user),
        );
      }
    } catch (_) {
      // 档案表未迁移时不阻断登录
    }
    final authUser = await _hydrateUser(user);
    currentUser = authUser;
    return authUser;
  }

  Future<AuthUser> verifyEmailOtp({
    required String email,
    required String token,
    String nickname = '',
    OtpType type = OtpType.signup,
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
      type: type,
    );
    final user = res.user ?? _client.auth.currentUser;
    if (user == null || user.id.isEmpty) {
      throw StateError('验证失败，请重试');
    }
    await SyncSettings.instance.bindOwner(user.id);
    final nick = nickname.trim();
    try {
      if (nick.isNotEmpty) {
        await SocialApi.instance.upsertMyProfile(nickname: nick);
      } else {
        await SocialApi.instance.ensureProfile(
          fallbackNickname: _metaName(user),
        );
      }
    } catch (_) {}
    final authUser = await _hydrateUser(user);
    currentUser = authUser;
    return authUser;
  }

  Future<void> refreshProfile() async {
    final user = _client.auth.currentUser;
    if (user == null) return;
    currentUser = await _hydrateUser(user);
  }

  Future<void> updateNickname(String nickname) async {
    final n = nickname.trim();
    if (n.isEmpty) throw StateError('昵称不能为空');
    final p = await SocialApi.instance.upsertMyProfile(nickname: n);
    final cur = currentUser;
    if (cur != null) {
      currentUser = cur.copyWith(
        displayName: p.nickname,
        avatarUrl: p.avatarUrl,
      );
    }
  }

  Future<void> updateAvatarUrl(String url) async {
    final p = await SocialApi.instance.upsertMyProfile(avatarUrl: url);
    final cur = currentUser;
    if (cur != null) {
      currentUser = cur.copyWith(
        displayName: p.nickname,
        avatarUrl: p.avatarUrl,
      );
    }
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

  String _metaName(User user) {
    final meta = user.userMetadata ?? const <String, dynamic>{};
    return '${meta['display_name'] ?? meta['full_name'] ?? ''}'.trim();
  }

  Future<AuthUser> _hydrateUser(User user) async {
    final meta = user.userMetadata ?? const <String, dynamic>{};
    final phone = '${user.phone ?? meta['phone'] ?? ''}'.trim();
    var name = _metaName(user);
    var avatar = '';
    try {
      final profile = await SocialApi.instance.fetchProfile(user.id);
      if (profile != null) {
        if (profile.nickname.trim().isNotEmpty) name = profile.nickname.trim();
        avatar = profile.avatarUrl.trim();
      }
    } catch (_) {}
    return AuthUser(
      id: user.id,
      email: (user.email ?? '').trim(),
      phone: phone,
      displayName: name,
      avatarUrl: avatar,
    );
  }
}
