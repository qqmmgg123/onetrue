import 'package:flutter/material.dart';

import '../../media/qiniu_uploader.dart';

/// 文章封面：规范化七牛测试域 URL，失败时占位。
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.height,
    this.aspectRatio,
    this.borderRadius = 8,
    this.fit = BoxFit.cover,
  });

  final String url;
  final double? height;
  final double? aspectRatio;
  final double borderRadius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final raw = url.trim();
    if (raw.isEmpty) return const SizedBox.shrink();
    final src = QiniuUploader.playableUrl(raw);
    Widget img = Image.network(
      src,
      fit: fit,
      width: double.infinity,
      errorBuilder: (_, __, ___) => Container(
        color: const Color(0xFFF0F0F0),
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image_outlined, color: Color(0xFF999999)),
      ),
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(
          color: const Color(0xFFF5F5F5),
          alignment: Alignment.center,
          child: const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      },
    );
    if (aspectRatio != null) {
      img = AspectRatio(aspectRatio: aspectRatio!, child: img);
    } else if (height != null) {
      img = SizedBox(height: height, width: double.infinity, child: img);
    }
    if (borderRadius > 0) {
      img = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: img,
      );
    }
    return img;
  }
}
