package opensource.wild

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** SAF is necessary here: file_selector's save dialog is not supported on Android. */
class SettingsDocumentChannel(private val activity: FlutterFragmentActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "litetale/settings")
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null
    private val saveLauncher = activity.registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { response ->
        val reply = pending ?: return@registerForActivityResult
        val bytes = pendingBytes
        pending = null
        pendingBytes = null
        val uri = response.data?.data
        if (response.resultCode != Activity.RESULT_OK || uri == null || bytes == null) {
            reply.success(false)
        } else {
            io.execute {
                try {
                    val stream = activity.contentResolver.openOutputStream(uri, "wt")
                        ?: throw IllegalStateException("Document is unavailable")
                    stream.use { it.write(bytes); it.flush() }
                    main.post { reply.success(true) }
                } catch (_: Exception) {
                    main.post { reply.error("document_write", "无法保存文件，请选择可写入的位置", null) }
                }
            }
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "sdk" -> result.success(Build.VERSION.SDK_INT)
                "appLanguage" -> {
                    if (Build.VERSION.SDK_INT < 33) result.success(false)
                    else try {
                        activity.startActivity(Intent(Settings.ACTION_APP_LOCALE_SETTINGS).apply {
                            data = Uri.parse("package:${activity.packageName}")
                        })
                        result.success(true)
                    } catch (_: Exception) { result.success(false) }
                }
                "saveDocument" -> {
                    if (pending != null) {
                        result.error("document_busy", "请先完成当前文件选择", null)
                        return@setMethodCallHandler
                    }
                    val bytes = call.argument<ByteArray>("bytes")
                    val name = call.argument<String>("name")
                    if (bytes == null || name.isNullOrBlank() || name.contains('/') || name.contains('\\')) {
                        result.error("invalid_document", "文件数据无效", null)
                        return@setMethodCallHandler
                    }
                    pending = result
                    pendingBytes = bytes
                    try {
                        saveLauncher.launch(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = call.argument<String>("mime") ?: "application/octet-stream"
                            putExtra(Intent.EXTRA_TITLE, name)
                        })
                    } catch (_: Exception) {
                        pending = null
                        pendingBytes = null
                        result.error("document_picker", "无法打开系统文件选择器", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
