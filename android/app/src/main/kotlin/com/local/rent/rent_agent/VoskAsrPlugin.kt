package com.local.rent.rent_agent

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener
import org.vosk.android.SpeechService
import java.util.concurrent.Executors

/**
 * 离线 Vosk：Dart 负责下载/解压模型，这里只加载并听写麦克风 PCM。
 */
class VoskAsrPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var events: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    private var model: Model? = null
    private var speechService: SpeechService? = null
    private var modelPath: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "rent_agent/vosk")
        methodChannel?.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "rent_agent/vosk_events")
        eventChannel?.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopQuietly()
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        try {
            model?.close()
        } catch (_: Exception) {
        }
        model = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        this.events = events
    }

    override fun onCancel(arguments: Any?) {
        this.events = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> {
                val path = call.argument<String>("modelPath")
                if (path.isNullOrBlank()) {
                    result.error("bad_args", "modelPath required", null)
                    return
                }
                io.execute {
                    try {
                        if (model == null || modelPath != path) {
                            try {
                                model?.close()
                            } catch (_: Exception) {
                            }
                            model = Model(path)
                            modelPath = path
                        }
                        mainHandler.post { result.success(true) }
                    } catch (e: Exception) {
                        mainHandler.post {
                            result.error("prepare_failed", e.message, null)
                        }
                    }
                }
            }
            "start" -> {
                val m = model
                if (m == null) {
                    result.error("no_model", "请先 prepare 模型", null)
                    return
                }
                try {
                    stopQuietly()
                    val recognizer = Recognizer(m, 16000.0f)
                    val service = SpeechService(recognizer, 16000.0f)
                    service.startListening(object : RecognitionListener {
                        override fun onPartialResult(hypothesis: String?) {
                            emit("partial", extractText(hypothesis))
                        }

                        override fun onResult(hypothesis: String?) {
                            emit("result", extractText(hypothesis))
                        }

                        override fun onFinalResult(hypothesis: String?) {
                            emit("final", extractText(hypothesis))
                        }

                        override fun onError(e: Exception?) {
                            emit("error", e?.message ?: "vosk error")
                        }

                        override fun onTimeout() {
                            emit("timeout", "")
                        }
                    })
                    speechService = service
                    result.success(true)
                } catch (e: Exception) {
                    result.error("start_failed", e.message, null)
                }
            }
            "stop" -> {
                io.execute {
                    var text = ""
                    try {
                        speechService?.stop()
                    } catch (_: Exception) {
                    }
                    try {
                        speechService?.shutdown()
                    } catch (_: Exception) {
                    }
                    speechService = null
                    // final 已通过事件发出；这里再给 Dart 一个同步返回点
                    mainHandler.post { result.success(text) }
                }
            }
            "isReady" -> result.success(model != null)
            else -> result.notImplemented()
        }
    }

    private fun stopQuietly() {
        try {
            speechService?.stop()
        } catch (_: Exception) {
        }
        try {
            speechService?.shutdown()
        } catch (_: Exception) {
        }
        speechService = null
    }

    private fun emit(type: String, text: String) {
        mainHandler.post {
            events?.success(mapOf("type" to type, "text" to text))
        }
    }

    private fun extractText(hypothesis: String?): String {
        if (hypothesis.isNullOrBlank()) return ""
        return try {
            val json = JSONObject(hypothesis)
            when {
                json.has("text") -> json.optString("text", "")
                json.has("partial") -> json.optString("partial", "")
                else -> ""
            }.trim()
        } catch (_: Exception) {
            hypothesis.trim()
        }
    }
}
