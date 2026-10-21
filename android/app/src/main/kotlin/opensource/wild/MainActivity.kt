package opensource.wild

import android.os.*
import android.view.*
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import dev.flutter.packages.file_selector_android.FileSelectorAndroidPlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.newSingleThreadContext
import kotlinx.coroutines.sync.Mutex
import kotlin.coroutines.EmptyCoroutineContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.file.Files
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class MainActivity : FlutterFragmentActivity() {

    private val scope = CoroutineScope(EmptyCoroutineContext)
    private val uiThreadHandler = Handler(Looper.getMainLooper())
    private var epubArtwork: EpubArtworkChannel? = null
    private var epubPages: EpubPageChannel? = null
    
    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Android-only --no-pub builds can retain an older generated registrant
        // when desktop symlinks are unavailable. Never register the picker twice.
        if (!flutterEngine.plugins.has(FileSelectorAndroidPlugin::class.java)) {
            flutterEngine.plugins.add(FileSelectorAndroidPlugin())
        }

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "litetale/ptq_curl",
            PTQPageCurlPlatformViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        LauncherIconChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        SettingsDocumentChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        epubArtwork = EpubArtworkChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        epubPages = EpubPageChannel(this, flutterEngine.dartExecutor.binaryMessenger)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "litetale/web_session")
            .setMethodCallHandler { call, result ->
                if (call.method != "flushCookies") {
                    result.notImplemented()
                } else {
                    // flush() performs disk I/O. Keep it off the UI thread and
                    // acknowledge persistence before Flutter saves login state.
                    scope.launch {
                        try {
                            android.webkit.CookieManager.getInstance().flush()
                            uiThreadHandler.post { result.success(null) }
                        } catch (_: Exception) {
                            uiThreadHandler.post {
                                result.error("web_session_save_failed", "无法保存文库8网页会话，请重试。", null)
                            }
                        }
                    }
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "methods").setMethodCallHandler { call, result ->
            result.withCoroutine {
                when (call.method) {
                    "dataRoot" -> {
                        androidDataLocal()
                    }
                    "getKeepScreenOn" -> getKeepScreenOn()
                    "setKeepScreenOn" -> setKeepScreenOn(call.arguments as Boolean)
                    else -> {
                        null
                    }
                }
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "volume_button")
            .setStreamHandler(volumeStreamHandler)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        epubArtwork?.dispose()
        epubArtwork = null
        epubPages?.dispose()
        epubPages = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun MethodChannel.Result.withCoroutine(exec: () -> Any?) {
        scope.launch {
            try {
                val data = exec()
                uiThreadHandler.post {
                    when (data) {
                        null -> {
                            notImplemented()
                        }
                        is Unit -> {
                            success(null)
                        }
                        else -> {
                            success(data)
                        }
                    }
                }
            } catch (e: Exception) {
                uiThreadHandler.post {
                    error("", e.message, "")
                }
            }

        }
    }

    private fun androidDataLocal(): String {
        val localFile = File(filesDir.absolutePath, "data.local")
        if (localFile.exists()) {
            val path = String(FileInputStream(localFile).use { it.readBytes() })
            if (File(path).isDirectory) {
                return path
            }
        }
        return filesDir.absolutePath
    }

    private fun getKeepScreenOn() =
        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON.and(window.attributes.flags) > 0

    private fun setKeepScreenOn(value: Boolean) =
        uiThreadHandler.post {
            if (value)
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }


// volume_buttons

    private var volumeEvents: EventChannel.EventSink? = null
    private val capturedVolumeKeys = mutableSetOf<Int>()

    private val volumeStreamHandler = object : EventChannel.StreamHandler {

        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            volumeEvents = events
        }

        override fun onCancel(arguments: Any?) {
            volumeEvents = null
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val keyCode = event.keyCode
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            when (event.action) {
                KeyEvent.ACTION_DOWN -> {
                    if (event.repeatCount == 0) {
                        capturedVolumeKeys.remove(keyCode)
                        volumeEvents?.let { sink ->
                            capturedVolumeKeys.add(keyCode)
                            sink.success(if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) "DOWN" else "UP")
                            return true
                        }
                    } else if (keyCode in capturedVolumeKeys) {
                        // One physical press turns one page. Android repeats a
                        // held key; do not skip several pages while it is held.
                        return true
                    }
                }
                KeyEvent.ACTION_UP -> {
                    // Pair the consumed down/up even if a modal or preference
                    // change cancelled the stream while the key was held.
                    if (capturedVolumeKeys.remove(keyCode)) return true
                }
            }
        }
        // No active reader subscription: preserve the system volume behavior,
        // including events dispatched to a focused native curl view.
        return super.dispatchKeyEvent(event)
    }

}
