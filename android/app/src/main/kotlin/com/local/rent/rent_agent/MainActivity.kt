package com.local.rent.rent_agent

import android.app.KeyguardManager
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import me.leolin.shortcutbadger.ShortcutBadger

class MainActivity : FlutterActivity() {
    private val channelName = "rent_agent/recorder"
    private val badgeChannelName = "rent_agent/badge"
    private var recorder: MediaRecorder? = null
    private var currentPath: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // 全屏闹钟意图：锁屏上也能亮屏展示
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val keyguard = getSystemService(KEYGUARD_SERVICE) as? KeyguardManager
            keyguard?.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD,
            )
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(VoskAsrPlugin())
        flutterEngine.plugins.add(VideoProbePlugin())
        flutterEngine.plugins.add(VideoTranscodePlugin())
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, badgeChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "set" -> {
                        val count = call.argument<Int>("count") ?: 0
                        try {
                            val ok = ShortcutBadger.applyCount(applicationContext, count.coerceAtLeast(0))
                            result.success(ok)
                        } catch (e: Exception) {
                            result.error("badge_set", e.message, null)
                        }
                    }
                    "clear" -> {
                        try {
                            val ok = ShortcutBadger.removeCount(applicationContext)
                            result.success(ok)
                        } catch (e: Exception) {
                            result.error("badge_clear", e.message, null)
                        }
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
