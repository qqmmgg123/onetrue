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
import 'busy.dart';
import 'format.dart';
import 'note_quill.dart';
import 'widgets/user_avatar.dart';

/// 文章详情：初始在详情；向左滑到作者陋室，向右滑回详情。
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
  late final PageController _page;

  @override
  void initState() {
    super.initState();
    // 0=详情，1=作者陋室：从详情向左滑到陋室
    _page = PageController(initialPage: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppStore>().recordArticleOpen(widget.article);
    });
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _page,
        children: [
          _ArticleDetailPane(
            article: widget.article,
            highlightCommentId: widget.highlightCommentId,
            onOpenAuthor: () => _page.animateToPage(
              1,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOut,
            ),
          ),
          _AuthorLoushiPane(
            ownerId: widget.article.ownerId,
            onBackToArticle: () => _page.animateToPage(
              0,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOut,
            ),
          ),
        ],
      ),
    );
  }
}

class _ArticleDetailPane extends StatefulWidget {
  const _ArticleDetailPane({
    required this.article,
    required this.onOpenAuthor,
    this.highlightCommentId,
  });

  final MarketplaceArticle article;
  final VoidCallback onOpenAuthor;
  final String? highlightCommentId;

  @override
  State<_ArticleDetailPane> createState() => _ArticleDetailPaneState();
}

class _ArticleDetailPaneState extends State<_ArticleDetailPane> {
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
    _loadSocial();
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
        const SnackBar(content: Text('请先登录再评点')),
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
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
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
              '回书 @${c.replyToNickname}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
            ),
          ],
          const SizedBox(height: 6),
          Text(c.body, style: const TextStyle(fontSize: 14, height: 1.4)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _replyingTo = c),
              child: const Text('回书'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final article = widget.article;
    return Scaffold(
      appBar: AppBar(
        title: Text(article.displayTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          if (article.ownerId.trim().isNotEmpty)
            TextButton(
              onPressed: widget.onOpenAuthor,
              child: const Text('作者陋室'),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
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
                Text(
                  article.ownerId.trim().isEmpty
                      ? '向左滑动可查看作者陋室（若已关联作者）。'
                      : '向左滑动打开作者陋室；向右滑回本文。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
                Text(
                  '评点',
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
                    child: Text('还没有评点，来抢沙发吧'),
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
                  '回书 ${_replyingTo!.authorNickname.isEmpty ? '用户' : _replyingTo!.authorNickname}',
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
                        hintText: _replyingTo == null ? '写评点…' : '写回书…',
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

class _AuthorLoushiPane extends StatefulWidget {
  const _AuthorLoushiPane({
    required this.ownerId,
    required this.onBackToArticle,
  });

  final String ownerId;
  final VoidCallback onBackToArticle;

  @override
  State<_AuthorLoushiPane> createState() => _AuthorLoushiPaneState();
}

class _AuthorLoushiPaneState extends State<_AuthorLoushiPane> {
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
      // 清掉旧 NetworkImage 缓存
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('作者陋室'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBackToArticle,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 20),
                      Center(
                        child: GestureDetector(
                          onTap: _isSelf ? _changeAvatar : null,
                          child: Column(
                            children: [
                              UserAvatar(
                                url: avatar,
                                nickname: nick,
                                radius: 40,
                              ),
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
                              if (!_isSelf &&
                                  widget.ownerId.trim().isNotEmpty) ...[
                                const SizedBox(height: 12),
                                FilledButton(
                                  onPressed: _followBusy ? null : _toggleFollow,
                                  child: Text(_following ? '已留意' : '留意'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      if (_articles.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 48),
                          child: Center(child: Text('这位作者还没有上架文章')),
                        )
                      else
                        ...List.generate(_articles.length, (i) {
                          final a = _articles[i];
                          return Column(
                            children: [
                              ListTile(
                                leading: const Icon(Icons.article_outlined),
                                title: Text(a.displayTitle),
                                subtitle: Text(
                                  [
                                    if (a.city.isNotEmpty) a.city,
                                    '❤ ${a.recommendCount} · 评 ${a.commentCount}',
                                  ].join(' · '),
                                ),
                                onTap: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          MarketplaceArticlePage(article: a),
                                    ),
                                  );
                                },
                              ),
                              const Divider(height: 1),
                            ],
                          );
                        }),
                    ],
                  ),
                ),
    );
  }
}
