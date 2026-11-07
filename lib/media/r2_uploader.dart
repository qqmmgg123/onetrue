import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../config/baked_env.dart';

/// Cloudflare R2（S3 兼容）上传。凭证来自 env.local 打包注入。
class R2Uploader {
  R2Uploader({
    String? accountId,
    String? accessKeyId,
    String? secretAccessKey,
    String? bucket,
    String? publicBase,
  })  : accountId = (accountId ?? BakedEnv.r2AccountId).trim(),
        accessKeyId = (accessKeyId ?? BakedEnv.r2AccessKeyId).trim(),
        secretAccessKey = (secretAccessKey ?? BakedEnv.r2SecretAccessKey).trim(),
        bucket = (bucket ?? BakedEnv.r2Bucket).trim(),
        publicBase = (publicBase ?? BakedEnv.r2PublicBase)
            .trim()
            .replaceAll(RegExp(r'/+$'), '');

  final String accountId;
  final String accessKeyId;
  final String secretAccessKey;
  final String bucket;
  final String publicBase;

  String get name => 'Cloudflare R2';

  bool get configured =>
      accountId.isNotEmpty &&
      accessKeyId.isNotEmpty &&
      secretAccessKey.isNotEmpty &&
      bucket.isNotEmpty &&
      publicBase.isNotEmpty;

  String publicUrlFor(String objectKey) => '$publicBase/$objectKey';

  Future<String> putFile({
    required File file,
    required String objectKey,
    String contentType = 'video/mp4',
    String contentDisposition = 'inline',
    void Function(int sent, int total)? onBytesProgress,
  }) async {
    final len = await file.length();
    onBytesProgress?.call(0, len);
    final bytes = await file.readAsBytes();
    onBytesProgress?.call(bytes.length ~/ 2, bytes.length);
    final url = await putBytes(
      bytes: bytes,
      objectKey: objectKey,
      contentType: contentType,
      contentDisposition: contentDisposition,
    );
    onBytesProgress?.call(bytes.length, bytes.length);
    return url;
  }

  Future<String> putBytes({
    required List<int> bytes,
    required String objectKey,
    String contentType = 'application/octet-stream',
    String contentDisposition = 'inline',
  }) async {
    if (!configured) {
      throw StateError(
        '未配置 Cloudflare R2（R2_ACCOUNT_ID / ACCESS_KEY / SECRET / BUCKET / PUBLIC_BASE）',
      );
    }
    final host = '$accountId.r2.cloudflarestorage.com';
    final uri = Uri.https(host, '/$bucket/$objectKey');
    final now = DateTime.now().toUtc();
    final amzDate = _fmtAmz(now);
    final dateStamp = _fmtDate(now);
    final payloadHash = sha256.convert(bytes).toString();
    const region = 'auto';
    const service = 's3';
    final canonicalUri = '/$bucket/$objectKey';
    // 头名必须小写且按字母序，与 SignedHeaders 一致
    final canonicalHeaders = StringBuffer()
      ..writeln('content-disposition:$contentDisposition')
      ..writeln('content-type:$contentType')
      ..writeln('host:$host')
      ..writeln('x-amz-content-sha256:$payloadHash')
      ..writeln('x-amz-date:$amzDate');
    const signedHeaders =
        'content-disposition;content-type;host;x-amz-content-sha256;x-amz-date';
    final canonicalRequest = [
      'PUT',
      canonicalUri,
      '',
      canonicalHeaders.toString(),
      signedHeaders,
      payloadHash,
    ].join('\n');
    final credentialScope = '$dateStamp/$region/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');
    final signingKey = _signingKey(secretAccessKey, dateStamp, region, service);
    final signature = Hmac(sha256, signingKey)
        .convert(utf8.encode(stringToSign))
        .toString();
    final authorization =
        'AWS4-HMAC-SHA256 Credential=$accessKeyId/$credentialScope, '
        'SignedHeaders=$signedHeaders, Signature=$signature';

    final res = await http
        .put(
          uri,
          headers: {
            'Content-Disposition': contentDisposition,
            'Content-Type': contentType,
            'Host': host,
            'x-amz-content-sha256': payloadHash,
            'x-amz-date': amzDate,
            'Authorization': authorization,
          },
          body: bytes,
        )
        .timeout(const Duration(minutes: 3));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('R2 上传失败 ${res.statusCode}: ${res.body}');
    }

    final publicUrl = publicUrlFor(objectKey);
    await _verifyPublic(publicUrl, expectTypePrefix: contentType.split(';').first);
    return publicUrl;
  }

  /// 上传后立刻用公开域名探一下，避免 App 里才发现 404 / 类型不对。
  Future<void> _verifyPublic(String url, {required String expectTypePrefix}) async {
    try {
      final res = await http
          .head(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      // 部分 CDN 对 HEAD 不友好，再试 Range GET
      final check = res.statusCode == 200 || res.statusCode == 403
          ? res
          : await http.get(
              Uri.parse(url),
              headers: {'Range': 'bytes=0-1'},
            ).timeout(const Duration(seconds: 15));
      if (check.statusCode >= 400 && check.statusCode != 206) {
        throw StateError(
          '公开地址不可访问 HTTP ${check.statusCode}（检查桶是否已开 r2.dev 公共访问）\n$url',
        );
      }
      final ct = (check.headers['content-type'] ?? '').toLowerCase();
      if (expectTypePrefix.startsWith('video/') &&
          ct.isNotEmpty &&
          !ct.contains('video') &&
          !ct.contains('octet-stream')) {
        // octet-stream 也能播，但最好是 video/*
        throw StateError(
          '公开地址 Content-Type=$ct，期望 $expectTypePrefix。请重新上传。\n$url',
        );
      }
    } catch (e) {
      if (e is StateError) rethrow;
      // 网络探测失败不阻断上传结果，播放页会再报
    }
  }

  Future<String> putJson(String objectKey, Map<String, dynamic> data) {
    final body = utf8.encode(const JsonEncoder.withIndent('  ').convert(data));
    return putBytes(
      bytes: body,
      objectKey: objectKey,
      contentType: 'application/json; charset=utf-8',
      contentDisposition: 'inline',
    );
  }

  /// 删除对象；不存在时忽略。
  Future<void> deleteObject(String objectKey) async {
    if (!configured) return;
    final key = objectKey.trim().replaceFirst(RegExp(r'^/+'), '');
    if (key.isEmpty) return;
    final host = '$accountId.r2.cloudflarestorage.com';
    final uri = Uri.https(host, '/$bucket/$key');
    final now = DateTime.now().toUtc();
    final amzDate = _fmtAmz(now);
    final dateStamp = _fmtDate(now);
    const payloadHash =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    const region = 'auto';
    const service = 's3';
    final canonicalUri = '/$bucket/$key';
    final canonicalHeaders = StringBuffer()
      ..writeln('host:$host')
      ..writeln('x-amz-content-sha256:$payloadHash')
      ..writeln('x-amz-date:$amzDate');
    const signedHeaders = 'host;x-amz-content-sha256;x-amz-date';
    final canonicalRequest = [
      'DELETE',
      canonicalUri,
      '',
      canonicalHeaders.toString(),
      signedHeaders,
      payloadHash,
    ].join('\n');
    final credentialScope = '$dateStamp/$region/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');
    final signingKey = _signingKey(secretAccessKey, dateStamp, region, service);
    final signature = Hmac(sha256, signingKey)
        .convert(utf8.encode(stringToSign))
        .toString();
    final authorization =
        'AWS4-HMAC-SHA256 Credential=$accessKeyId/$credentialScope, '
        'SignedHeaders=$signedHeaders, Signature=$signature';
    final res = await http
        .delete(
          uri,
          headers: {
            'Host': host,
            'x-amz-content-sha256': payloadHash,
            'x-amz-date': amzDate,
            'Authorization': authorization,
          },
        )
        .timeout(const Duration(seconds: 8));
    // 204/200 成功；404 本就不存在
    if (res.statusCode == 404 || res.statusCode == 204 || res.statusCode == 200) {
      return;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('R2 删除失败 ${res.statusCode}: ${res.body}');
    }
  }

  static String _fmtAmz(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}T'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  }

  static String _fmtDate(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}';
  }

  static List<int> _hmac(List<int> key, String data) {
    return Hmac(sha256, key).convert(utf8.encode(data)).bytes;
  }

  static List<int> _signingKey(
    String secret,
    String dateStamp,
    String region,
    String service,
  ) {
    final kDate = _hmac(utf8.encode('AWS4$secret'), dateStamp);
    final kRegion = _hmac(kDate, region);
    final kService = _hmac(kRegion, service);
    return _hmac(kService, 'aws4_request');
  }
}
