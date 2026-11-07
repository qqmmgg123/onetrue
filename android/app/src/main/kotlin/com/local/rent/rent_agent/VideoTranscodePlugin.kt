package com.local.rent.rent_agent

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 系统 Media3 Transformer：HEVC → H.264（强制 AVC），比 video_compress 更稳。
 */
class VideoTranscodePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var appContext: Context? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var transformer: Transformer? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val busy = AtomicBoolean(false)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "rent_agent/video_transcode")
        methodChannel?.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "rent_agent/video_transcode_progress")
        eventChannel?.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cancelInternal()
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
        appContext = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "thumbnail" -> {
                val path = call.argument<String>("path")
                val out = call.argument<String>("out")
                if (path.isNullOrBlank() || out.isNullOrBlank()) {
                    result.error("bad_args", "path/out required", null)
                    return
                }
                try {
                    result.success(makeThumbnail(path, out))
                } catch (e: Exception) {
                    result.error("thumb_failed", e.message, null)
                }
            }
            "transcodeAvc" -> {
                val input = call.argument<String>("input")
                val output = call.argument<String>("output")
                val maxHeight = call.argument<Int>("maxHeight") ?: 720
                if (input.isNullOrBlank() || output.isNullOrBlank()) {
                    result.error("bad_args", "input/output required", null)
                    return
                }
                startTranscode(input, output, maxHeight, result)
            }
            "cancel" -> {
                cancelInternal()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun startTranscode(
        input: String,
        output: String,
        maxHeight: Int,
        result: MethodChannel.Result,
    ) {
        val ctx = appContext
        if (ctx == null) {
            result.error("no_context", "plugin not attached", null)
            return
        }
        if (!busy.compareAndSet(false, true)) {
            result.error("busy", "已有转码任务在进行", null)
            return
        }
        try {
            File(output).parentFile?.mkdirs()
            if (File(output).exists()) File(output).delete()

            val mediaItem = MediaItem.fromUri(Uri.fromFile(File(input)))
            val effects = Effects(
                /* audioProcessors = */ emptyList(),
                /* videoEffects = */ listOf(Presentation.createForHeight(maxHeight.coerceIn(360, 1280))),
            )
            val edited = EditedMediaItem.Builder(mediaItem)
                .setEffects(effects)
                .build()

            val answered = AtomicBoolean(false)
            fun finishOk(path: String) {
                if (answered.compareAndSet(false, true)) {
                    busy.set(false)
                    transformer = null
                    mainHandler.post { result.success(path) }
                }
            }
            fun finishErr(code: String, msg: String?) {
                if (answered.compareAndSet(false, true)) {
                    busy.set(false)
                    transformer = null
                    mainHandler.post { result.error(code, msg, null) }
                }
            }

            val t = Transformer.Builder(ctx)
                .setVideoMimeType(MimeTypes.VIDEO_H264)
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
                .addListener(
                    object : Transformer.Listener {
                        override fun onCompleted(
                            composition: Composition,
                            exportResult: ExportResult,
                        ) {
                            emitProgress(100)
                            finishOk(output)
                        }

                        override fun onError(
                            composition: Composition,
                            exportResult: ExportResult,
                            exportException: ExportException,
                        ) {
                            finishErr("transcode_failed", exportException.message)
                        }
                    },
                )
                .build()
            transformer = t

            // 进度轮询（Transformer 无稳定回调时兜底）
            val progressHolder = ProgressHolder()
            val progressTicker = object : Runnable {
                override fun run() {
                    val tr = transformer ?: return
                    if (!busy.get()) return
                    try {
                        val state = tr.getProgress(progressHolder)
                        if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
                            emitProgress(progressHolder.progress)
                        }
                    } catch (_: Exception) {
                    }
                    if (busy.get()) mainHandler.postDelayed(this, 400)
                }
            }
            mainHandler.post(progressTicker)
            emitProgress(0)
            t.start(edited, output)
        } catch (e: Exception) {
            busy.set(false)
            transformer = null
            result.error("transcode_failed", e.message, null)
        }
    }

    private fun emitProgress(percent: Int) {
        mainHandler.post {
            eventSink?.success(percent.coerceIn(0, 100))
        }
    }

    private fun cancelInternal() {
        try {
            transformer?.cancel()
        } catch (_: Exception) {
        }
        transformer = null
        busy.set(false)
    }

    private fun makeThumbnail(path: String, outPath: String): String? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            // 约第 0.5 秒，比 video_compress 的 -1 更稳
            val bmp = retriever.getFrameAtTime(
                500_000,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            ) ?: retriever.frameAtTime ?: return null
            val scaled = scaleMax(bmp, 720)
            File(outPath).parentFile?.mkdirs()
            FileOutputStream(outPath).use { fos ->
                scaled.compress(Bitmap.CompressFormat.JPEG, 80, fos)
            }
            if (scaled !== bmp) scaled.recycle()
            bmp.recycle()
            return outPath
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun scaleMax(src: Bitmap, maxSide: Int): Bitmap {
        val w = src.width
        val h = src.height
        val max = maxOf(w, h)
        if (max <= maxSide) return src
        val scale = maxSide.toFloat() / max
        return Bitmap.createScaledBitmap(
            src,
            (w * scale).toInt().coerceAtLeast(1),
            (h * scale).toInt().coerceAtLeast(1),
            true,
        )
    }
}
