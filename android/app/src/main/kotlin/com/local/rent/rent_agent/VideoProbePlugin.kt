package com.local.rent.rent_agent

import android.media.MediaExtractor
import android.media.MediaFormat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 探测本地视频轨编码：已是 H.264(AVC) 则可跳过重编码，避免二次压缩拖很久。
 */
class VideoProbePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "rent_agent/video_probe")
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "probe") {
            result.notImplemented()
            return
        }
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("bad_args", "path required", null)
            return
        }
        try {
            result.success(probe(path))
        } catch (e: Exception) {
            result.error("probe_failed", e.message, null)
        }
    }

    private fun probe(path: String): Map<String, Any?> {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            var videoMime = ""
            var audioMime = ""
            var width = 0
            var height = 0
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/") && videoMime.isEmpty()) {
                    videoMime = mime
                    width = format.getIntegerOrZero(MediaFormat.KEY_WIDTH)
                    height = format.getIntegerOrZero(MediaFormat.KEY_HEIGHT)
                } else if (mime.startsWith("audio/") && audioMime.isEmpty()) {
                    audioMime = mime
                }
            }
            val avc = videoMime == "video/avc"
            val hevc = videoMime == "video/hevc"
            val lower = path.lowercase()
            val mp4Like = lower.endsWith(".mp4") || lower.endsWith(".m4v")
            // 已是 AVC 且 mp4 容器：可直接上传，无需重编
            val skipReencode = avc && mp4Like
            return mapOf(
                "videoMime" to videoMime,
                "audioMime" to audioMime,
                "width" to width,
                "height" to height,
                "isAvc" to avc,
                "isHevc" to hevc,
                "skipReencode" to skipReencode,
            )
        } finally {
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun MediaFormat.getIntegerOrZero(key: String): Int =
        try {
            if (containsKey(key)) getInteger(key) else 0
        } catch (_: Exception) {
            0
        }
}
