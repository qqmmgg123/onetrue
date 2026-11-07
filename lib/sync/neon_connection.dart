import 'package:postgres/postgres.dart';

/// Parse postgresql://… for Neon / any Postgres (ssl preferred).
class NeonEndpoint {
  NeonEndpoint({
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    this.useSsl = true,
  });

  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final bool useSsl;

  static NeonEndpoint parse(String raw) {
    final uri = Uri.parse(raw.trim());
    if (uri.scheme != 'postgres' && uri.scheme != 'postgresql') {
      throw const FormatException('DATABASE_URL 需以 postgresql:// 开头');
    }
    final userInfo = uri.userInfo.split(':');
    final user = userInfo.isNotEmpty ? Uri.decodeComponent(userInfo.first) : '';
    final pass = userInfo.length > 1
        ? Uri.decodeComponent(userInfo.sublist(1).join(':'))
        : '';
    final db = uri.pathSegments.isNotEmpty
        ? uri.pathSegments.first
        : (uri.path.replaceFirst('/', '').split('?').first);
    if (uri.host.isEmpty || user.isEmpty || db.isEmpty) {
      throw const FormatException('DATABASE_URL 缺少 host / user / database');
    }
    final ssl = (uri.queryParameters['sslmode'] ?? 'require').toLowerCase();
    return NeonEndpoint(
      host: uri.host,
      port: uri.hasPort ? uri.port : 5432,
      database: db,
      username: user,
      password: pass,
      useSsl: ssl != 'disable',
    );
  }

  Future<PostgreSQLConnection> open() async {
    final conn = PostgreSQLConnection(
      host,
      port,
      database,
      username: username,
      password: password,
      useSSL: useSsl,
      timeoutInSeconds: 25,
    );
    await conn.open().timeout(const Duration(seconds: 25));
    return conn;
  }
}
