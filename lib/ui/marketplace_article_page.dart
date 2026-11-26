import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' hide Text;
import 'package:provider/provider.dart';

import '../auth/auth_service.dart';
import '../domain/models.dart';
import '../social/avatar_io.dart';
import '../social/social_api.dart';
import '../social/social_models.dart';
import '../state/app_store.dart';
import '../sync/sync_service.dart';
import 'article_feed_card.dart';
import 'busy.dart';
import 'format.dart';
import 'note_editor_page.dart';
import 'note_quill.dart';
import 'open_article.dart';
import 'quill_image_embed.dart';
import 'widgets/cover_image.dart';
import 'widgets/user_avatar.dart';

/// 文章详情：作者头像可点进作者文章列表；本人可编辑本机笔记。
class MarketplaceArticlePage extends StatefulWidget {
  const MarketplaceArticlePage({
    super.key,
    required this.article,
    this.highlightCommentId,
  });

  final MarketplaceArticle article;
  final String? highlightCommentId;

  @override
  State<MarketplaceArticlePage> createState() => _MarketplaceArticlePageState();
}

class _MarketplaceArticlePageState extends State<MarketplaceArticlePage> {
  late final QuillController _quill;
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _commentInput = TextEditingController();
  final _commentKeys = <String, GlobalKey>{};

  bool _liked = false;
  bool _favorited = false;
  int _recommendCount = 0;
  int _commentCount = 0;
  List<ArticleComment> _comments = const [];
  bool _loadingSocial = true;
  ArticleComment? _replyingTo;
  UserProfile? _author;

  bool get _isSelf {
    final me = AuthService.instance.currentUser?.id ?? '';
    final oid = widget.article.ownerId.trim();
    return me.isNotEmpty && oid.isNotEmpty && me == oid;
  }

  Note? _localNote(AppStore store) {
    final uuid = widget.article.noteUuid.trim();
    if (uuid.isEmpty) return null;
    for (final n in store.notes) {
      if (n.uuid == uuid) return n;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final a = widget.article;
    _recommendCount = a.recommendCount;
    _commentCount = a.commentCount;
    _quill = QuillController(
      document: documentFromBody(a.body, format: a.format),
      selection: const TextSelection.collapsed(offset: 0),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppStore>().recordArticleOpen(widget.article);
    });
    _loadSocial();
    _loadAuthor();
  }

  Future<void> _loadAuthor() async {
    final oid = widget.article.ownerId.trim();
    if (oid.isEmpty) return;
    try {
      final p = await SocialApi.instance.fetchProfile(oid);
      if (!mounted) return;
      setState(() => _author = p);
    } catch (_) {}
  }

  Future<void> _loadSocial() async {
    final id = widget.article.noteUuid;
    try {
      final liked = await SocialApi.instance.hasRecommended(id);
      final favorited = await SocialApi.instance.hasFavorited(id);
      final count = await SocialApi.instance.recommendCount(id);
      final comments = await SocialApi.instance.listComments(id);
      if (!mounted) return;
      setState(() {
        _liked = liked;
        _favorited = favorited;
        _recommendCount = count;
        _comments = comments;
        _commentCount = comments.where((c) => !c.isReply).length;
        _loadingSocial = false;
      });
      final hid = widget.highlightCommentId?.trim() ?? '';
      if (hid.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _commentKeys[hid]?.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(
              ctx,
              duration: const Duration(milliseconds: 320),
              alignment: 0.2,
            );
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingSocial = false);
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    _commentInput.dispose();
    _quill.dispose();
    super.dispose();
  }

  Future<void> _openAuthor() async {
    final oid = widget.article.ownerId.trim();
    if (oid.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _AuthorArticlesPage(ownerId: oid),
      ),
    );
  }

  Future<void> _editLocal(Note note) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(noteId: note.id),
      ),
    );
  }

  Future<void> _deleteLocal(Note note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这篇文章？'),
        content: Text('确认删除「${note.displayTitle}」？删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final store = context.read<AppStore>();
    await runBusy(
      context,
      message: '正在删除…',
      task: () => store.removeNote(note.id),
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _toggleLike() async {
    final store = context.read<AppStore>();
    if (store.user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录再推荐')),
      );
      return;
    }
    try {
      final r = await runBusy(
        context,
        message: _liked ? '取消推荐…' : '推荐中…',
        task: () => SocialApi.instance.toggleRecommend(
          noteId: widget.article.noteUuid,
          ownerId: widget.article.ownerId,
        ),
      );
      if (!mounted) return;
      setState(() {
        _liked = r.recommended;
        _recommendCount = r.count;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'.replaceFirst('Bad state: ', ''))),
      );
    }
  }

  Future<void> _toggleFavorite() async {
    final store = context.read<AppStore>();
    if (store.user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录再收藏')),
      );
      return;
    }
    try {
      final on = await runBusy(
        context,
        message: _favorited ? '取消收藏…' : '收藏中…',
        task: () =>
            SocialApi.instance.toggleFavorite(widget.article.noteUuid),
      );
      if (!mounted) return;
      setState(() => _favorited = on);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(on ? '已收藏' : '已取消收藏'),
          duration: const Duration(seconds: 1),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'.replaceFirst('Bad state: ', ''))),
      );
    }
  }

  Future<void> _sendComment() async {
    final store = context.read<AppStore>();
    if (store.user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录再留言')),
      );
      return;
    }
    final text = _commentInput.text.trim();
    if (text.isEmpty) return;
    try {
      final c = await runBusy(
        context,
        message: '发送中…',
        task: () => SocialApi.instance.addComment(
          noteId: widget.article.noteUuid,
          body: text,
          noteOwnerId: widget.article.ownerId,
          parentId: _replyingTo?.parentId ?? _replyingTo?.id,
          replyToUserId: _replyingTo?.authorId,
        ),
      );
      if (!mounted) return;
      setState(() {
        _comments = [..._comments, c];
        _commentInput.clear();
        _replyingTo = null;
        if (!c.isReply) _commentCount += 1;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'.replaceFirst('Bad state: ', ''))),
      );
    }
  }

  List<Widget> _buildCommentTree() {
    final roots = _comments.where((c) => !c.isReply).toList();
    final replies = <String, List<ArticleComment>>{};
    for (final c in _comments.where((c) => c.isReply)) {
      final pid = c.parentId!;
      replies.putIfAbsent(pid, () => []).add(c);
    }
    final widgets = <Widget>[];
    for (final root in roots) {
      widgets.add(_commentTile(root, isRoot: true));
      for (final r in replies[root.id] ?? const <ArticleComment>[]) {
        widgets.add(_commentTile(r, isRoot: false));
      }
    }
    return widgets;
  }

  Widget _commentTile(ArticleComment c, {required bool isRoot}) {
    final key = _commentKeys.putIfAbsent(c.id, GlobalKey.new);
    final highlight = widget.highlightCommentId == c.id;
    return Container(
      key: key,
      margin: EdgeInsets.only(left: isRoot ? 0 : 28, bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xFFFFF6E8) : const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UserAvatar(
                url: c.authorAvatarUrl,
                nickname: c.authorNickname,
                radius: 14,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  c.authorNickname.isEmpty ? '用户' : c.authorNickname,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              Text(
                formatFriendlyWhen(c.createdAt),
                style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
              ),
            ],
          ),
          if (c.replyToNickname.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '回复 @${c.replyToNickname}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
            ),
          ],
          const SizedBox(height: 6),
          Text(c.body, style: const TextStyle(fontSize: 14, height: 1.4)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _replyingTo = c),
              child: const Text('回复'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final article = widget.article;
    final store = context.watch<AppStore>();
    final local = _isSelf ? _localNote(store) : null;
    final coverUrl = (local?.coverUrl.trim().isNotEmpty == true)
        ? local!.coverUrl
        : article.coverUrl;
    final nick = _author?.displayName.trim().isNotEmpty == true
        ? _author!.displayName
        : (_isSelf
            ? (AuthService.instance.currentUser?.displayName ?? '我')
            : '作者');
    final avatar = _isSelf
        ? (AuthService.instance.currentUser?.avatarUrl ??
            _author?.avatarUrl ??
            '')
        : (_author?.avatarUrl ?? '');

    return Scaffold(
      appBar: AppBar(
        title: Text(article.displayTitle),
        actions: [
          if (local != null) ...[
            TextButton(
              onPressed: () => _editLocal(local),
              child: const Text('编辑'),
            ),
            TextButton(
              onPressed: () => _deleteLocal(local),
              child: Text(
                '删除',
                style: TextStyle(color: Colors.red.shade700),
              ),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                if (coverUrl.trim().isNotEmpty) ...[
                  CoverImage(
                    url: coverUrl,
                    aspectRatio: 16 / 9,
                    borderRadius: 10,
                  ),
                  const SizedBox(height: 14),
                ],
                if (article.ownerId.trim().isNotEmpty)
                  InkWell(
                    onTap: _openAuthor,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        children: [
                          UserAvatar(
                            url: avatar,
                            nickname: nick,
                            radius: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              nick,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          const Icon(Icons.chevron_right, size: 20),
                        ],
                      ),
                    ),
                  ),
                if (article.city.isNotEmpty || article.listedAt != null)
                  Text(
                    [
                      if (article.city.isNotEmpty) article.city,
                      if (article.listedAt != null)
                        ymdCn(article.listedAt!.toLocal()),
                    ].join(' · '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 12),
                QuillEditor(
                  controller: _quill,
                  focusNode: _focus,
                  scrollController: ScrollController(),
                  scrollable: false,
                  padding: EdgeInsets.zero,
                  autoFocus: false,
                  readOnly: true,
                  expands: false,
                  showCursor: false,
                  enableInteractiveSelection: true,
                  embedBuilders: kNoteEmbedBuilders,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    IconButton(
                      tooltip: '推荐',
                      onPressed: _toggleLike,
                      icon: Icon(
                        _liked ? Icons.favorite : Icons.favorite_border,
                        color: _liked ? Colors.redAccent : null,
                      ),
                    ),
                    Text('$_recommendCount'),
                    IconButton(
                      tooltip: _favorited ? '取消收藏' : '收藏',
                      onPressed: _toggleFavorite,
                      icon: Icon(
                        _favorited ? Icons.star : Icons.star_border,
                        color: _favorited ? const Color(0xFFE6A800) : null,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chat_bubble_outline, size: 20),
                    const SizedBox(width: 6),
                    Text('$_commentCount'),
                    const Spacer(),
                    Text(
                      '浏览 ${article.viewCount}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  '留言',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (_loadingSocial)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_comments.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('还没有留言，来抢沙发吧'),
                  )
                else
                  ..._buildCommentTree(),
              ],
            ),
          ),
          if (_replyingTo != null)
            Material(
              color: const Color(0xFFF0F0F0),
              child: ListTile(
                dense: true,
                title: Text(
                  '回复 ${_replyingTo!.authorNickname.isEmpty ? '用户' : _replyingTo!.authorNickname}',
                  style: const TextStyle(fontSize: 13),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _replyingTo = null),
                ),
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _commentInput,
                      minLines: 1,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText:
                            _replyingTo == null ? '写留言…' : '写回复…',
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFFF5F5F5),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  TextButton(onPressed: _sendComment, child: const Text('发送')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 作者文章列表（由头像/昵称点入）。
class _AuthorArticlesPage extends StatefulWidget {
  const _AuthorArticlesPage({required this.ownerId});

  final String ownerId;

  @override
  State<_AuthorArticlesPage> createState() => _AuthorArticlesPageState();
}

class _AuthorArticlesPageState extends State<_AuthorArticlesPage> {
  bool _loading = true;
  String? _error;
  List<MarketplaceArticle> _articles = const [];
  UserProfile? _profile;
  bool _following = false;
  bool _followBusy = false;

  bool get _isSelf {
    final me = AuthService.instance.currentUser?.id ?? '';
    return me.isNotEmpty && me == widget.ownerId.trim();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final oid = widget.ownerId.trim();
    if (oid.isEmpty) {
      setState(() {
        _loading = false;
        _error = '暂无作者信息';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sync = SyncService(db: context.read<AppStore>().db);
      final articles = await sync.fetchListedArticles(ownerId: oid);
      final profile = await SocialApi.instance.fetchProfile(oid);
      var following = false;
      if (!_isSelf && AuthService.instance.isLoggedIn) {
        following = await SocialApi.instance.isFollowing(oid);
      }
      if (!mounted) return;
      setState(() {
        _articles = articles;
        _profile = profile;
        _following = following;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _toggleFollow() async {
    if (_isSelf) return;
    if (!AuthService.instance.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录再留意')),
      );
      return;
    }
    setState(() => _followBusy = true);
    try {
      if (_following) {
        await SocialApi.instance.unfollow(widget.ownerId);
      } else {
        await SocialApi.instance.follow(widget.ownerId);
      }
      if (!mounted) return;
      setState(() => _following = !_following);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  Future<void> _changeAvatar() async {
    if (!_isSelf) return;
    final uid = AuthService.instance.currentUser?.id ?? '';
    if (uid.isEmpty) return;
    try {
      final url = await pickCropUploadAvatar(context: context, userId: uid);
      if (url == null || !mounted) return;
      await runBusy(
        context,
        message: '更新头像…',
        task: () => AuthService.instance.updateAvatarUrl(url),
      );
      await AuthService.instance.refreshProfile();
      imageCache.clear();
      imageCache.clearLiveImages();
      if (!mounted) return;
      setState(() {
        _profile = UserProfile(
          id: uid,
          nickname: AuthService.instance.currentUser?.displayName ??
              _profile?.nickname ??
              '',
          avatarUrl: url,
        );
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('上传失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final nick = _profile?.displayName ??
        AuthService.instance.currentUser?.displayName ??
        '作者';
    final avatar = _isSelf
        ? (AuthService.instance.currentUser?.avatarUrl ??
            _profile?.avatarUrl ??
            '')
        : (_profile?.avatarUrl ?? '');

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        children: [
          GestureDetector(
            onTap: _isSelf ? _changeAvatar : null,
            child: Column(
              children: [
                UserAvatar(url: avatar, nickname: nick, radius: 40),
                if (_isSelf)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      '点击更换头像',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF888888),
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                Text(
                  nick,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!_isSelf && widget.ownerId.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _followBusy ? null : _toggleFollow,
                    child: Text(_following ? '已留意' : '留意'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('作者文章')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : ArticleFeedGrid(
                  articles: _articles,
                  header: header,
                  onRefresh: _load,
                  onOpen: (a) => openMarketplaceArticle(context, a),
                  empty: const Padding(
                    padding: EdgeInsets.only(top: 48),
                    child: Center(child: Text('这位作者还没有文章')),
                  ),
                ),
    );
  }
}
