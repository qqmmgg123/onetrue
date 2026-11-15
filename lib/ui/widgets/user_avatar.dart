import 'package:flutter/material.dart';

/// 默认头像 + 网络头像（带 cacheWidth 减轻内存；URL 含 ?v= 破缓存）。
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    this.url,
    this.nickname = '',
    this.radius = 28,
  });

  final String? url;
  final String nickname;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final u = (url ?? '').trim();
    final initials = _initials(nickname);
    if (u.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: const Color(0xFFE8E8E8),
        child: Text(
          initials,
          style: TextStyle(
            color: const Color(0xFF666666),
            fontSize: radius * 0.7,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFFE8E8E8),
      backgroundImage: NetworkImage(u),
      onBackgroundImageError: (_, __) {},
      child: null,
    );
  }

  static String _initials(String name) {
    final n = name.trim();
    if (n.isEmpty) return '醍';
    if (n.length == 1) return n;
    return n.substring(0, 1);
  }
}
