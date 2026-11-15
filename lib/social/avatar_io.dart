import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../media/qiniu_uploader.dart';

/// 业界常见头像规范：正方形、约 512px、JPEG ~85、通常 <200KB。
const kAvatarExportSize = 512;
const kAvatarJpegQuality = 85;

/// 选图 → 缩放裁剪 → 压缩 → 七牛；返回带 `?v=` 的公开 URL（破缓存）。
Future<String?> pickCropUploadAvatar({
  required BuildContext context,
  required String userId,
}) async {
  final picker = ImagePicker();
  final x = await picker.pickImage(
    source: ImageSource.gallery,
    maxWidth: 2048,
    maxHeight: 2048,
    imageQuality: 95,
  );
  if (x == null) return null;
  final bytes = await x.readAsBytes();
  if (!context.mounted) return null;

  final cropped = await Navigator.of(context).push<Uint8List>(
    MaterialPageRoute(
      builder: (_) => AvatarCropPage(imageBytes: bytes),
      fullscreenDialog: true,
    ),
  );
  if (cropped == null || cropped.isEmpty) return null;

  final encoded = _encodeAvatarJpeg(cropped);
  final ts = DateTime.now().millisecondsSinceEpoch;
  final key = 'avatars/$userId/$ts.jpg';
  final uploader = QiniuUploader();
  final url = await uploader.putBytes(
    bytes: encoded,
    objectKey: key,
    contentType: 'image/jpeg',
    filename: 'avatar.jpg',
  );
  final sep = url.contains('?') ? '&' : '?';
  return '$url${sep}v=$ts';
}

Uint8List _encodeAvatarJpeg(Uint8List raw) {
  final decoded = img.decodeImage(raw);
  if (decoded == null) return raw;
  var im = decoded;
  final side = im.width < im.height ? im.width : im.height;
  final x = ((im.width - side) / 2).round();
  final y = ((im.height - side) / 2).round();
  im = img.copyCrop(im, x: x, y: y, width: side, height: side);
  if (im.width != kAvatarExportSize) {
    im = img.copyResize(
      im,
      width: kAvatarExportSize,
      height: kAvatarExportSize,
      interpolation: img.Interpolation.linear,
    );
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: kAvatarJpegQuality));
}

class AvatarCropPage extends StatefulWidget {
  const AvatarCropPage({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<AvatarCropPage> createState() => _AvatarCropPageState();
}

class _AvatarCropPageState extends State<AvatarCropPage> {
  final _boundaryKey = GlobalKey();
  bool _busy = false;

  Future<void> _confirm() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      final boundary =
          _boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('裁剪区域不可用');
      final shot = await boundary.toImage(pixelRatio: 2);
      final bd = await shot.toByteData(format: ui.ImageByteFormat.png);
      shot.dispose();
      if (bd == null) throw StateError('截取失败');
      final png = bd.buffer.asUint8List();
      final decoded = img.decodeImage(png);
      if (decoded == null) throw StateError('解码失败');
      // 截的是整屏预览区，取中心正方形（与遮罩一致）
      final side =
          decoded.width < decoded.height ? decoded.width : decoded.height;
      final x = ((decoded.width - side) / 2).round();
      final y = ((decoded.height - side) / 2).round();
      final cropped = img.copyCrop(
        decoded,
        x: x,
        y: y,
        width: side,
        height: side,
      );
      final out = Uint8List.fromList(img.encodePng(cropped));
      if (!mounted) return;
      Navigator.pop(context, out);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('裁剪失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('裁剪头像'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _confirm,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('完成', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  key: _boundaryKey,
                  child: InteractiveViewer(
                    minScale: 1,
                    maxScale: 4,
                    child: Center(
                      child: Image.memory(
                        widget.imageBytes,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
                IgnorePointer(
                  child: CustomPaint(
                    painter: _CropMaskPainter(),
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Text(
              '双指缩放、拖动。导出为正方形 JPEG（512px）。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _CropMaskPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * 0.78;
    final crop = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: side,
      height: side,
    );
    final overlay = Path()..addRect(Offset.zero & size);
    final hole = Path()..addRRect(RRect.fromRectXY(crop, 8, 8));
    canvas.drawPath(
      Path.combine(PathOperation.difference, overlay, hole),
      Paint()..color = Colors.black54,
    );
    canvas.drawRRect(
      RRect.fromRectXY(crop, 8, 8),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
