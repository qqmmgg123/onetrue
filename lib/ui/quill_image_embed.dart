import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;

import '../media/qiniu_uploader.dart';

/// 正文插图：Quill `image` embed → 网络图。
class NetworkImageEmbedBuilder extends quill.EmbedBuilder {
  @override
  String get key => quill.BlockEmbed.imageType;

  @override
  Widget build(
    BuildContext context,
    quill.QuillController controller,
    quill.Embed node,
    bool readOnly,
    bool inline,
    TextStyle textStyle,
  ) {
    final raw = '${node.value.data}'.trim();
    if (raw.isEmpty) {
      return const SizedBox.shrink();
    }
    final src = QiniuUploader.playableUrl(raw);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          src,
          fit: BoxFit.contain,
          width: double.infinity,
          errorBuilder: (_, __, ___) => Container(
            height: 120,
            alignment: Alignment.center,
            color: const Color(0xFFF0F0F0),
            child: const Text(
              '图片加载失败',
              style: TextStyle(color: Color(0xFF888888)),
            ),
          ),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Container(
              height: 120,
              alignment: Alignment.center,
              color: const Color(0xFFF5F5F5),
              child: const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          },
        ),
      ),
    );
  }
}

List<quill.EmbedBuilder> get kNoteEmbedBuilders => [NetworkImageEmbedBuilder()];
