import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 房间视频本地文件缓存：第二次打开直接播本地文件，避免反复拉 CDN。
class VideoFileCache {
  VideoFileCache._();

  static const _dirName = 'room_video_cache';
  static const maxFiles = 24;

  static Future<Directory> _dir() async {
    final root = await getTemporaryDirectory();
    final d = Directory(p.join(root.path, _dirName));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 缓存键忽略 ?v= 等查询参数，同一对象只留一份本地文件。
  static String _key(String url) =>
      sha1.convert(utf8.encode(_stripQuery(url))).toString();

  static String _stripQuery(String url) {
    final i = url.indexOf('?');
    return i < 0 ? url.trim() : url.substring(0, i).trim();
  }

  static Future<File> _fileFor(String url) async {
    final d = await _dir();
    return File(p.join(d.path, '${_key(url)}.mp4'));
  }

  /// 已缓存且非空则返回，否则 null。
  static Future<File?> find(String url) async {
    if (url.trim().isEmpty) return null;
    final f = await _fileFor(url);
    if (await f.exists() && await f.length() > 0) return f;
    return null;
  }

  /// 后台下载到缓存（失败忽略）。
  static Future<void> prefetch(String url) async {
    if (url.trim().isEmpty) return;
    try {
      await ensureLocal(url);
    } catch (_) {
      // 缓存失败不影响在线播放
    }
  }

  /// 用刚上传的本地文件写入缓存，避免再从 CDN 拉一遍。
  static Future<void> putLocal(String url, File local) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty || !await local.exists()) return;
    final f = await _fileFor(trimmed);
    final tmp = File('${f.path}.part');
    await local.copy(tmp.path);
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
    await _trim();
  }

  /// 确保本地有文件；已缓存则直接返回，否则下载。
  static Future<File> ensureLocal(
    String url, {
    void Function(double? fraction)? onProgress,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) throw StateError('视频地址为空');
    final existing = await find(trimmed);
    if (existing != null) {
      onProgress?.call(1);
      return existing;
    }
    final f = await _fileFor(trimmed);
    final tmp = File('${f.path}.part');
    onProgress?.call(null);
    final res = await http
        .get(Uri.parse(trimmed))
        .timeout(const Duration(minutes: 15));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('下载失败 HTTP ${res.statusCode}');
    }
    await tmp.writeAsBytes(res.bodyBytes, flush: true);
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
    await _trim();
    onProgress?.call(1);
    return f;
  }

  /// 复制到应用文档目录，便于用户从系统分享面板另存。
  static Future<File> copyForShare(
    File cached, {
    String? preferredName,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'shared_videos'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final name = (preferredName == null || preferredName.trim().isEmpty)
        ? 'room_${DateTime.now().millisecondsSinceEpoch}.mp4'
        : preferredName.trim().endsWith('.mp4')
            ? preferredName.trim()
            : '${preferredName.trim()}.mp4';
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final out = File(p.join(dir.path, safe));
    await cached.copy(out.path);
    return out;
  }

  static Future<void> invalidate(String url) async {
    if (url.trim().isEmpty) return;
    try {
      final f = await _fileFor(url);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    // 兼容旧版：曾用「带 query 的完整 URL」做哈希
    try {
      final legacy = sha1.convert(utf8.encode(url.trim())).toString();
      final d = await _dir();
      final old = File(p.join(d.path, '$legacy.mp4'));
      if (await old.exists()) await old.delete();
    } catch (_) {}
  }

  static Future<void> _trim() async {
    try {
      final d = await _dir();
      final entities = await d.list().toList();
      final files = entities
          .whereType<File>()
          .where((e) => e.path.endsWith('.mp4'))
          .toList();
      if (files.length <= maxFiles) return;
      files.sort(
        (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
      );
      final drop = files.length - maxFiles;
      for (var i = 0; i < drop; i++) {
        try {
          await files[i].delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
