/// 谏言（公开 listed admonition）
class AdmonitionItem {
  const AdmonitionItem({
    required this.id,
    this.title = '',
    this.body = '',
    this.format = 'quill',
  });

  final String id;
  final String title;
  final String body;
  final String format;

  factory AdmonitionItem.fromMap(Map<String, dynamic> m) => AdmonitionItem(
        id: '${m['id'] ?? ''}',
        title: '${m['title'] ?? ''}',
        body: '${m['body'] ?? ''}',
        format: '${m['format'] ?? 'quill'}',
      );
}

class UserProfile {
  const UserProfile({
    required this.id,
    this.nickname = '',
    this.avatarUrl = '',
    this.isAdmin = false,
  });

  final String id;
  final String nickname;
  final String avatarUrl;
  final bool isAdmin;

  String get displayName {
    final n = nickname.trim();
    if (n.isNotEmpty) return n;
    return '用户${id.length >= 4 ? id.substring(0, 4) : id}';
  }

  /// 带缓存破坏参数的展示 URL（上传时已写入 ?v=）。
  String get avatarDisplayUrl => avatarUrl.trim();

  factory UserProfile.fromMap(Map<String, dynamic> m) => UserProfile(
        id: '${m['id'] ?? ''}',
        nickname: '${m['nickname'] ?? ''}',
        avatarUrl: '${m['avatar_url'] ?? ''}',
        isAdmin: m['is_admin'] == true,
      );
}

class ArticleComment {
  const ArticleComment({
    required this.id,
    required this.noteId,
    required this.authorId,
    this.parentId,
    this.replyToUserId,
    required this.body,
    required this.createdAt,
    this.authorNickname = '',
    this.authorAvatarUrl = '',
    this.replyToNickname = '',
  });

  final String id;
  final String noteId;
  final String authorId;
  final String? parentId;
  final String? replyToUserId;
  final String body;
  final DateTime createdAt;
  final String authorNickname;
  final String authorAvatarUrl;
  final String replyToNickname;

  bool get isReply => parentId != null && parentId!.isNotEmpty;
}

class SocialNotificationItem {
  const SocialNotificationItem({
    required this.id,
    required this.kind,
    required this.actorId,
    required this.body,
    required this.createdAt,
    this.noteId,
    this.commentId,
    this.readAt,
    this.actorNickname = '',
    this.noteTitle = '',
  });

  final String id;
  final String kind; // comment | reply | recommend | follow
  final String actorId;
  final String body;
  final DateTime createdAt;
  final String? noteId;
  final String? commentId;
  final DateTime? readAt;
  final String actorNickname;
  final String noteTitle;

  bool get isRead => readAt != null;
}
