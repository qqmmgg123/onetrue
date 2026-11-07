import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_compress/video_compress.dart';

import '../config/baked_env.dart';
import '../data/app_database.dart';
import '../domain/models.dart';
import 'qiniu_uploader.dart';
import 'r2_uploader.dart';
import 'video_codec_probe.dart';
import 'video_file_cache.dart';
import 'video_transcoder.dart';

class RoomVideoShare {
  const RoomVideoShare({
    required this.roomUuid,
    required this.videoUrl,
    required this.posterUrl,
    required this.shareUrl,
    required this.metaUrl,
    required this.storageName,
    this.videoObjectKey = '',
    this.posterObjectKey = '',
  });

  final String roomUuid;
  final String videoUrl;
  final String posterUrl;
  final String shareUrl;
  final String metaUrl;
  final String storageName;
  final String videoObjectKey;
  final String posterObjectKey;
}

/// 上传房间视频：本机处理好再传（七牛优先，失败用 R2）。
/// 云端转码已关闭：前期免智能多媒体费用；已是 H.264/MP4 则跳过重编。
class RoomVideoService {
  RoomVideoService({
    AppDatabase? db,
    QiniuUploader? qiniu,
    R2Uploader? r2,
  })  : _db = db ?? AppDatabase.instance,
        _qiniu = qiniu ?? QiniuUploader(),
        _r2 = r2 ?? R2Uploader();

  final AppDatabase _db;
  final QiniuUploader _qiniu;
  final R2Uploader _r2;

  bool get canUpload => _qiniu.configured || _r2.configured;

  String? shareUrlFor(String roomUuid) {
    final base = BakedEnv.shareWebBase.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty || roomUuid.isEmpty) return null;
    return '$base/r/$roomUuid';
  }

  /// [onProgress] 的 fraction 为 0~1；非上传阶段可为 null（不确定进度）。
  Future<RoomVideoShare> uploadRoomVideo({
    required int roomId,
    required File videoFile,
    File? posterFile,
    void Function(String stage, [double? fraction])? onProgress,
  }) async {
    final room = await _db.getRoom(roomId);
    if (room == null) throw StateError('房间不存在');
    final uuid = await _db.roomUuid(roomId);
    if (uuid == null || uuid.isEmpty) throw StateError('房间缺少同步 uuid');

    final property = await _db.getProperty(room.propertyId);
    final lease = await _db.activeLeaseForRoom(roomId);
    Tenant? tenant;
    if (lease != null) {
      tenant = await _db.getTenant(lease.tenantId);
    }
    final rent = lease?.baseRent ?? 0.0;
    final oldUrl = room.videoUrl;
    final oldPoster = room.videoPosterUrl;

    onProgress?.call('检查视频编码…');
    final prepared = await _prepareForUpload(videoFile, onProgress: onProgress);
    final uploadFile = prepared.video;
    final uploadPoster = posterFile ?? prepared.poster;

    // 已配七牛则只用七牛，不再自动改传 R2（国内常解析不了 R2，且会在
    // 七牛已成功落盘后被误判失败，导致 meta.json 写不上）。
    final backends = <_ObjectStore>[
      if (_qiniu.configured) _QiniuStore(_qiniu),
      if (!_qiniu.configured && _r2.configured) _R2Store(_r2),
    ];
    if (backends.isEmpty) {
      await prepared.cleanup();
      throw StateError(
        '未配置存储：请填七牛 QINIU_* 或 Cloudflare R2_*，然后重新打包',
      );
    }

    Object? lastError;
    try {
      for (var i = 0; i < backends.length; i++) {
        final backend = backends[i];
        final isFallback = i > 0;
        try {
          onProgress?.call(
            isFallback
                ? '${backends[i - 1].name} 失败，改用 ${backend.name}…'
                : '上传到 ${backend.name}…',
          );
          final share = await _uploadPrepared(
            store: backend,
            room: room,
            uuid: uuid,
            propertyName: property?.name ?? '',
            propertyAddress: property?.address ?? '',
            tenantName: tenant?.name ?? '',
            rent: rent,
            uploadFile: uploadFile,
            uploadPoster: uploadPoster,
            onProgress: onProgress,
          );
          if (oldUrl.isNotEmpty) {
            await VideoFileCache.invalidate(oldUrl);
          }
          await VideoFileCache.invalidate(share.videoUrl);
          // 直接用刚传的本地文件做缓存，避免再下 CDN（也可能仍是旧边缘节点）
          onProgress?.call('写入本地缓存…');
          try {
            await VideoFileCache.putLocal(share.videoUrl, uploadFile);
          } catch (_) {
            // ignore: unawaited_futures
            VideoFileCache.prefetch(share.videoUrl);
          }

          // 清理不阻断成功返回：同 key 覆盖已废弃，旧文件按 URL/历史路径删
          onProgress?.call('清理旧视频…');
          try {
            await _cleanupStaleRemote(
              uuid: uuid,
              newVideoKey: share.videoObjectKey,
              newPosterKey: share.posterObjectKey.isEmpty
                  ? null
                  : share.posterObjectKey,
              oldVideoUrl: oldUrl,
              oldPosterUrl: oldPoster,
              allStores: backends,
            ).timeout(const Duration(seconds: 25));
          } catch (_) {
            // 清理超时/失败不影响新视频可用
          }
          return share;
        } catch (e) {
          lastError = e;
          if (i == backends.length - 1) break;
          onProgress?.call('${backend.name} 失败：$e');
        }
      }
      throw StateError('视频上传失败：$lastError');
    } finally {
      await prepared.cleanup();
    }
  }

  /// 新文件已上传成功后清理旧对象（含历史固定路径 video.mp4 / poster.*）。
  Future<void> _cleanupStaleRemote({
    required String uuid,
    required String newVideoKey,
    required String? newPosterKey,
    required String oldVideoUrl,
    required String oldPosterUrl,
    required List<_ObjectStore> allStores,
  }) async {
    const posterExts = ['jpg', 'jpeg', 'png', 'webp'];
    for (final store in allStores) {
      final keys = <String>{
        // 历史固定路径
        'rooms/$uuid/video.mp4',
        for (final ext in posterExts) 'rooms/$uuid/poster.$ext',
      };
      final fromOldVideo = store.objectKeyFromPublicUrl(oldVideoUrl);
      if (fromOldVideo != null) keys.add(fromOldVideo);
      final fromOldPoster = store.objectKeyFromPublicUrl(oldPosterUrl);
      if (fromOldPoster != null) keys.add(fromOldPoster);

      keys.remove(newVideoKey);
      if (newPosterKey != null) keys.remove(newPosterKey);
      keys.removeWhere((k) => k.endsWith('/meta.json'));

      // 并行删，单 key 超时短，避免卡在「清理旧视频」
      await Future.wait(keys.map((key) async {
        try {
          await store
              .deleteObject(key)
              .timeout(const Duration(seconds: 8));
        } catch (_) {}
      }));
    }
  }

  Future<RoomVideoShare> _uploadPrepared({
    required _ObjectStore store,
    required Room room,
    required String uuid,
    required String propertyName,
    required String propertyAddress,
    required String tenantName,
    required double rent,
    required File uploadFile,
    required File? uploadPoster,
    void Function(String stage, [double? fraction])? onProgress,
  }) async {
    // 新逻辑（勿改回固定 video.mp4）：
    // 1) 每次用 video_<ts>.mp4，避开 CDN 同名缓存
    // 2) 分享页靠 meta.json 里的 videoUrl 找到真实文件
    // 3) 视频一成功就先写 meta，再传封面（封面失败也不挡分享）
    final ts = DateTime.now().millisecondsSinceEpoch;
    final videoKey = 'rooms/$uuid/video_$ts.mp4';
    onProgress?.call('上传视频（${store.name}）…', 0);
    final rawVideoUrl = await store.putFile(
      file: uploadFile,
      objectKey: videoKey,
      contentType: 'video/mp4',
      contentDisposition: 'inline',
      onBytesProgress: (sent, total) {
        onProgress?.call(
          _formatUploadProgress('上传视频（${store.name}）', sent, total),
          total > 0 ? (sent / total).clamp(0.0, 1.0) : null,
        );
      },
      onStage: (tip) => onProgress?.call(tip),
    );
    final videoUrl = _versionedUrl(rawVideoUrl);

    Map<String, dynamic> buildMeta({
      String posterUrl = '',
      String posterKey = '',
    }) =>
        <String, dynamic>{
          'id': uuid,
          'roomLabel': room.label,
          'propertyName': propertyName,
          'propertyAddress': propertyAddress,
          'tenantName': tenantName,
          'rent': rent,
          'videoUrl': videoUrl,
          'posterUrl': posterUrl,
          'videoKey': videoKey,
          'posterKey': posterKey,
          'storage': store.name,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'appDownloadUrl': BakedEnv.appDownloadUrl.trim(),
          'appDownloadHint': BakedEnv.appDownloadHint.trim(),
        };

    // 先写 meta（很小的 JSON），分享页立刻可用（指向 video_<ts>.mp4）
    onProgress?.call('写分享信息…');
    var metaUrl = await store.putJson(
      'rooms/$uuid/meta.json',
      buildMeta(),
      onStage: (tip) => onProgress?.call(tip),
    );

    var posterUrl = '';
    var posterKey = '';
    if (uploadPoster != null && await uploadPoster.exists()) {
      final pExt = _extOf(uploadPoster.path, 'jpg');
      posterKey = 'rooms/$uuid/poster_$ts.$pExt';
      try {
        onProgress?.call('上传封面（${store.name}）…', 0);
        final rawPoster = await store
            .putFile(
              file: uploadPoster,
              objectKey: posterKey,
              contentType: pExt == 'png' ? 'image/png' : 'image/jpeg',
              contentDisposition: 'inline',
              onBytesProgress: (sent, total) {
                onProgress?.call(
                  _formatUploadProgress('上传封面（${store.name}）', sent, total),
                  total > 0 ? (sent / total).clamp(0.0, 1.0) : null,
                );
              },
              onStage: (tip) => onProgress?.call(tip),
            )
            // 封面失败不应拖死整次上传；超时就跳过
            .timeout(const Duration(seconds: 25));
        posterUrl = _versionedUrl(rawPoster);
        onProgress?.call('更新分享信息…', 1);
        metaUrl = await store.putJson(
          'rooms/$uuid/meta.json',
          buildMeta(posterUrl: posterUrl, posterKey: posterKey),
          onStage: (tip) => onProgress?.call(tip),
        );
      } catch (_) {
        // 封面失败不阻断：视频 + meta 已足够分享播放
        onProgress?.call('封面跳过（不影响视频）', 1);
        posterKey = '';
        posterUrl = '';
      }
    }

    await _db.setRoomVideo(
      roomId: room.id,
      videoUrl: videoUrl,
      posterUrl: posterUrl,
    );

    return RoomVideoShare(
      roomUuid: uuid,
      videoUrl: videoUrl,
      posterUrl: posterUrl,
      shareUrl: shareUrlFor(uuid) ?? videoUrl,
      metaUrl: metaUrl,
      storageName: store.name,
      videoObjectKey: videoKey,
      posterObjectKey: posterKey,
    );
  }

  /// 必须得到可播的 H.264/MP4 再上传。
  /// 微信 HEVC 优先走 Media3；video_compress 仅作兜底且带超时，避免一直卡住。
  Future<_PreparedVideo> _prepareForUpload(
    File source, {
    void Function(String stage, [double? fraction])? onProgress,
  }) async {
    onProgress?.call('准备视频文件…');
    final work = await _copyToTemp(source);

    final probe = await VideoCodecProbe.probe(work.path);
    final srcBytes = await work.length();
    // 已是 H.264/MP4 可跳过；但过大时仍压缩一档，减轻直传压力（非关掉转码）
    final tooBigForSkip = srcBytes > 18 * 1024 * 1024;
    if (probe.skipReencode && !tooBigForSkip) {
      final mb = (srcBytes / (1024 * 1024)).toStringAsFixed(1);
      onProgress?.call('已是 H.264/MP4（${mb}MB），跳过转码');
      final poster = await _makePoster(work.path);
      return _PreparedVideo(
        video: work,
        poster: poster,
        temporary: work.path != source.path,
      );
    }
    if (probe.skipReencode && tooBigForSkip) {
      onProgress?.call(
        '已是 H.264，但 ${(srcBytes / (1024 * 1024)).toStringAsFixed(0)}MB 偏大，压缩后再传…',
        0,
      );
    } else {
      onProgress?.call(
        probe.isHevc
            ? '检测到 HEVC，开始转 H.264…'
            : '需要转码（${probe.videoMime.isEmpty ? "编码未知" : probe.videoMime}）…',
        0,
      );
    }

    File? out;

    // 1) Android Media3 强制 H.264（微信 HEVC 首选）
    if (VideoTranscoder.isSupported) {
      onProgress?.call(
        probe.isHevc ? '系统硬编 HEVC→H.264…' : '系统硬编转 H.264…',
        0,
      );
      out = await VideoTranscoder.transcodeToAvc(
        work.path,
        maxHeight: 720,
        onProgress: (pct) {
          onProgress?.call('系统硬编转 H.264… $pct%', pct / 100.0);
        },
      );
      if (out != null && await _isAvcFile(out)) {
        final poster = await _makePoster(out.path);
        if (work.path != source.path) {
          try {
            await work.delete();
          } catch (_) {}
        }
        return _PreparedVideo(video: out, poster: poster, temporary: true);
      }
      out = null;
      onProgress?.call('系统硬编未成功，改用备用压缩…');
    }

    // 2) video_compress 兜底：无音轨优先（微信片带音频时旧库易卡死）
    for (final attempt in <({VideoQuality q, bool audio, String tip})>[
      (q: VideoQuality.LowQuality, audio: false, tip: '备用压缩（无音轨）…'),
      (q: VideoQuality.LowQuality, audio: true, tip: '备用压缩（含音轨）…'),
    ]) {
      onProgress?.call(attempt.tip, 0);
      out = await _compressWithTimeout(
        work.path,
        quality: attempt.q,
        includeAudio: attempt.audio,
        onProgress: onProgress,
        timeout: const Duration(seconds: 75),
      );
      if (out != null && await _isAvcFile(out)) {
        final poster = await _makePoster(out.path);
        if (work.path != source.path) {
          try {
            await work.delete();
          } catch (_) {}
        }
        return _PreparedVideo(video: out, poster: poster, temporary: true);
      }
      if (out != null) {
        try {
          await out.delete();
        } catch (_) {}
      }
    }

    throw StateError(
      '本机未能转成可播放的 H.264'
      '（源编码 ${probe.videoMime.isEmpty ? "未知" : probe.videoMime}）。\n'
      '微信视频多为 HEVC；请更新 App 后重试，或换系统相机拍摄的视频。',
    );
  }

  Future<File> _copyToTemp(File source) async {
    try {
      final dir = await getTemporaryDirectory();
      final dest = File(p.join(
        dir.path,
        'upload_src_${DateTime.now().millisecondsSinceEpoch}.mp4',
      ));
      return await source.copy(dest.path);
    } catch (_) {
      return source;
    }
  }

  Future<File?> _makePoster(String videoPath) async {
    // 不用 video_compress 抽帧（微信 HEVC 上经常卡死）
    final native = await VideoTranscoder.thumbnail(videoPath);
    if (native != null) return native;
    try {
      final thumb = await VideoCompress.getFileThumbnail(
        videoPath,
        quality: 60,
        position: 1,
      ).timeout(const Duration(seconds: 6));
      if (await thumb.exists()) {
        final dir = await getTemporaryDirectory();
        final dest = File(p.join(
          dir.path,
          'room_poster_${DateTime.now().millisecondsSinceEpoch}.jpg',
        ));
        return await thumb.copy(dest.path);
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _isAvcFile(File f) async {
    final probe = await VideoCodecProbe.probe(f.path);
    return probe.isAvc || probe.skipReencode;
  }

  Future<File?> _compressWithTimeout(
    String path, {
    required VideoQuality quality,
    required bool includeAudio,
    void Function(String stage, [double? fraction])? onProgress,
    required Duration timeout,
  }) async {
    // video_compress 的 progress 是自定义 Observable（subscribe），不是 Stream
    dynamic subscription;
    try {
      try {
        await VideoCompress.deleteAllCache();
      } catch (_) {}
      try {
        subscription = VideoCompress.compressProgress$.subscribe((p) {
          final pct = (p as num).round().clamp(0, 100);
          onProgress?.call('备用压缩… $pct%', pct / 100.0);
        });
      } catch (_) {}
      final info = await VideoCompress.compressVideo(
        path,
        quality: quality,
        deleteOrigin: false,
        includeAudio: includeAudio,
      ).timeout(timeout, onTimeout: () {
        // ignore: discarded_futures
        VideoCompress.cancelCompression();
        return null;
      });
      final out = info?.file;
      if (out == null || !await out.exists() || await out.length() <= 0) {
        return null;
      }
      return out;
    } catch (_) {
      try {
        await VideoCompress.cancelCompression();
      } catch (_) {}
      return null;
    } finally {
      try {
        subscription?.unsubscribe();
      } catch (_) {}
    }
  }

  /// 公开地址加版本参数，避免 CDN/本地缓存一直命中旧文件。
  static String _versionedUrl(String url) {
    final base = url.trim();
    if (base.isEmpty) return base;
    final v = DateTime.now().millisecondsSinceEpoch;
    return base.contains('?') ? '$base&v=$v' : '$base?v=$v';
  }

  static String _extOf(String path, String fallback) {
    final i = path.lastIndexOf('.');
    if (i < 0 || i == path.length - 1) return fallback;
    return path.substring(i + 1).toLowerCase();
  }

  static String _formatUploadProgress(String label, int sent, int total) {
    String mb(int n) => (n / (1024 * 1024)).toStringAsFixed(1);
    if (total > 0) {
      final pct = ((sent / total) * 100).clamp(0, 100).round();
      return '$label $pct%（${mb(sent)}/${mb(total)} MB）';
    }
    return '$label ${mb(sent)} MB';
  }
}

abstract class _ObjectStore {
  String get name;

  Future<String> putFile({
    required File file,
    required String objectKey,
    String contentType,
    String contentDisposition,
    void Function(int sent, int total)? onBytesProgress,
    void Function(String tip)? onStage,
  });

  Future<String> putJson(
    String objectKey,
    Map<String, dynamic> data, {
    void Function(String tip)? onStage,
  });

  Future<void> deleteObject(String objectKey);

  /// 若 url 属于本存储公开域名，返回 object key；否则 null。
  String? objectKeyFromPublicUrl(String url);
}

String? _keyUnderPublicBase(String url, String publicBase) {
  final base = publicBase.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty) return null;
  var raw = url.trim();
  if (raw.isEmpty) return null;
  final q = raw.indexOf('?');
  if (q >= 0) raw = raw.substring(0, q);
  raw = raw.replaceAll(RegExp(r'/+$'), '');
  if (!raw.startsWith(base)) return null;
  var key = raw.substring(base.length);
  if (key.startsWith('/')) key = key.substring(1);
  return key.isEmpty ? null : key;
}

class _QiniuStore implements _ObjectStore {
  _QiniuStore(this._u);
  final QiniuUploader _u;
  @override
  String get name => _u.name;

  @override
  Future<String> putFile({
    required File file,
    required String objectKey,
    String contentType = 'video/mp4',
    String contentDisposition = 'inline',
    void Function(int sent, int total)? onBytesProgress,
    void Function(String tip)? onStage,
  }) =>
      _u.putFile(
        file: file,
        objectKey: objectKey,
        contentType: contentType,
        contentDisposition: contentDisposition,
        onBytesProgress: onBytesProgress,
        onStage: onStage,
      );

  @override
  Future<String> putJson(
    String objectKey,
    Map<String, dynamic> data, {
    void Function(String tip)? onStage,
  }) =>
      _u.putJson(objectKey, data, onStage: onStage);

  @override
  Future<void> deleteObject(String objectKey) => _u.deleteObject(objectKey);

  @override
  String? objectKeyFromPublicUrl(String url) =>
      _keyUnderPublicBase(url, _u.publicBase);
}

class _R2Store implements _ObjectStore {
  _R2Store(this._u);
  final R2Uploader _u;
  @override
  String get name => _u.name;

  @override
  Future<String> putFile({
    required File file,
    required String objectKey,
    String contentType = 'video/mp4',
    String contentDisposition = 'inline',
    void Function(int sent, int total)? onBytesProgress,
    void Function(String tip)? onStage,
  }) async {
    onStage?.call('上传到 $name…');
    return _u.putFile(
      file: file,
      objectKey: objectKey,
      contentType: contentType,
      contentDisposition: contentDisposition,
      onBytesProgress: onBytesProgress,
    );
  }

  @override
  Future<String> putJson(
    String objectKey,
    Map<String, dynamic> data, {
    void Function(String tip)? onStage,
  }) {
    onStage?.call('写分享信息…');
    return _u.putJson(objectKey, data);
  }

  @override
  Future<void> deleteObject(String objectKey) => _u.deleteObject(objectKey);

  @override
  String? objectKeyFromPublicUrl(String url) =>
      _keyUnderPublicBase(url, _u.publicBase);
}

class _PreparedVideo {
  _PreparedVideo({
    required this.video,
    required this.poster,
    required this.temporary,
  });

  final File video;
  final File? poster;
  final bool temporary;

  Future<void> cleanup() async {
    if (!temporary) return;
    try {
      if (await video.exists()) await video.delete();
    } catch (_) {}
    try {
      if (poster != null && await poster!.exists()) await poster!.delete();
    } catch (_) {}
  }
}
