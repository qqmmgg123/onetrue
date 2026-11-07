import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../data/app_database.dart';
import '../domain/models.dart';
import '../media/qiniu_uploader.dart';
import '../media/room_video_service.dart';
import '../media/video_file_cache.dart';
import '../share/room_share_poster.dart';
import 'busy.dart';
import 'format.dart';

/// 竖屏房间视频页：播放 + 底部飘浮价格 + 上传/更新 + 海报/视频分享。
class RoomVideoPage extends StatefulWidget {
  const RoomVideoPage({super.key, required this.roomId});

  final int roomId;

  @override
  State<RoomVideoPage> createState() => _RoomVideoPageState();
}

class _RoomVideoPageState extends State<RoomVideoPage> {
  final _svc = RoomVideoService();
  Room? _room;
  Property? _property;
  Lease? _lease;
  Tenant? _tenant;
  String? _roomUuid;
  VideoPlayerController? _player;
  bool _loading = true;
  bool _uploading = false;
  String _uploadStage = '';
  double? _uploadFraction;
  String? _error;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    _load();
  }

  @override
  void dispose() {
    _player?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  Future<void> _load() async {
    final db = AppDatabase.instance;
    final room = await db.getRoom(widget.roomId);
    Property? property;
    Lease? lease;
    Tenant? tenant;
    String? uuid;
    if (room != null) {
      property = await db.getProperty(room.propertyId);
      lease = await db.activeLeaseForRoom(room.id);
      if (lease != null) tenant = await db.getTenant(lease.tenantId);
      uuid = await db.roomUuid(room.id);
    }
    await _player?.dispose();
    _player = null;
    if (room != null && room.hasVideo) {
      try {
        // 七牛测试域名 https 证书常无效，播放前改成 http
        _player = await _openPlayer(QiniuUploader.playableUrl(room.videoUrl));
      } catch (e) {
        final msg = '$e';
        if (msg.contains('Source error') ||
            msg.contains('VideoError') ||
            msg.contains('Cleartext') ||
            msg.contains('SSL') ||
            msg.contains('Certificate')) {
          _error = '视频无法播放（网络/证书或编码问题）。\n'
              '七牛测试域名请用 http；自定义域名再开 https。\n'
              '仍不行请点「更新视频」重传。';
        } else {
          _error = '视频无法播放：$e';
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _room = room;
      _property = property;
      _lease = lease;
      _tenant = tenant;
      _roomUuid = uuid;
      _loading = false;
    });
  }

  double get _rent => _lease?.baseRent ?? 0;

  /// 先试本地缓存；Source error 时清缓存再拉网络（避免一直播旧的 HEVC 缓存）。
  Future<VideoPlayerController> _openPlayer(String url) async {
    Future<VideoPlayerController> fromFile(File f) async {
      final c = VideoPlayerController.file(f);
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      return c;
    }

    Future<VideoPlayerController> fromNet() async {
      final c = VideoPlayerController.networkUrl(Uri.parse(url));
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      // ignore: unawaited_futures
      VideoFileCache.prefetch(url);
      return c;
    }

    final cached = await VideoFileCache.find(url);
    if (cached != null) {
      try {
        return await fromFile(cached);
      } catch (_) {
        await VideoFileCache.invalidate(url);
      }
    }
    try {
      return await fromNet();
    } catch (e) {
      await VideoFileCache.invalidate(url);
      rethrow;
    }
  }

  Future<void> _pickAndUpload() async {
    if (!_svc.canUpload) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '未配置存储：请在 env.local 优先填七牛 QINIU_ACCESS_KEY / '
            'QINIU_SECRET_KEY / QINIU_BUCKET / QINIU_PUBLIC_BASE'
            '（可选再填 R2_* 作备用），然后重新 .\\build_apk.ps1',
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('拍摄视频'),
              subtitle: const Text('打开相机录制，最长约 3 分钟'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final picker = ImagePicker();
    final x = await picker.pickVideo(
      source: source,
      maxDuration: const Duration(minutes: 3),
    );
    if (x == null) return;
    if (!mounted) return;
    // 更新前先停掉旧播放器，避免一直占着旧缓存文件
    final oldUrl = _room?.videoUrl ?? '';
    await _player?.dispose();
    _player = null;
    if (oldUrl.isNotEmpty) {
      await VideoFileCache.invalidate(oldUrl);
    }
    setState(() {
      _uploading = true;
      _uploadStage = '准备上传…';
      _uploadFraction = null;
      _error = null;
    });
    var stage = '准备中…';
    void showStage(String s, [double? fraction]) {
      stage = s;
      if (!mounted) return;
      setState(() {
        _uploadStage = s;
        // 仅文案更新时保留已有百分比，避免直传心跳把进度条清掉
        if (fraction != null) _uploadFraction = fraction;
      });
    }
    try {
      final share = await _svc.uploadRoomVideo(
        roomId: widget.roomId,
        videoFile: File(x.path),
        onProgress: showStage,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已上传到 ${share.storageName}。分享链接：${share.shareUrl}'),
        ),
      );
      setState(() {
        _loading = true;
        _uploading = false;
        _uploadStage = '';
        _uploadFraction = null;
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('上传失败（$stage）：$e')),
      );
      // 失败时尽量恢复旧视频播放
      await _load();
    } finally {
      if (mounted && _uploading) {
        setState(() {
          _uploading = false;
          _uploadStage = '';
          _uploadFraction = null;
        });
      }
    }
  }

  String get _shareTitle =>
      '${_property?.name ?? ''} · ${_room?.label ?? ''}'.trim();

  String get _shareDesc => [
        if ((_tenant?.name ?? '').isNotEmpty) _tenant!.name,
        '月租 ${formatYuan(_rent)}',
        if ((_property?.address ?? '').isNotEmpty) _property!.address,
      ].join(' · ');

  Future<void> _shareMenu() async {
    final room = _room;
    if (room == null || !room.hasVideo) return;
    final uuid = _roomUuid;
    final webUrl = uuid == null ? null : _svc.shareUrlFor(uuid);

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (webUrl != null && webUrl.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('分享海报图（推荐）'),
                subtitle: const Text('封面+标题+描述+二维码，发微信长按识别即可打开'),
                onTap: () {
                  Navigator.pop(ctx);
                  _sharePosterImage(webUrl);
                },
              )
            else
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('海报分享未配置'),
                subtitle: Text('需要 SHARE_WEB_BASE 才能生成带二维码的海报'),
              ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('下载并分享视频文件'),
              subtitle: const Text('保存到本地，或用系统面板发给微信/文件等'),
              onTap: () {
                Navigator.pop(ctx);
                _downloadAndShareVideo();
              },
            ),
            if (webUrl != null && webUrl.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.link_outlined),
                title: const Text('复制/分享网页链接'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final text = [
                    webUrl,
                    '',
                    if (_shareTitle.isNotEmpty) _shareTitle,
                    if (_shareDesc.isNotEmpty) _shareDesc,
                  ].join('\n');
                  await Share.share(
                    text,
                    subject: _shareTitle.isEmpty ? '房间视频' : _shareTitle,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _sharePosterImage(String webUrl) async {
    final room = _room;
    if (room == null) return;
    try {
      final file = await runBusy(
        context,
        message: '正在生成分享海报…',
        task: () => RoomSharePoster.build(
              shareUrl: webUrl,
              title: _shareTitle,
              description: _shareDesc,
              posterUrl: room.videoPosterUrl,
            ),
      );
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/jpeg')],
        text: _shareTitle.isEmpty ? '房间实拍视频' : _shareTitle,
        subject: _shareTitle.isEmpty ? '房间实拍视频' : _shareTitle,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('生成海报失败：$e')),
      );
    }
  }

  Future<void> _downloadAndShareVideo() async {
    final room = _room;
    final rawUrl = room?.videoUrl ?? '';
    if (rawUrl.trim().isEmpty) return;
    final url = QiniuUploader.playableUrl(rawUrl);
    final label = [
      if ((_property?.name ?? '').isNotEmpty) _property!.name,
      if ((room?.label ?? '').isNotEmpty) room!.label,
    ].join('_');
    final fileName = label.isEmpty
        ? 'room_${room!.id}.mp4'
        : '${label.replaceAll(RegExp(r'\s+'), '_')}.mp4';
    try {
      final shared = await runBusy(
        context,
        message: '正在下载视频…',
        task: () async {
          final local = await VideoFileCache.ensureLocal(url);
          return VideoFileCache.copyForShare(
            local,
            preferredName: fileName,
          );
        },
      );
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(shared.path, mimeType: 'video/mp4')],
        text: _shareTitle.isEmpty ? '房间视频' : _shareTitle,
        subject: _shareTitle.isEmpty ? '房间视频' : _shareTitle,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载/分享失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    return Scaffold(
      backgroundColor: Colors.black,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : Stack(
              fit: StackFit.expand,
              children: [
                if (_player != null && _player!.value.isInitialized)
                  Center(
                    child: AspectRatio(
                      aspectRatio: _player!.value.aspectRatio == 0
                          ? 9 / 16
                          : _player!.value.aspectRatio,
                      child: VideoPlayer(_player!),
                    ),
                  )
                else
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _error ??
                            '这个房间还没有视频\n点下方「上传 / 更新视频」添加',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70, height: 1.5),
                      ),
                    ),
                  ),
                // 顶部返回
                SafeArea(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ),
                // 抖音式底部信息
                SafeArea(
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_property?.name ?? ''} · ${room?.label ?? ''}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              shadows: [
                                Shadow(blurRadius: 8, color: Colors.black54),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _tenant == null
                                ? '空房 · 月租 ${formatYuan(_rent)}'
                                : '${_tenant!.name} · 月租 ${formatYuan(_rent)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              shadows: [
                                Shadow(blurRadius: 8, color: Colors.black54),
                              ],
                            ),
                          ),
                          if ((_property?.address ?? '').isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              _property!.address,
                              style: const TextStyle(
                                color: Colors.white70,
                                shadows: [
                                  Shadow(blurRadius: 6, color: Colors.black45),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              FilledButton.tonal(
                                onPressed: _uploading ? null : _pickAndUpload,
                                child: Text(_uploading
                                    ? '上传中…'
                                    : (room?.hasVideo == true
                                        ? '拍摄/更新'
                                        : '拍摄/上传')),
                              ),
                              const SizedBox(width: 8),
                              if (room?.hasVideo == true)
                                OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: const BorderSide(color: Colors.white54),
                                  ),
                                  onPressed: _shareMenu,
                                  child: const Text('分享'),
                                ),
                              const Spacer(),
                              if (_player != null)
                                IconButton(
                                  onPressed: () {
                                    setState(() {
                                      if (_player!.value.isPlaying) {
                                        _player!.pause();
                                      } else {
                                        _player!.play();
                                      }
                                    });
                                  },
                                  icon: Icon(
                                    _player!.value.isPlaying
                                        ? Icons.pause_circle
                                        : Icons.play_circle,
                                    color: Colors.white,
                                    size: 36,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_uploading)
                  ColoredBox(
                    color: const Color(0x99000000),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 36),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_uploadFraction == null)
                              const CircularProgressIndicator(color: Colors.white)
                            else
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(
                                  value: _uploadFraction,
                                  minHeight: 10,
                                  backgroundColor: Colors.white24,
                                  color: Colors.white,
                                ),
                              ),
                            const SizedBox(height: 16),
                            Text(
                              _uploadStage.isEmpty ? '处理中…' : _uploadStage,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                height: 1.4,
                              ),
                            ),
                            if (_uploadFraction != null) ...[
                              const SizedBox(height: 6),
                              Text(
                                '${(_uploadFraction! * 100).clamp(0, 100).round()}%',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
