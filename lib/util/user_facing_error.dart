/// 把后端 / SDK 英文错误转成对用户可读的中文。
String userFacingError(
  Object? error, {
  String fallback = '操作失败，请稍后重试',
}) {
  if (error == null) return fallback;
  var raw = error.toString().trim();
  if (raw.isEmpty) return fallback;

  raw = raw
      .replaceFirst(RegExp(r'^Bad state:\s*', caseSensitive: false), '')
      .replaceFirst(RegExp(r'^Exception:\s*', caseSensitive: false), '')
      .replaceFirst(RegExp(r'^StateError:\s*', caseSensitive: false), '')
      .replaceFirst(RegExp(r'^AuthApiException:\s*', caseSensitive: false), '')
      .replaceFirst(RegExp(r'^AuthException\(message:\s*', caseSensitive: false), '')
      .replaceFirst(RegExp(r'^AuthRetryableFetchException:\s*', caseSensitive: false), '')
      .replaceFirst(RegExp(r',\s*statusCode:.*\)$'), '')
      .replaceFirst(RegExp(r'^Error:\s*', caseSensitive: false), '')
      .trim();

  // 已是中文为主则原样返回（去掉常见英文前缀后）
  final mapped = _mapKnown(raw);
  if (mapped != null) return mapped;

  if (_looksMostlyChinese(raw)) return raw;
  return fallback;
}

String? _mapKnown(String raw) {
  final s = raw.toLowerCase();

  if (s.contains('invalid login credentials') ||
      s.contains('invalid email or password') ||
      s.contains('email or password is incorrect')) {
    return '邮箱或密码不正确';
  }
  if (s.contains('email not confirmed') ||
      s.contains('email address not confirmed')) {
    return '邮箱尚未验证，请先完成邮箱验证';
  }
  if (s.contains('user already registered') ||
      s.contains('already been registered') ||
      s.contains('user already exists')) {
    return '该邮箱已注册，请直接登录；若尚未验证，请点「去验证邮箱」';
  }
  if (s.contains('user not found')) {
    return '账号不存在，请先注册';
  }
  if (s.contains('password should be at least') ||
      s.contains('password is too short') ||
      (s.contains('password') && s.contains('at least 6'))) {
    return '密码至少 6 位';
  }
  if (s.contains('unable to validate email') ||
      s.contains('invalid email') ||
      s.contains('email format')) {
    return '请输入合法邮箱';
  }
  if (s.contains('email rate limit') ||
      s.contains('over_email_send_rate_limit') ||
      s.contains('rate limit')) {
    return '发送太频繁，请稍后再试';
  }
  if (s.contains('for security purposes') ||
      s.contains('only request this after')) {
    return '操作太频繁，请稍后再试';
  }
  if (s.contains('token has expired') ||
      s.contains('otp_expired') ||
      s.contains('email link is invalid or has expired')) {
    return '验证码已过期，请重新获取';
  }
  if (s.contains('token') && (s.contains('invalid') || s.contains('otp'))) {
    return '验证码不正确或已失效';
  }
  if (s.contains('network') ||
      s.contains('failed to fetch') ||
      s.contains('socketexception') ||
      s.contains('connection') ||
      s.contains('timed out') ||
      s.contains('timeout')) {
    return '网络异常，请检查网络后重试';
  }
  if (s.contains('jwt expired') ||
      s.contains('session') && s.contains('expired') ||
      s.contains('refresh token')) {
    return '登录已过期，请重新登录';
  }
  if (s.contains('supabase') && s.contains('未配置')) {
    return raw; // 已是我们自己的中文提示
  }
  if (s.contains('signup is disabled')) {
    return '当前未开放注册';
  }
  if (s.contains('weak password')) {
    return '密码过于简单，请换一个更安全的密码';
  }
  if (s.contains('same password') ||
      s.contains('should be different from the old password')) {
    return '新密码不能与旧密码相同';
  }
  return null;
}

bool _looksMostlyChinese(String s) {
  var cn = 0;
  var letters = 0;
  for (final r in s.runes) {
    if (r >= 0x4E00 && r <= 0x9FFF) {
      cn++;
    } else if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
      letters++;
    }
  }
  return cn > 0 && cn >= letters;
}
