package opensource.wild

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class ReaderSpeechChannel(context: Context, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val audio = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()
    private val commands = MethodChannel(messenger, "litetale/reader_speech")
    private val events = EventChannel(messenger, "litetale/reader_speech/events")
    private val voiceRequests = mutableListOf<MethodChannel.Result>()
    private var engine: TextToSpeech? = null
    private var voices = emptyList<Voice>()
    private var configuredVoice: String? = null
    private var ready = false
    private var disposed = false
    private var foreground = false
    private var generation = 0
    private var focusGeneration = 0
    private var focusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var focusRequest: AudioFocusRequest? = null
    private var utteranceId: String? = null
    private var sink: EventChannel.EventSink? = null

    val isSpeaking: Boolean get() = utteranceId != null

    init {
        commands.setMethodCallHandler(::handle)
        events.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }

    override fun onCancel(arguments: Any?) {
        sink = null
        stop()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "voices" -> initialize(result)
            "speak" -> speak(call, result)
            "pause" -> {
                if (call.arguments == utteranceId) stop()
                result.success(false)
            }
            "resume" -> result.success(false)
            "stop" -> {
                if (call.arguments == utteranceId) stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun initialize(result: MethodChannel.Result) {
        if (ready) {
            describeVoices(result)
            return
        }
        voiceRequests.add(result)
        if (engine != null) return
        val attempt = ++generation
        try {
            engine = TextToSpeech(app) { status ->
                main.post {
                    if (!disposed && generation == attempt) {
                        finishInitialization(status == TextToSpeech.SUCCESS)
                    }
                }
            }
        } catch (_: Exception) {
            finishInitialization(false)
            return
        }
        main.postDelayed({
            if (!disposed && !ready && generation == attempt) finishInitialization(false)
        }, 7000)
    }

    private fun finishInitialization(success: Boolean) {
        ready = success && engine != null
        if (ready) {
            engine?.setAudioAttributes(attributes)
            engine?.setOnUtteranceProgressListener(listener)
            voiceRequests.forEach(::describeVoices)
        } else {
            generation++
            engine?.shutdown()
            engine = null
            voiceRequests.forEach {
                it.error("tts_unavailable", "无法启动系统语音，请检查设备的文字转语音设置", null)
            }
        }
        voiceRequests.clear()
    }

    private fun availableVoices(tts: TextToSpeech): List<Voice> = tts.voices.orEmpty()
        .filterNot { TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED in it.features }
        .sortedWith(compareBy({ it.locale.toLanguageTag() }, { it.name }))

    private fun describeVoices(result: MethodChannel.Result) {
        voices = engine?.let(::availableVoices).orEmpty()
        result.success(mapOf(
            "limit" to TextToSpeech.getMaxSpeechInputLength(),
            "voices" to voices.map {
                mapOf("id" to it.name, "name" to it.name,
                    "language" to it.locale.toLanguageTag(), "network" to it.isNetworkConnectionRequired,
                    "quality" to it.quality)
            },
        ))
    }

    private fun speak(call: MethodCall, result: MethodChannel.Result) {
        if (!foreground) {
            result.error("speech_inactive", "请返回阅读器继续朗读", null)
            return
        }
        val tts = engine
        if (tts == null || !ready) {
            result.error("tts_unavailable", "请重新打开朗读面板", null)
            return
        }
        val id = call.argument<String>("id")
        val text = call.argument<String>("text")
        val rate = call.argument<Double>("rate")
        if (id == null || text.isNullOrEmpty() || text.length > TextToSpeech.getMaxSpeechInputLength() || rate == null || !rate.isFinite()) {
            stop()
            result.error("invalid_speech", "朗读内容无效", null)
            return
        }
        val voiceId = call.argument<String>("voice")
        var voice = selectVoice(voiceId)
        if (voice == null) {
            voices = availableVoices(tts)
            voice = selectVoice(voiceId)
        }
        if (voice == null || (configuredVoice != voice.name && tts.setVoice(voice) != TextToSpeech.SUCCESS)) {
            configuredVoice = null
            stop()
            result.error("voice_unavailable", "该音色不可用，请在系统设置安装语音或选择其他音色", null)
            return
        }
        configuredVoice = voice.name
        if (!requestFocus()) {
            result.error("speech_audio", "无法取得朗读音频，请重试", null)
            return
        }
        tts.setSpeechRate(rate.toFloat().coerceIn(.5f, 2f))
        utteranceId = id
        if (tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, id) == TextToSpeech.SUCCESS) {
            result.success(null)
        } else {
            stop()
            result.error("speech_failed", "系统语音未能播放，请重试", null)
        }
    }

    private fun selectVoice(id: String?): Voice? {
        if (id != null) return voices.firstOrNull { it.name == id }
        return voices.asSequence()
            .filter { (it.locale.language == "zh" || it.locale.language == "cmn") && !it.isNetworkConnectionRequired }
            .maxWithOrNull(compareBy({ it.locale.country == "CN" }, { it.quality }))
    }

    @Suppress("DEPRECATION")
    private fun requestFocus(): Boolean {
        if (focusListener != null) return true
        val attempt = ++focusGeneration
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            if (change < 0) main.post {
                if (attempt == focusGeneration) interrupt()
            }
        }
        val status = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes)
                .setWillPauseWhenDucked(true)
                .setOnAudioFocusChangeListener(listener, main)
                .build()
            audio.requestAudioFocus(request).also {
                if (it == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) focusRequest = request
            }
        } else {
            audio.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
        if (status != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) return false
        focusListener = listener
        return true
    }

    @Suppress("DEPRECATION")
    private fun stop() {
        utteranceId = null
        engine?.stop()
        focusGeneration++
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audio.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            focusListener?.let { audio.abandonAudioFocus(it) }
        }
        focusListener = null
    }

    fun setForeground(active: Boolean) {
        foreground = active
        if (!active) interrupt()
    }

    private fun interrupt() {
        val id = utteranceId ?: return
        stop()
        sink?.success(mapOf("id" to id, "type" to "interrupted"))
    }

    private val listener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) = send(utteranceId, "started")
        override fun onDone(utteranceId: String?) = send(utteranceId, "done")
        override fun onStop(utteranceId: String?, interrupted: Boolean) = send(utteranceId, "interrupted")
        @Deprecated("Android calls this on older engines")
        override fun onError(utteranceId: String?) = send(utteranceId, "error")
        override fun onError(utteranceId: String?, errorCode: Int) = send(utteranceId, "error")
        override fun onRangeStart(utteranceId: String?, start: Int, end: Int, frame: Int) = send(utteranceId, "range", start)
    }

    private fun send(id: String?, type: String, start: Int? = null) {
        main.post {
            if (id != null && id == utteranceId) {
                if (type == "interrupted" || type == "error") stop()
                sink?.success(mapOf("id" to id, "type" to type, "start" to start))
            }
        }
    }

    fun dispose() {
        disposed = true
        generation++
        stop()
        engine?.shutdown()
        engine = null
        ready = false
        voiceRequests.forEach { it.error("tts_closed", "阅读器已关闭", null) }
        voiceRequests.clear()
        sink = null
        commands.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}
