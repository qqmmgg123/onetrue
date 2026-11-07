import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'room_video_page.dart';

/// 房间列表 / 详情右侧的竖向缩略图入口。
class RoomVideoThumb extends StatelessWidget {
  const RoomVideoThumb({
    super.key,
    required this.roomId,
    this.videoUrl = '',
    this.posterUrl = '',
    this.width = 56,
    this.height = 74,
    this.onClosed,
  });

  final int roomId;
  final String videoUrl;
  final String posterUrl;
  final double width;
  final double height;
  final VoidCallback? onClosed;

  bool get hasVideo => videoUrl.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => RoomVideoPage(roomId: roomId),
            ),
          );
          onClosed?.call();
        },
        borderRadius: BorderRadius.circular(8),
        child: Ink(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: hasVideo ? Colors.black87 : scheme.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant),
            image: hasVideo && posterUrl.trim().isNotEmpty
                ? DecorationImage(
                    image: NetworkImage(posterUrl),
                    fit: BoxFit.cover,
                  )
                : null,
          ),
          child: hasVideo
              ? const Center(
                  child: Icon(Icons.play_circle_fill,
                      color: Colors.white70, size: 28),
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.videocam_off_outlined,
                        size: 20, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 2),
                    Text(
                      '无视频',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  static RoomVideoThumb fromRoom(Room room, {VoidCallback? onClosed}) =>
      RoomVideoThumb(
        roomId: room.id,
        videoUrl: room.videoUrl,
        posterUrl: room.videoPosterUrl,
        onClosed: onClosed,
      );
}
