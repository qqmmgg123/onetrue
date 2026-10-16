package com.local.rent.rent_agent

import android.media.MediaRecorder
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "rent_agent/recorder"
    private var recorder: MediaRecorder? = null
    private var currentPath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "path required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            startRecorder(path)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("start_failed", e.message, null)
                        }
                    }
                    "stop" -> {
                        try {
                            val path = stopRecorder()
                            result.success(path)
                        } catch (e: Exception) {
                            result.error("stop_failed", e.message, null)
                        }
                    }
                    "amplitude" -> {
                        result.success(readAmplitude())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startRecorder(path: String) {
        stopRecorderQuietly()
        currentPath = path
        val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(this)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }
        r.setAudioSource(MediaRecorder.AudioSource.MIC)
        r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        r.setAudioSamplingRate(16000)
        r.setAudioChannels(1)
        r.setAudioEncodingBitRate(64000)
        r.setOutputFile(path)
        r.prepare()
        r.start()
        recorder = r
    }

    private fun stopRecorder(): String? {
        val path = currentPath
        val r = recorder ?: return path
        try {
            r.stop()
        } catch (_: RuntimeException) {
            // 录得太短可能 stop 失败
        }
        try {
            r.release()
        } catch (_: Exception) {
        }
        recorder = null
        currentPath = null
        return path
    }

    private fun stopRecorderQuietly() {
        try {
            stopRecorder()
        } catch (_: Exception) {
        }
    }

    private fun readAmplitude(): Double {
        val r = recorder ?: return 0.0
        return try {
            val amp = r.maxAmplitude // 0..32767
            (amp / 16000.0).coerceIn(0.0, 1.0)
        } catch (_: Exception) {
            0.0
        }
    }

    override fun onDestroy() {
        stopRecorderQuietly()
        super.onDestroy()
    }
}
