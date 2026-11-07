class AuthUser {
  const AuthUser({
    required this.id,
    required this.phone,
    this.displayName = '',
  });

  final String id;
  final String phone;
  final String displayName;

  String get phoneMasked {
    final p = phone.trim();
    if (p.length < 7) return p;
    return '${p.substring(0, 3)}****${p.substring(p.length - 4)}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'phone': phone,
        'display_name': displayName,
      };

  factory AuthUser.fromJson(Map<String, dynamic> j) => AuthUser(
        id: '${j['id'] ?? ''}',
        phone: '${j['phone'] ?? ''}',
        displayName: '${j['display_name'] ?? ''}',
      );
}
