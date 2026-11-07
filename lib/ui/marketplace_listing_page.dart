import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../domain/models.dart';
import '../media/qiniu_uploader.dart';
import '../state/app_store.dart';

/// 游客只读房源详情（含视频播放）。
class MarketplaceListingPage extends StatefulWidget {
  const MarketplaceListingPage({super.key, required this.listing});

  final MarketplaceListing listing;

  @override
  State<MarketplaceListingPage> createState() => _MarketplaceListingPageState();
}

class _MarketplaceListingPageState extends State<MarketplaceListingPage> {
  VideoPlayerController? _player;
  String? _error;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final url = widget.listing.videoUrl.trim();
    if (url.isEmpty) {
      setState(() => _ready = true);
      return;
    }
    try {
      final playable = QiniuUploader.playableUrl(url);
      final c = VideoPlayerController.networkUrl(Uri.parse(playable));
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _player = c;
        _ready = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _ready = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final L = widget.listing;
    final subtitle = [
      if (L.city.isNotEmpty) L.city,
      if (L.address.isNotEmpty) L.address,
    ].join(' · ');
    return Scaffold(
      appBar: AppBar(
        title: Text('${L.propertyName} · ${L.roomLabel}'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            L.propertyName,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text('房间 ${L.roomLabel}'),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: TextStyle(color: Colors.grey.shade700)),
          ],
          const SizedBox(height: 16),
          if (!_ready)
            const AspectRatio(
              aspectRatio: 9 / 16,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_player != null && _player!.value.isInitialized)
            AspectRatio(
              aspectRatio: _player!.value.aspectRatio == 0
                  ? 9 / 16
                  : _player!.value.aspectRatio,
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  VideoPlayer(_player!),
                  VideoProgressIndicator(_player!, allowScrubbing: true),
                  Positioned(
                    right: 8,
                    bottom: 28,
                    child: IconButton.filled(
                      onPressed: () {
                        final p = _player!;
                        if (p.value.isPlaying) {
                          p.pause();
                        } else {
                          p.play();
                        }
                        setState(() {});
                      },
                      icon: Icon(
                        _player!.value.isPlaying
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              height: 180,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _error != null ? '视频暂不可播' : '暂无视频',
                style: TextStyle(color: Colors.grey.shade700),
              ),
            ),
          const SizedBox(height: 24),
          if (context.watch<AppStore>().isGuest)
            Text(
              '如需登记租约或管理自己的房源，请注册登录成为房东。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
            )
          else
            Text(
              '这是广场上架房源（只读）。管理自己的房间请回到「我的」。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
            ),
        ],
      ),
    );
  }
}
