import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

import '../config/baked_env.dart';
import '../social/social_api.dart';
import '../sync/sync_settings.dart';
import '../util/user_facing_error.dart';
import 'auth_models.dart';

StateError _authErr(Object e, String fallback) =>
    StateError(userFacingError(e, fallback: fallback));

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
      throw StateError(
        '未配置 Supabase（SUPABASE_URL / SUPABASE_ANON_KEY）。'
        '请用 .\\run_app.ps1 或 .\\build_apk.ps1 启动/打包，'
        '不要直接 flutter run（env.local 不会自动打进 App）',
      );
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
    try {
      await _client.auth.signInWithOtp(
        email: e,
        shouldCreateUser: true,
      );
    } catch (err) {
      throw _authErr(err, '发送验证码失败');
    }
  }

  /// 注册结果：可能需要邮箱 OTP 确认。
  /// - [sessionReady] true：已登录
  /// - [needsOtp] true：等待邮箱验证码（含「已登记未验证」）
  /// - [otpHint] 给 UI 的发信提示
  Future<({bool sessionReady, bool needsOtp, String? otpHint})>
      signUpWithPassword({
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
    try {
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
        return (sessionReady: true, needsOtp: false, otpHint: null);
      }
      // 已注册且已验证：静默成功 + identities 为空
      final identities = user?.identities;
      if (identities != null && identities.isEmpty) {
        throw StateError('该邮箱已注册，请直接登录');
      }
      // 新注册或未验证：再 resend，提高收到验证码概率
      var hint = '验证码已发送到邮箱，请查收后完成注册';
      try {
        await resendSignupOtp(e);
      } catch (mailErr) {
        final m = mailErr.toString().toLowerCase();
        if (m.contains('rate') || m.contains('security purposes')) {
          hint = '验证码发送较频繁，请稍后再点「重发验证码」，或查收此前邮件（含垃圾箱）';
        }
      }
      return (sessionReady: false, needsOtp: true, otpHint: hint);
    } catch (err) {
      if (err is StateError) rethrow;
      throw _authErr(err, '注册失败');
    }
  }

  /// 已登记未验证：主动发注册验证码并进入验证流程。
  Future<void> beginEmailVerification(String email) async {
    await resendSignupOtp(email);
  }

  Future<void> resendSignupOtp(String email) async {
    final e = email.trim();
    if (!_emailRe.hasMatch(e)) {
      throw StateError('请输入合法邮箱');
    }
    try {
      await _client.auth.resend(
        type: OtpType.signup,
        email: e,
      );
    } catch (err) {
      throw _authErr(err, '发送验证码失败');
    }
  }

  /// 忘记密码：向邮箱发送恢复验证码（需 Reset password 模板含 `{{ .Token }}`）。
  Future<void> sendPasswordResetOtp(String email) async {
    final e = email.trim();
    if (!_emailRe.hasMatch(e)) {
      throw StateError('请输入合法邮箱');
    }
    try {
      await _client.auth.resetPasswordForEmail(e);
    } catch (err) {
      throw _authErr(err, '发送验证码失败');
    }
  }

  /// 用恢复 OTP 验证身份并设置新密码。
  Future<AuthUser> resetPasswordWithOtp({
    required String email,
    required String token,
    required String newPassword,
  }) async {
    final e = email.trim();
    final code = token.trim();
    final p = newPassword.trim();
    if (!_emailRe.hasMatch(e)) {
      throw StateError('请输入合法邮箱');
    }
    if (code.isEmpty) {
      throw StateError('请输入验证码');
    }
    if (p.length < 6) {
      throw StateError('新密码至少 6 位');
    }
    try {
      final res = await _client.auth.verifyOTP(
        email: e,
        token: code,
        type: OtpType.recovery,
      );
      final user = res.user ?? _client.auth.currentUser;
      if (user == null || user.id.isEmpty) {
        throw StateError('验证失败，请重试');
      }
      await _client.auth.updateUser(UserAttributes(password: p));
      await SyncSettings.instance.bindOwner(user.id);
      try {
        await SocialApi.instance.ensureProfile(
          fallbackNickname: _metaName(user),
        );
      } catch (_) {}
      final authUser = await _hydrateUser(user);
      currentUser = authUser;
      return authUser;
    } catch (err) {
      if (err is StateError) rethrow;
      throw _authErr(err, '重置密码失败');
    }
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
    try {
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
    } catch (err) {
      if (err is StateError) rethrow;
      throw _authErr(err, '登录失败');
    }
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
    try {
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
    } catch (err) {
      if (err is StateError) rethrow;
      throw _authErr(err, '验证失败');
    }
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
