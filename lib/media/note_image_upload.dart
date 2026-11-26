import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'qiniu_uploader.dart';

/// 文章封面 / 正文插图：选图 → 压缩 → 七牛，返回公开 URL。
Future<String?> pickAndUploadNoteImage({
  required String userId,
  required String folder,
  int maxEdge = 1600,
  int jpegQuality = 82,
}) async {
  final uid = userId.trim();
  if (uid.isEmpty) throw StateError('请先登录');
  final picker = ImagePicker();
  final x = await picker.pickImage(
    source: ImageSource.gallery,
    maxWidth: maxEdge.toDouble(),
    maxHeight: maxEdge.toDouble(),
    imageQuality: 92,
  );
  if (x == null) return null;
  final raw = await x.readAsBytes();
  final encoded = _encodeJpeg(raw, maxEdge: maxEdge, quality: jpegQuality);
  final ts = DateTime.now().millisecondsSinceEpoch;
  final key = '$folder/$uid/$ts.jpg';
  final uploader = QiniuUploader();
  if (!uploader.configured) {
    throw StateError('未配置七牛，无法上传图片');
  }
  final url = await uploader.putBytes(
    bytes: encoded,
    objectKey: key,
    contentType: 'image/jpeg',
    filename: 'image.jpg',
  );
  final sep = url.contains('?') ? '&' : '?';
  return '$url${sep}v=$ts';
}

Uint8List _encodeJpeg(
  Uint8List raw, {
  required int maxEdge,
  required int quality,
}) {
  final decoded = img.decodeImage(raw);
  if (decoded == null) return raw;
  var im = decoded;
  final long = im.width > im.height ? im.width : im.height;
  if (long > maxEdge) {
    im = img.copyResize(
      im,
      width: im.width >= im.height ? maxEdge : null,
      height: im.height > im.width ? maxEdge : null,
      interpolation: img.Interpolation.linear,
    );
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: quality));
}
