import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr/qr.dart';

import '../media/qiniu_uploader.dart';

/// 房间视频分享海报（方案1）：封面缩略图 + 标题/描述 + 二维码。
/// 分享出去的是一张图，微信里长按识别二维码打开网页，无需开放平台 AppID。
class RoomSharePoster {
  RoomSharePoster._();

  static const double width = 1080;
  static const double height = 1680;

  static Future<File> build({
    required String shareUrl,
    required String title,
    required String description,
    String? posterUrl,
    String brand = '缘初 · 房间实拍',
  }) async {
    final coverBytes = await _downloadPosterBytes(posterUrl);
    final cover = coverBytes == null
        ? null
        : await _decodeUiImage(coverBytes);
    final qrUi = await _decodeUiImage(_qrPngBytes(shareUrl));

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = const Size(width, height);

    // 背景
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFF5F2EC),
    );

    // 封面区
    const coverH = 980.0;
    final coverRect = const Rect.fromLTWH(0, 0, width, coverH);
    if (cover != null) {
      _paintCover(canvas, cover, coverRect);
    } else {
      final shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF3A3F4A), Color(0xFF6B5E4E), Color(0xFF2C3038)],
      ).createShader(coverRect);
      canvas.drawRect(coverRect, Paint()..shader = shader);
      _paintText(
        canvas,
        'ROOM',
        rect: const Rect.fromLTWH(0, 420, width, 60),
        style: const TextStyle(
          color: Color(0x66FFFFFF),
          fontSize: 42,
          fontWeight: FontWeight.w300,
          letterSpacing: 16,
        ),
        align: TextAlign.center,
      );
    }

    // 封面底部暗角
    canvas.drawRect(
      coverRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withOpacity(0.55),
          ],
          stops: const [0.55, 1.0],
        ).createShader(coverRect),
    );

    // 信息卡片
    const cardLeft = 44.0;
    const cardTop = coverH - 48;
    const cardRight = width - 44;
    const cardBottom = height - 88;
    final cardRRect = RRect.fromRectAndRadius(
      const Rect.fromLTRB(cardLeft, cardTop, cardRight, cardBottom),
      const Radius.circular(32),
    );
    canvas.drawRRect(
      cardRRect,
      Paint()
        ..color = Colors.white
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.5),
    );
    canvas.drawRRect(
      cardRRect,
      Paint()
        ..color = const Color(0xFFE8E2D8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final safeTitle = title.trim().isEmpty ? '房间实拍视频' : title.trim();
    final safeDesc = description.trim();

    // 左侧文案
    const textLeft = cardLeft + 44;
    const textTop = cardTop + 48;
    const textMaxW = width - 44 - 44 - 44 - 280;
    _paintText(
      canvas,
      safeTitle,
      rect: Rect.fromLTWH(textLeft, textTop, textMaxW, 120),
      style: const TextStyle(
        color: Color(0xFF1C1C1C),
        fontSize: 44,
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
      maxLines: 2,
    );
    if (safeDesc.isNotEmpty) {
      _paintText(
        canvas,
        safeDesc,
        rect: const Rect.fromLTWH(textLeft, textTop + 128, textMaxW, 160),
        style: const TextStyle(
          color: Color(0xFF666666),
          fontSize: 28,
          height: 1.4,
          fontWeight: FontWeight.w400,
        ),
        maxLines: 4,
      );
    }

    // 右侧二维码
    const qrBox = 268.0;
    const qrLeft = cardRight - 44 - qrBox;
    const qrTop = cardTop + 48;
    final qrRRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(qrLeft, qrTop, qrBox, qrBox),
      const Radius.circular(20),
    );
    canvas.drawRRect(qrRRect, Paint()..color = const Color(0xFFFAFAF8));
    canvas.drawRRect(
      qrRRect,
      Paint()
        ..color = const Color(0xFFE8E2D8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    const qrPad = 18.0;
    canvas.drawImageRect(
      qrUi,
      Rect.fromLTWH(0, 0, qrUi.width.toDouble(), qrUi.height.toDouble()),
      const Rect.fromLTWH(
        qrLeft + qrPad,
        qrTop + qrPad,
        qrBox - qrPad * 2,
        qrBox - qrPad * 2,
      ),
      Paint()..filterQuality = FilterQuality.high,
    );

    // 提示
    _paintText(
      canvas,
      '微信内长按图片 · 识别二维码查看实拍视频',
      rect: const Rect.fromLTWH(
        textLeft,
        qrTop + qrBox + 36,
        cardRight - cardLeft - 88,
        40,
      ),
      style: const TextStyle(
        color: Color(0xFF8A7F72),
        fontSize: 26,
        fontWeight: FontWeight.w500,
      ),
    );

    // 品牌
    _paintText(
      canvas,
      brand,
      rect: const Rect.fromLTWH(0, height - 64, width, 36),
      style: const TextStyle(
        color: Color(0xFFA3988C),
        fontSize: 24,
        letterSpacing: 1.2,
      ),
      align: TextAlign.center,
    );

    final picture = recorder.endRecording();
    final uiImage = await picture.toImage(width.toInt(), height.toInt());
    final byteData =
        await uiImage.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw StateError('海报生成失败');
    }

    final dir = await getTemporaryDirectory();
    final out = File(
      p.join(
        dir.path,
        'room_share_poster_${DateTime.now().millisecondsSinceEpoch}.jpg',
      ),
    );
    // 转 JPEG 体积更小，微信分享更友好
    final pngBytes = byteData.buffer.asUint8List();
    final decoded = img.decodeImage(pngBytes);
    if (decoded == null) {
      await out.writeAsBytes(pngBytes, flush: true);
      return out;
    }
    final jpg = img.encodeJpg(decoded, quality: 92);
    final jpgFile = File(out.path.replaceAll('.jpg', '') + '.jpg');
    await jpgFile.writeAsBytes(jpg, flush: true);
    return jpgFile;
  }

  static void _paintCover(Canvas canvas, ui.Image cover, Rect dst) {
    final src = Rect.fromLTWH(
      0,
      0,
      cover.width.toDouble(),
      cover.height.toDouble(),
    );
    // cover fit：保持比例裁切填满
    final scale = (dst.width / src.width > dst.height / src.height)
        ? dst.width / src.width
        : dst.height / src.height;
    final w = src.width * scale;
    final h = src.height * scale;
    final fitted = Rect.fromCenter(
      center: dst.center,
      width: w,
      height: h,
    );
    canvas.save();
    canvas.clipRect(dst);
    canvas.drawImageRect(
      cover,
      src,
      fitted,
      Paint()..filterQuality = FilterQuality.high,
    );
    canvas.restore();
  }

  static void _paintText(
    Canvas canvas,
    String text, {
    required Rect rect,
    required TextStyle style,
    TextAlign align = TextAlign.left,
    int maxLines = 3,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: rect.width);
    tp.paint(canvas, Offset(rect.left, rect.top));
  }

  static Future<Uint8List?> _downloadPosterBytes(String? url) async {
    final raw = (url ?? '').trim();
    if (raw.isEmpty) return null;
    try {
      final playable = QiniuUploader.playableUrl(raw);
      final res = await http
          .get(Uri.parse(playable))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      if (res.bodyBytes.isEmpty) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Image> _decodeUiImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  static Uint8List _qrPngBytes(String data) {
    final qrCode = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final qrImage = QrImage(qrCode);
    final n = qrImage.moduleCount;
    const module = 10;
    final size = n * module;
    final out = img.Image(width: size, height: size);
    img.fill(out, color: img.ColorRgb8(255, 255, 255));
    final black = img.ColorRgb8(22, 22, 22);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (!qrImage.isDark(y, x)) continue;
        for (var dy = 0; dy < module; dy++) {
          for (var dx = 0; dx < module; dx++) {
            out.setPixel(x * module + dx, y * module + dy, black);
          }
        }
      }
    }
    return Uint8List.fromList(img.encodePng(out));
  }
}
