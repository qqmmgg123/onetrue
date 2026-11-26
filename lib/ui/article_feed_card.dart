import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../social/social_api.dart';
import '../social/social_models.dart';
import '../media/qiniu_uploader.dart';
import 'format.dart';
import 'note_quill.dart';
import 'widgets/user_avatar.dart';

/// 对齐 Web `.feed-card`：大封面 + 紧凑标题/摘要/作者。
class ArticleFeedCard extends StatelessWidget {
  const ArticleFeedCard({
    super.key,
    required this.article,
    this.author,
    this.footTime,
    this.onTap,
    this.onDelete,
    this.deleteTooltip = '删除',
  });

  final MarketplaceArticle article;
  final UserProfile? author;
  final DateTime? footTime;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final String deleteTooltip;

  String get _excerpt {
    final plain = plainTextFromStoredBody(
      article.body,
      format: article.format,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (plain.isEmpty) return article.displayTitle;
    return plain.length > 80 ? '${plain.substring(0, 80)}…' : plain;
  }

  String get _authorName {
    final n = author?.displayName.trim() ?? '';
    if (n.isNotEmpty) return n;
    return '作者';
  }

  @override
  Widget build(BuildContext context) {
    final city = article.city.trim().isEmpty ? '醍醐' : article.city.trim();
    final when = footTime ?? article.listedAt;
    final whenText = when == null ? '' : formatFriendlyWhen(when.toLocal());
    final cover = article.coverUrl.trim();

    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE5E5E5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (cover.isNotEmpty)
                    Image.network(
                      QiniuUploader.playableUrl(cover),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const _CoverPlaceholder(),
                    )
                  else
                    const _CoverPlaceholder(),
                  Positioned(
                    left: 12,
                    bottom: 10,
                    right: onDelete != null ? 40 : 12,
                    child: Text(
                      city,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cover.isEmpty
                            ? const Color(0xFF6B6B6B)
                            : Colors.white,
                        shadows: cover.isEmpty
                            ? null
                            : const [
                                Shadow(
                                  blurRadius: 6,
                                  color: Color(0x88000000),
                                ),
                              ],
                      ),
                    ),
                  ),
                  if (onDelete != null)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton(
                        tooltip: deleteTooltip,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: cover.isEmpty ? null : Colors.white,
                        ),
                        onPressed: onDelete,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    article.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      height: 1.35,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _excerpt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: Color(0xFF6B6B6B),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      UserAvatar(
                        url: author?.avatarUrl,
                        nickname: _authorName,
                        radius: 10,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF6B6B6B),
                          ),
                        ),
                      ),
                      Text(
                        [
                          '♥ ${article.recommendCount}',
                          if (whenText.isNotEmpty) whenText,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF8A8A8A),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFF0F0F0), Color(0xFFE2E2E2)],
            ),
          ),
        ),
        CustomPaint(painter: _CoverHatchPainter()),
      ],
    );
  }
}

class _CoverHatchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x05000000)
      ..strokeWidth = 1;
    const step = 12.0;
    for (var x = -size.height; x < size.width + size.height; x += step) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 两列 cover 网格；自动拉取作者 profiles。
class ArticleFeedGrid extends StatefulWidget {
  const ArticleFeedGrid({
    super.key,
    required this.articles,
    required this.onOpen,
    this.onRefresh,
    this.empty,
    this.deleteMode = ArticleFeedDeleteMode.none,
    this.onDelete,
    this.deleteTooltip = '删除',
    this.header,
    this.footTimeOf,
  });

  final List<MarketplaceArticle> articles;
  final Future<void> Function(MarketplaceArticle article) onOpen;
  final Future<void> Function()? onRefresh;
  final Widget? empty;
  final ArticleFeedDeleteMode deleteMode;
  final Future<void> Function(MarketplaceArticle article)? onDelete;
  final String deleteTooltip;
  final Widget? header;
  final DateTime? Function(MarketplaceArticle article)? footTimeOf;

  @override
  State<ArticleFeedGrid> createState() => _ArticleFeedGridState();
}

enum ArticleFeedDeleteMode { none, always, ownOnly }

class _ArticleFeedGridState extends State<ArticleFeedGrid> {
  Map<String, UserProfile> _profiles = const {};

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  @override
  void didUpdateWidget(covariant ArticleFeedGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.articles, widget.articles)) {
      _loadProfiles();
    }
  }

  Future<void> _loadProfiles() async {
    final ids = widget.articles
        .map((a) => a.ownerId.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) {
      if (mounted) setState(() => _profiles = const {});
      return;
    }
    try {
      final map = await SocialApi.instance.fetchProfiles(ids);
      if (!mounted) return;
      setState(() => _profiles = map);
    } catch (_) {
      /* 离线仍展示卡片 */
    }
  }

  bool _canDelete(MarketplaceArticle a) {
    switch (widget.deleteMode) {
      case ArticleFeedDeleteMode.none:
        return false;
      case ArticleFeedDeleteMode.always:
        return widget.onDelete != null;
      case ArticleFeedDeleteMode.ownOnly:
        return widget.onDelete != null && a.ownerId.trim().isNotEmpty;
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.articles;
    final header = widget.header;
    final emptyChild = widget.empty ??
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 48, 24, 24),
          child: Text('暂无文章', textAlign: TextAlign.center),
        );

    Widget body;
    if (list.isEmpty) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (header != null) header,
          emptyChild,
        ],
      );
    } else {
      body = CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (header != null) SliverToBoxAdapter(child: header),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                // 封面 4:3 占主高度，正文区紧凑，避免大块空白
                childAspectRatio: 0.62,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final a = list[i];
                  return ArticleFeedCard(
                    article: a,
                    author: _profiles[a.ownerId.trim()],
                    footTime: widget.footTimeOf?.call(a),
                    onTap: () => widget.onOpen(a),
                    deleteTooltip: widget.deleteTooltip,
                    onDelete: _canDelete(a)
                        ? () => widget.onDelete?.call(a)
                        : null,
                  );
                },
                childCount: list.length,
              ),
            ),
          ),
        ],
      );
    }

    if (widget.onRefresh == null) return body;
    return RefreshIndicator(
      onRefresh: () async {
        await widget.onRefresh!();
        await _loadProfiles();
      },
      child: body,
    );
  }
}
