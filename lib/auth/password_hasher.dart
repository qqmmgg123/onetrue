import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 轻量口令哈希（一期测试用）。正式版应由服务端处理。
/// 格式：`sha256iter$<salt_hex>$<digest_hex>`
class PasswordHasher {
  static const _iters = 12000;

  static String hash(String password) {
    final salt = _randomHex(16);
    final digest = _derive(password, salt);
    return 'sha256iter\$$salt\$$digest';
  }

  static bool verify(String password, String stored) {
    final parts = stored.split('\$');
    if (parts.length != 3 || parts[0] != 'sha256iter') return false;
    final salt = parts[1];
    final expected = parts[2];
    return _derive(password, salt) == expected;
  }

  static String _derive(String password, String salt) {
    var bytes = utf8.encode('$salt:$password');
    Digest d = sha256.convert(bytes);
    for (var i = 0; i < _iters; i++) {
      d = sha256.convert(d.bytes);
    }
    return d.toString();
  }

  static String _randomHex(int byteLen) {
    final rnd = Random.secure();
    final buf = List<int>.generate(byteLen, (_) => rnd.nextInt(256));
    return buf.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
