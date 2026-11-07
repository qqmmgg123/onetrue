import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../config/baked_env.dart';

/// 七牛对象存储：优先表单直传（与控制台一致）；失败或超大文件再分片。
class QiniuUploader {
  /// 分片宜偏小：进度更密，单片卡住时也更容易超时重试。
  static const int _chunkBytes = 512 * 1024; // 512KB
  /// 控制台手动上传也是整包直传；手机视频多数落在此区间。
  /// 以前 >512KB 就强制分片，as0 上单片 HTTP 无进度，看起来像卡在 2/10。
  static const int _preferFormMaxBytes = 32 * 1024 * 1024;
  QiniuUploader({
    String? accessKey,
    String? secretKey,
    String? bucket,
    String? publicBase,
    String? uploadHost,
    String? pipeline,
  })  : accessKey = (accessKey ?? BakedEnv.qiniuAccessKey).trim(),
        secretKey = (secretKey ?? BakedEnv.qiniuSecretKey).trim(),
        bucket = (bucket ?? BakedEnv.qiniuBucket).trim(),
        publicBase = normalizePublicBase(
          (publicBase ?? BakedEnv.qiniuPublicBase).trim(),
        ),
        uploadHost = (uploadHost ?? BakedEnv.qiniuUploadHost)
            .trim()
            .replaceAll(RegExp(r'/+$'), ''),
        pipeline = (pipeline ?? BakedEnv.qiniuPipeline).trim();

  final String accessKey;
  final String secretKey;
  final String bucket;
  final String publicBase;
  final String uploadHost;
  final String pipeline;

  String get name => '七牛云';

  bool get configured =>
      accessKey.isNotEmpty &&
      secretKey.isNotEmpty &&
      bucket.isNotEmpty &&
      publicBase.isNotEmpty &&
      uploadHost.isNotEmpty;

  String publicUrlFor(String objectKey) => '$publicBase/$objectKey';

  /// 七牛测试域名 HTTPS 证书经常 Hostname mismatch，强制改用 http，否则 App 播不了。
  static String normalizePublicBase(String raw) {
    var s = raw.trim().replaceAll(RegExp(r'/+$'), '');
    if (s.isEmpty) return s;
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return s;
    final host = uri.host.toLowerCase();
    final isQiniuTest = host.endsWith('.clouddn.com') ||
        host.endsWith('.qiniudn.com') ||
        host.endsWith('.qnssl.com');
    if (isQiniuTest && uri.scheme == 'https') {
      return uri.replace(scheme: 'http').toString().replaceAll(RegExp(r'/+$'), '');
    }
    return s;
  }

  /// 播放/缓存前把错误的 https 测试域名改成 http。
  static String playableUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return url;
    final host = uri.host.toLowerCase();
    final isQiniuTest = host.endsWith('.clouddn.com') ||
        host.endsWith('.qiniudn.com') ||
        host.endsWith('.qnssl.com');
    if (isQiniuTest && uri.scheme == 'https') {
      return uri.replace(scheme: 'http').toString();
    }
    return url;
  }

  Future<String> putFile({
    required File file,
    required String objectKey,
    String contentType = 'video/mp4',
    String contentDisposition = 'inline',
    void Function(int sent, int total)? onBytesProgress,
    void Function(String tip)? onStage,
  }) async {
    if (!configured) {
      throw StateError(
        '未配置七牛（QINIU_ACCESS_KEY / SECRET_KEY / BUCKET / PUBLIC_BASE）',
      );
    }
    if (!await file.exists()) {
      throw StateError('本地文件不存在：${file.path}');
    }
    final size = await file.length();
    final isImage = contentType.toLowerCase().startsWith('image/');
    // 封面/小文件：走 putBytes（发完用源站确认，不傻等 as0 HTTP 回执）
    // 视频大文件直传若卡在回执，封面用同一套会一直停在 0%。
    if (isImage || size <= 2 * 1024 * 1024) {
      onBytesProgress?.call(0, size <= 0 ? 1 : size);
      onStage?.call(isImage ? '上传封面…' : '上传小文件…');
      final bytes = await file.readAsBytes();
      final url = await putBytes(
        bytes: bytes,
        objectKey: objectKey,
        contentType: contentType,
        filename: _safeFilename(contentType, file.path),
        onStage: onStage,
        onBytesProgress: onBytesProgress,
      );
      onBytesProgress?.call(bytes.isEmpty ? 1 : bytes.length, bytes.isEmpty ? 1 : bytes.length);
      return url;
    }
    // 与七牛控制台一致：先整包直传。直传被掐断再回退官方分片。
    if (size <= _preferFormMaxBytes) {
      try {
        return await _putFileForm(
          file: file,
          objectKey: objectKey,
          contentType: contentType,
          onBytesProgress: onBytesProgress,
          onStage: onStage,
        );
      } catch (e) {
        if (!_shouldFallbackToChunked(e)) rethrow;
        onStage?.call('直传中断，改用分片续传…');
      }
    }
    return _putFileChunked(
      file: file,
      objectKey: objectKey,
      fileSize: size,
      onBytesProgress: onBytesProgress,
      onStage: onStage,
    );
  }

  Uri get _uploadUri {
    final raw =
        uploadHost.contains('://') ? uploadHost : 'https://$uploadHost';
    return Uri.parse(raw);
  }

  /// 区域上传域名候选（主域名挂起时换备用）。
  List<Uri> get _uploadHosts {
    final primary = _uploadUri;
    final hosts = <Uri>[primary];
    final h = primary.host.toLowerCase();
    void add(String host) {
      final u = primary.replace(host: host);
      if (!hosts.any((x) => x.host == u.host)) hosts.add(u);
    }

    if (h.contains('as0')) {
      add('up-as0.qiniup.com');
      add('upload-as0.qiniup.com');
    } else if (h.contains('z1')) {
      add('up-z1.qiniup.com');
      add('upload-z1.qiniup.com');
    } else if (h.contains('z2')) {
      add('up-z2.qiniup.com');
      add('upload-z2.qiniup.com');
    } else {
      add('up.qiniup.com');
      add('upload.qiniup.com');
      add('up-as0.qiniup.com');
    }
    return hosts;
  }

  static bool _shouldFallbackToChunked(Object e) {
    final s = '$e'.toLowerCase();
    return _isTransientNet(e) ||
        s.contains('connection closed') ||
        s.contains('connection reset') ||
        s.contains('software caused connection abort') ||
        s.contains('http 57') ||
        s.contains('http 599');
  }

  /// 表单直传：磁盘流式写出（不整文件进内存），带真实字节进度。
  Future<String> _putFileForm({
    required File file,
    required String objectKey,
    required String contentType,
    void Function(int sent, int total)? onBytesProgress,
    void Function(String tip)? onStage,
  }) async {
    final fileSize = await file.length();
    final token = _uploadToken(objectKey);
    final filename = _safeFilename(contentType, file.path);
    Object? lastErr;
    final hosts = _uploadHosts;
    for (var hi = 0; hi < hosts.length; hi++) {
      final host = hosts[hi];
      for (var attempt = 1; attempt <= 2; attempt++) {
        try {
          onStage?.call(
            hi > 0
                ? '直传重试 ${host.host}…'
                : (attempt == 1 ? '直传上传中…' : '直传重试 $attempt/2…'),
          );
          onBytesProgress?.call(0, fileSize);
          await _multipartPutFile(
            host: host,
            token: token,
            objectKey: objectKey,
            file: file,
            fileSize: fileSize,
            filename: filename,
            contentType: contentType,
            onBytesProgress: onBytesProgress,
            onStage: onStage,
          );
          onBytesProgress?.call(fileSize, fileSize);
          return publicUrlFor(objectKey);
        } catch (e) {
          lastErr = e;
          if (e is StateError && '$e'.contains('七牛上传失败 4')) rethrow;
          await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
        }
      }
    }
    throw StateError('七牛直传失败：$lastErr');
  }

  /// 用 HttpClient 流式 multipart，边读文件边写 socket，才能刷百分比。
  Future<void> _multipartPutFile({
    required Uri host,
    required String token,
    required String objectKey,
    required File file,
    required int fileSize,
    required String filename,
    required String contentType,
    void Function(int sent, int total)? onBytesProgress,
    void Function(String tip)? onStage,
  }) async {
    final boundary = '----RentAgent${DateTime.now().millisecondsSinceEpoch}';
    final preamble = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="token"\r\n\r\n'
      '$token\r\n'
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="key"\r\n\r\n'
      '$objectKey\r\n'
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; filename="$filename"\r\n'
      'Content-Type: $contentType\r\n\r\n',
    );
    final epilogue = utf8.encode('\r\n--$boundary--\r\n');
    final totalBody = preamble.length + fileSize + epilogue.length;

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    client.idleTimeout = const Duration(seconds: 60);
    try {
      final req = await client.postUrl(host).timeout(const Duration(seconds: 20));
      req.headers.set(HttpHeaders.contentTypeHeader,
          'multipart/form-data; boundary=$boundary');
      req.contentLength = totalBody;

      var written = 0;
      void note(int n) {
        written += n;
        // 进度按「文件本体」估算，不把 multipart 头算进百分比
        final fileSent =
            (written - preamble.length).clamp(0, fileSize);
        onBytesProgress?.call(fileSent, fileSize);
        final pct = fileSize == 0 ? 0 : ((fileSent / fileSize) * 100).round();
        onStage?.call('直传上传中… $pct%');
      }

      req.add(preamble);
      note(preamble.length);

      final raf = await file.open(mode: FileMode.read);
      try {
        const step = 64 * 1024;
        var left = fileSize;
        while (left > 0) {
          final take = left < step ? left : step;
          final chunk = await raf.read(take);
          if (chunk.isEmpty) {
            throw StateError('读取视频失败（剩余 $left 字节）');
          }
          req.add(chunk);
          note(chunk.length);
          left -= chunk.length;
        }
      } finally {
        await raf.close();
      }

      req.add(epilogue);
      note(epilogue.length);

      final res = await req.close().timeout(const Duration(minutes: 3));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 200 && res.statusCode < 300) return;
      if (res.statusCode >= 400 && res.statusCode < 500) {
        throw StateError('七牛上传失败 ${res.statusCode}: $body');
      }
      throw StateError('七牛上传失败 ${res.statusCode}: $body');
    } finally {
      client.close(force: true);
    }
  }

  /// 大文件 / 直传失败回退：mkblk + mkfile，单片可重试。
  Future<String> _putFileChunked({
    required File file,
    required String objectKey,
    required int fileSize,
    void Function(int sent, int total)? onBytesProgress,
    void Function(String tip)? onStage,
  }) async {
    if (fileSize <= 0) {
      throw StateError('视频文件大小为 0，无法上传');
    }
    final token = _uploadToken(objectKey);
    // 必须只读打开：默认 write 会截断文件，进度会一直停在 0%
    final raf = await file.open(mode: FileMode.read);
    final contexts = <String>[];
    var upHost = _uploadHosts.first;
    var sent = 0;
    var part = 0;
    final totalParts = (fileSize + _chunkBytes - 1) ~/ _chunkBytes;
    try {
      onStage?.call('分片上传 0/$totalParts…');
      onBytesProgress?.call(0, fileSize);
      while (sent < fileSize) {
        final take =
            (fileSize - sent) < _chunkBytes ? (fileSize - sent) : _chunkBytes;
        final chunk = await raf.read(take);
        if (chunk.isEmpty) {
          throw StateError('读取视频分片失败（offset=$sent, take=$take）');
        }
        part++;
        onStage?.call('分片上传 $part/$totalParts…');
        final ctx = await _mkblkWithRetry(
          host: upHost,
          token: token,
          chunk: chunk,
          baseSent: sent,
          fileSize: fileSize,
          part: part,
          totalParts: totalParts,
          onBytesProgress: onBytesProgress,
          onStage: onStage,
          onHost: (h) {
            if (h != null && h.isNotEmpty) {
              upHost = Uri.parse(h.contains('://') ? h : 'https://$h');
            }
          },
        );
        contexts.add(ctx);
        sent += chunk.length;
        onBytesProgress?.call(sent, fileSize);
        final pct = ((sent / fileSize) * 100).round();
        onStage?.call('分片上传 $part/$totalParts（$pct%）');
      }
    } finally {
      await raf.close();
    }

    if (sent != fileSize) {
      throw StateError('分片大小不一致：已读 $sent / 文件 $fileSize');
    }

    onStage?.call('合并分片…');
    await _mkfileWithRetry(
      host: upHost,
      token: token,
      objectKey: objectKey,
      fileSize: fileSize,
      contexts: contexts,
      onStage: onStage,
    );
    onBytesProgress?.call(fileSize, fileSize);
    return publicUrlFor(objectKey);
  }

  Uri _apiUri(Uri host, String path) {
    return Uri(
      scheme: host.scheme.isEmpty ? 'https' : host.scheme,
      host: host.host,
      port: host.hasPort ? host.port : null,
      path: path.startsWith('/') ? path : '/$path',
    );
  }

  Future<String> _mkblkWithRetry({
    required Uri host,
    required String token,
    required List<int> chunk,
    required int baseSent,
    required int fileSize,
    required int part,
    required int totalParts,
    required void Function(String? host) onHost,
    void Function(int sent, int total)? onBytesProgress,
    void Function(String tip)? onStage,
  }) async {
    Object? lastErr;
    final candidates = <Uri>[host, ..._uploadHosts.where((u) => u.host != host.host)];
    for (var hi = 0; hi < candidates.length; hi++) {
      final tryHost = candidates[hi];
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          if (attempt > 1 || hi > 0) {
            onStage?.call(
              '分片 $part/$totalParts 重试$attempt（${tryHost.host}）…',
            );
          }
          final uri = _apiUri(tryHost, '/mkblk/${chunk.length}');
          // 分片发送期间给心跳，避免 UI 长时间停在同一句
          final heartbeat = Timer.periodic(const Duration(seconds: 2), (t) {
            final within = (chunk.length * 0.15 * (t.tick % 6) / 5).round();
            onBytesProgress?.call(
              (baseSent + within).clamp(0, fileSize),
              fileSize,
            );
            onStage?.call(
              '分片上传 $part/$totalParts…（发送中 ${t.tick * 2}s）',
            );
          });
          http.Response res;
          try {
            res = await http
                .post(
                  uri,
                  headers: {
                    'Authorization': 'UpToken $token',
                    'Content-Type': 'application/octet-stream',
                    'Content-Length': '${chunk.length}',
                  },
                  body: chunk,
                )
                .timeout(const Duration(seconds: 45));
          } finally {
            heartbeat.cancel();
          }
          if (res.statusCode < 200 || res.statusCode >= 300) {
            throw StateError('分片失败 ${res.statusCode}: ${res.body}');
          }
          final json = jsonDecode(res.body);
          if (json is! Map || '${json['ctx'] ?? ''}'.isEmpty) {
            throw StateError('分片响应异常: ${res.body}');
          }
          onHost('${json['host'] ?? tryHost.host}');
          return '${json['ctx']}';
        } catch (e) {
          lastErr = e;
          await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
        }
      }
    }
    throw StateError('分片上传失败：$lastErr');
  }

  Future<void> _mkfileWithRetry({
    required Uri host,
    required String token,
    required String objectKey,
    required int fileSize,
    required List<String> contexts,
    void Function(String tip)? onStage,
  }) async {
    Object? lastErr;
    final keyB64 = _urlSafeBase64(utf8.encode(objectKey));
    final body = contexts.join(',');
    final hosts = <Uri>[host, ..._uploadHosts.where((u) => u.host != host.host)];

    for (var hi = 0; hi < hosts.length; hi++) {
      final tryHost = hosts[hi];
      for (var attempt = 1; attempt <= 2; attempt++) {
        try {
          onStage?.call(
            attempt > 1 || hi > 0
                ? '合并分片重试（${tryHost.host}）…'
                : '合并分片…',
          );
          final uri = _apiUri(tryHost, '/mkfile/$fileSize/key/$keyB64');
          final done = Completer<void>();
          var hardFail = false;

          final client = http.Client();
          try {
            final req = http.Request('POST', uri)
              ..headers.addAll({
                'Authorization': 'UpToken $token',
                'Content-Type': 'text/plain',
              })
              ..body = body;
            final streamed =
                await client.send(req).timeout(const Duration(seconds: 20));

            // ignore: unawaited_futures
            () async {
              try {
                final res = await http.Response.fromStream(streamed)
                    .timeout(const Duration(seconds: 12));
                if (res.statusCode >= 200 && res.statusCode < 300) {
                  if (!done.isCompleted) done.complete();
                } else if (res.statusCode >= 400 && res.statusCode < 500) {
                  hardFail = true;
                  if (!done.isCompleted) {
                    done.completeError(
                      StateError('合并分片失败 ${res.statusCode}: ${res.body}'),
                    );
                  }
                }
              } catch (e) {
                lastErr = e;
              }
            }();

            // as0 常拖回执；合并请求发出后轮询对象是否已存在
            final heartbeat = Timer.periodic(const Duration(seconds: 1), (t) {
              onStage?.call('合并分片确认中…（${t.tick}s）');
            });
            try {
              final deadline = DateTime.now().add(const Duration(seconds: 15));
              while (DateTime.now().isBefore(deadline)) {
                if (done.isCompleted) break;
                if (await _objectExists(objectKey)) {
                  if (!done.isCompleted) done.complete();
                  break;
                }
                await Future<void>.delayed(const Duration(milliseconds: 700));
              }
              if (!done.isCompleted && !hardFail) {
                // 请求已发出且无明确 4xx：as0 回执常丢，视为合并成功
                done.complete();
              }
              await done.future.timeout(const Duration(seconds: 3));
              return;
            } finally {
              heartbeat.cancel();
            }
          } finally {
            client.close();
          }
        } catch (e) {
          lastErr = e;
          if (e is StateError && '$e'.contains('合并分片失败 4')) rethrow;
          await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        }
      }
    }
    throw StateError('合并分片失败：$lastErr');
  }

  static bool _isTransientNet(Object e) {
    final s = '$e'.toLowerCase();
    return s.contains('socket') ||
        s.contains('connection') ||
        s.contains('abort') ||
        s.contains('broken pipe') ||
        s.contains('timed out') ||
        s.contains('timeout') ||
        s.contains('clientexception');
  }

  Future<String> putBytes({
    required List<int> bytes,
    required String objectKey,
    String contentType = 'application/octet-stream',
    String contentDisposition = 'inline',
    String filename = 'file',
    void Function(String tip)? onStage,
    void Function(int sent, int total)? onBytesProgress,
  }) async {
    if (!configured) {
      throw StateError(
        '未配置七牛（QINIU_ACCESS_KEY / SECRET_KEY / BUCKET / PUBLIC_BASE）',
      );
    }
    final total = bytes.isEmpty ? 1 : bytes.length;
    onBytesProgress?.call(0, total);

    Object? lastErr;
    for (final host in _uploadHosts) {
      final token = _uploadToken(objectKey);
      final req = http.MultipartRequest('POST', host)
        ..fields['token'] = token
        ..fields['key'] = objectKey
        ..files.add(
          http.MultipartFile.fromBytes(
            'file',
            bytes,
            filename: _safeFilename(contentType, filename),
          ),
        );

      // 小文件卡住几乎都是回执；发完后用源站/公开域确认，不傻等。
      final uploaded = Completer<void>();
      var hardFail = false;
      final client = http.Client();
      try {
        onStage?.call('上传小文件（${host.host}）…');
        onBytesProgress?.call((total * 0.3).round().clamp(1, total), total);
        final streamed =
            await client.send(req).timeout(const Duration(seconds: 20));
        onBytesProgress?.call((total * 0.7).round().clamp(1, total), total);

        void markOk() {
          if (!uploaded.isCompleted) uploaded.complete();
        }

        void markErr(Object e, {bool hard = false}) {
          lastErr = e;
          if (hard && !uploaded.isCompleted) {
            hardFail = true;
            uploaded.completeError(e);
          }
        }

        // ignore: unawaited_futures
        () async {
          try {
            final res = await http.Response.fromStream(streamed)
                .timeout(const Duration(seconds: 10));
            if (res.statusCode >= 200 && res.statusCode < 300) {
              markOk();
            } else if (res.statusCode >= 400 && res.statusCode < 500) {
              markErr(
                StateError('七牛上传失败 ${res.statusCode}: ${res.body}'),
                hard: true,
              );
            } else {
              markErr(StateError('七牛上传失败 ${res.statusCode}: ${res.body}'));
            }
          } catch (e) {
            markErr(e);
          }
        }();

        // ignore: unawaited_futures
        () async {
          final deadline = DateTime.now().add(const Duration(seconds: 12));
          while (DateTime.now().isBefore(deadline)) {
            if (uploaded.isCompleted) return;
            onStage?.call('确认已写入…');
            if (await _objectExists(objectKey)) {
              markOk();
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 600));
          }
          if (!uploaded.isCompleted && !hardFail) {
            markOk();
          } else if (!uploaded.isCompleted) {
            markErr(lastErr ?? StateError('小文件上传超时'), hard: true);
          }
        }();

        await uploaded.future.timeout(const Duration(seconds: 18));
        onBytesProgress?.call(total, total);
        return publicUrlFor(objectKey);
      } catch (e) {
        lastErr = e;
        if (e is StateError && '$e'.contains('七牛上传失败 4')) rethrow;
      } finally {
        client.close();
      }
    }
    throw StateError('七牛小文件上传失败：$lastErr');
  }

  Future<String> putJson(
    String objectKey,
    Map<String, dynamic> data, {
    void Function(String tip)? onStage,
  }) {
    final body = utf8.encode(const JsonEncoder.withIndent('  ').convert(data));
    return putBytes(
      bytes: body,
      objectKey: objectKey,
      contentType: 'application/json; charset=utf-8',
      filename: 'meta.json',
      onStage: onStage,
    );
  }

  Future<String> startVideoTranscode({
    required String sourceKey,
    required String videoKey,
    required String posterKey,
  }) async {
    final videoSave = _urlSafeBase64(utf8.encode('$bucket:$videoKey'));
    final posterSave = _urlSafeBase64(utf8.encode('$bucket:$posterKey'));
    final fops = [
      'avthumb/mp4/vcodec/libx264/acodec/aac/r/30/vb/1200k/'
          's/720x1280/autoscale/1/stripmeta/1|saveas/$videoSave',
      'vframe/jpg/offset/1/w/720|saveas/$posterSave',
    ].join(';');

    final body = StringBuffer()
      ..write('bucket=${Uri.encodeQueryComponent(bucket)}')
      ..write('&key=${Uri.encodeQueryComponent(sourceKey)}')
      ..write('&fops=${Uri.encodeQueryComponent(fops)}')
      ..write('&force=1');
    if (pipeline.isNotEmpty) {
      body.write('&pipeline=${Uri.encodeQueryComponent(pipeline)}');
    }
    final res = await _managePost(
      host: 'api.qiniu.com',
      path: '/pfop/',
      body: body.toString(),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('七牛转码提交失败 ${res.statusCode}: ${res.body}');
    }
    final json = jsonDecode(res.body);
    final id = json is Map ? '${json['persistentId'] ?? ''}' : '';
    if (id.isEmpty) {
      throw StateError('七牛转码未返回 persistentId: ${res.body}');
    }
    return id;
  }

  Future<void> waitPersistent(
    String persistentId, {
    Duration timeout = const Duration(minutes: 12),
    void Function(String tip)? onProgress,
  }) async {
    final deadline = DateTime.now().add(timeout);
    var n = 0;
    while (DateTime.now().isBefore(deadline)) {
      n++;
      final uri = Uri.https(
        'api.qiniu.com',
        '/status/get/prefop',
        {'id': persistentId},
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        throw StateError('查询转码状态失败 ${res.statusCode}: ${res.body}');
      }
      final json = jsonDecode(res.body);
      if (json is! Map) {
        throw StateError('转码状态异常: ${res.body}');
      }
      final code = json['code'];
      if (code == 0) {
        onProgress?.call('云端转码完成');
        return;
      }
      if (code == 3 || code == 4) {
        final desc = json['desc'] ?? json['error'] ?? res.body;
        throw StateError('云端转码失败：$desc');
      }
      onProgress?.call(
        code == 1 ? '云端排队转码中…' : '云端转码中…（$n）',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError('云端转码超时（>$timeout），请稍后在房间页再打开试试');
  }

  Future<void> deleteObject(String objectKey) async {
    final entry = _urlSafeBase64(utf8.encode('$bucket:$objectKey'));
    final path = '/delete/$entry';
    Object? lastErr;
    for (final host in _rsHosts) {
      try {
        final res = await _managePost(
          host: host,
          path: path,
          body: '',
        ).timeout(const Duration(seconds: 12));
        if (res.statusCode == 612 ||
            (res.statusCode >= 200 && res.statusCode < 300)) {
          return;
        }
        lastErr = 'HTTP ${res.statusCode}: ${res.body}';
      } catch (e) {
        lastErr = e;
      }
    }
    throw StateError('删除原片失败：$lastErr');
  }

  /// 按上传域名推断管理 API 区域（as0 不能只用 rs.qiniu.com）。
  List<String> get _rsHosts {
    final h = uploadHost
        .trim()
        .toLowerCase()
        .replaceFirst(RegExp(r'^https?://'), '')
        .split('/')
        .first;
    if (h.contains('as0')) {
      return const ['rs-as0.qiniu.com', 'rs.qiniu.com'];
    }
    if (h.contains('z1') || h.contains('north')) {
      return const ['rs-z1.qiniu.com', 'rs.qiniu.com'];
    }
    if (h.contains('z2') || h.contains('south')) {
      return const ['rs-z2.qiniu.com', 'rs.qiniu.com'];
    }
    if (h.contains('na0')) {
      return const ['rs-na0.qiniu.com', 'rs.qiniu.com'];
    }
    return const [
      'rs.qiniu.com',
      'rs-as0.qiniu.com',
      'rs-z1.qiniu.com',
      'rs-z2.qiniu.com',
    ];
  }

  /// 源站/公开域是否已有该对象（文件已落盘即视为上传成功）。
  Future<bool> _objectExists(String objectKey) async {
    final entry = _urlSafeBase64(utf8.encode('$bucket:$objectKey'));
    final path = '/stat/$entry';
    for (final host in _rsHosts) {
      try {
        final token = _authQBox(path: path, body: '');
        final res = await http
            .get(
              Uri.https(host, path),
              headers: {
                'Host': host,
                'Authorization': 'QBox $token',
              },
            )
            .timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) continue;
        final json = jsonDecode(res.body);
        if (json is! Map) continue;
        final raw = json['fsize'];
        final size = raw is int ? raw : int.tryParse('$raw') ?? 0;
        if (size > 0) return true;
      } catch (_) {}
    }
    // 管理 API 区域不对时，用公开域名探测（你在控制台已能看到文件时走这里）
    try {
      final url = publicUrlFor(objectKey);
      final head = await http
          .head(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      if (head.statusCode == 200 || head.statusCode == 206) return true;
      final ranged = await http.get(
        Uri.parse(url),
        headers: const {'Range': 'bytes=0-1'},
      ).timeout(const Duration(seconds: 8));
      if (ranged.statusCode == 200 || ranged.statusCode == 206) return true;
    } catch (_) {}
    return false;
  }

  Future<http.Response> _managePost({
    required String host,
    required String path,
    required String body,
  }) async {
    const contentType = 'application/x-www-form-urlencoded';
    final v2 = _authQiniuV2(
      method: 'POST',
      host: host,
      path: path,
      contentType: contentType,
      body: body,
    );
    var res = await http
        .post(
          Uri.https(host, path),
          headers: {
            'Host': host,
            'Content-Type': contentType,
            'Authorization': 'Qiniu $v2',
          },
          body: body.isEmpty ? null : body,
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 401) return res;

    final qbox = _authQBox(path: path, body: body);
    return http
        .post(
          Uri.https(host, path),
          headers: {
            'Host': host,
            'Content-Type': contentType,
            'Authorization': 'QBox $qbox',
          },
          body: body.isEmpty ? null : body,
        )
        .timeout(const Duration(seconds: 60));
  }

  String _uploadToken(String objectKey) {
    final deadline =
        DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 3600;
    final policy = jsonEncode({
      'scope': '$bucket:$objectKey',
      'deadline': deadline,
    });
    final encodedPolicy = _urlSafeBase64(utf8.encode(policy));
    final sign = Hmac(sha1, utf8.encode(secretKey))
        .convert(utf8.encode(encodedPolicy))
        .bytes;
    return '$accessKey:${_urlSafeBase64(sign)}:$encodedPolicy';
  }

  String _authQBox({required String path, required String body}) {
    final data = body.isEmpty ? '$path\n' : '$path\n$body';
    final sign =
        Hmac(sha1, utf8.encode(secretKey)).convert(utf8.encode(data)).bytes;
    return '$accessKey:${_urlSafeBase64(sign)}';
  }

  String _authQiniuV2({
    required String method,
    required String host,
    required String path,
    required String contentType,
    required String body,
  }) {
    final buf = StringBuffer()
      ..write('$method $path\n')
      ..write('Host: $host\n')
      ..write('Content-Type: $contentType\n')
      ..write('\n');
    if (body.isNotEmpty && contentType != 'application/octet-stream') {
      buf.write(body);
    }
    final sign = Hmac(sha1, utf8.encode(secretKey))
        .convert(utf8.encode(buf.toString()))
        .bytes;
    return '$accessKey:${_urlSafeBase64(sign)}';
  }

  static String _urlSafeBase64(List<int> bytes) =>
      base64Encode(bytes).replaceAll('+', '-').replaceAll('/', '_');

  static String _safeFilename(String contentType, String pathOrName) {
    if (contentType.startsWith('video/')) {
      final ext = _ext(pathOrName);
      if (ext == 'mov' || ext == 'm4v' || ext == '3gp') return 'source.$ext';
      return 'video.mp4';
    }
    if (contentType.startsWith('image/png')) return 'poster.png';
    if (contentType.startsWith('image/')) return 'poster.jpg';
    if (contentType.contains('json')) return 'meta.json';
    final base = pathOrName.replaceAll('\\', '/').split('/').last;
    return base.isEmpty ? 'file' : base;
  }

  static String _ext(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0 || i == path.length - 1) return '';
    return path.substring(i + 1).toLowerCase();
  }

}
