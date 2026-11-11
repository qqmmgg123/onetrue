class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    this.phone = '',
    this.displayName = '',
  });

  final String id;
  final String email;
  final String phone;
  final String displayName;

  String get emailMasked {
    final e = email.trim();
    final at = e.indexOf('@');
    if (at <= 1) return e;
    final name = e.substring(0, at);
    final domain = e.substring(at);
    if (name.length <= 2) return '${name[0]}***$domain';
    return '${name.substring(0, 2)}***$domain';
  }

  String get phoneMasked {
    final p = phone.trim();
    if (p.length < 7) return p;
    return '${p.substring(0, 3)}****${p.substring(p.length - 4)}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'phone': phone,
        'display_name': displayName,
      };

  factory AuthUser.fromJson(Map<String, dynamic> j) => AuthUser(
        id: '${j['id'] ?? ''}',
        email: '${j['email'] ?? ''}',
        phone: '${j['phone'] ?? ''}',
        displayName: '${j['display_name'] ?? ''}',
      );
}
