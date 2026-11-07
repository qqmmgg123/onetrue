import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../sync/neon_connection.dart';
import '../sync/sync_settings.dart';
import 'auth_models.dart';
import 'password_hasher.dart';

/// 手机号+密码鉴权（直连 Neon app_users）。
/// 正式版应改为后端 Auth API，勿在客户端持有 DATABASE_URL。
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _kSession = 'auth_session_json';
  static final _phoneRe = RegExp(r'^1\d{10}$');

  AuthUser? currentUser;

  bool get isLoggedIn => currentUser != null;
  bool get isGuest => currentUser == null;
  bool get isLandlord => currentUser != null;

  Future<void> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSession);
    if (raw == null || raw.isEmpty) {
      currentUser = null;
      return;
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final user = AuthUser.fromJson(map);
      if (user.id.isEmpty || user.phone.isEmpty) {
        currentUser = null;
        return;
      }
      currentUser = user;
      await SyncSettings.instance.bindOwner(user.id);
    } catch (_) {
      currentUser = null;
    }
  }

  Future<AuthUser> register({
    required String phone,
    required String password,
    String displayName = '',
  }) async {
    final p = phone.trim();
    final pw = password;
    if (!_phoneRe.hasMatch(p)) {
      throw StateError('请输入合法的 11 位手机号');
    }
    if (pw.length < 6) {
      throw StateError('密码至少 6 位');
    }
    final conn = await _open();
    try {
      final exists = await conn.query(
        'SELECT id FROM app_users WHERE phone = @phone LIMIT 1',
        substitutionValues: {'phone': p},
      );
      if (exists.isNotEmpty) {
        throw StateError('该手机号已注册，请直接登录');
      }
      final id = const Uuid().v4();
      final hash = PasswordHasher.hash(pw);
      await conn.execute(
        '''
        INSERT INTO app_users (id, phone, password_hash, display_name)
        VALUES (@id, @phone, @hash, @name)
        ''',
        substitutionValues: {
          'id': id,
          'phone': p,
          'hash': hash,
          'name': displayName.trim(),
        },
      );
      final user = AuthUser(id: id, phone: p, displayName: displayName.trim());
      await _persist(user);
      return user;
    } finally {
      await conn.close();
    }
  }

  Future<AuthUser> login({
    required String phone,
    required String password,
  }) async {
    final p = phone.trim();
    final pw = password;
    if (!_phoneRe.hasMatch(p)) {
      throw StateError('请输入合法的 11 位手机号');
    }
    final conn = await _open();
    try {
      final rows = await conn.query(
        '''
        SELECT id, phone, password_hash, display_name
        FROM app_users
        WHERE phone = @phone
        LIMIT 1
        ''',
        substitutionValues: {'phone': p},
      );
      if (rows.isEmpty) {
        throw StateError('账号不存在，请先注册');
      }
      final row = rows.first;
      final hash = '${row[2]}';
      if (!PasswordHasher.verify(pw, hash)) {
        throw StateError('密码不正确');
      }
      final user = AuthUser(
        id: '${row[0]}',
        phone: '${row[1]}',
        displayName: '${row[3] ?? ''}',
      );
      await _persist(user);
      return user;
    } finally {
      await conn.close();
    }
  }

  Future<void> logout() async {
    currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSession);
    await SyncSettings.instance.clearOwner();
  }

  Future<void> _persist(AuthUser user) async {
    currentUser = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSession, jsonEncode(user.toJson()));
    await SyncSettings.instance.bindOwner(user.id);
  }

  Future<PostgreSQLConnection> _open() async {
    await SyncSettings.instance.load();
    final url = SyncSettings.instance.databaseUrl.trim();
    if (url.isEmpty) {
      throw StateError('未配置数据库，无法注册/登录');
    }
    return NeonEndpoint.parse(url).open();
  }
}
