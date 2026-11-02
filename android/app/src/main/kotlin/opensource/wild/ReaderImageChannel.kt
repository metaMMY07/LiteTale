package opensource.wild

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Adds only app-created pictures. No broad media/storage permissions. */
class ReaderImageChannel(private val activity: FlutterFragmentActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "litetale/reader_images")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private data class Pending(val bytes: ByteArray, val name: String, val mime: String, val result: MethodChannel.Result)
    private var pending: Pending? = null
    private var closed = false
    private val picker = activity.registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { selection ->
        val job = pending ?: return@registerForActivityResult
        val uri = selection.data?.data
        if (selection.resultCode != Activity.RESULT_OK || uri == null) finish("cancelled")
        else worker.execute {
            try { write(uri, job.bytes); main.post { finish("exported") } }
            catch (_: Exception) { main.post { fail("无法写入图片文件") } }
        }
    }
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method !in setOf("save", "export")) { result.notImplemented(); return@setMethodCallHandler }
            if (closed || pending != null) { result.error("image_busy", "请先完成当前保存", null); return@setMethodCallHandler }
            val bytes = call.argument<ByteArray>("bytes")
            val name = call.argument<String>("name")
            val mime = call.argument<String>("mime")
            if (bytes == null || bytes.isEmpty() || bytes.size > 20*1024*1024 || name.isNullOrBlank() || name.length > 150 || name.contains('/') || name.contains('\\') ||
                mime !in setOf("image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp", "image/avif")) {
                result.error("invalid_image", "图片数据无效", null); return@setMethodCallHandler
            }
            val job = Pending(bytes, name, mime!!, result)
            pending = job
            if (call.method == "export" || Build.VERSION.SDK_INT < 29) {
                try { picker.launch(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE); type = job.mime; putExtra(Intent.EXTRA_TITLE, job.name)
                }) } catch (_: Exception) { fail("无法打开系统文件保存窗口") }
            } else worker.execute {
                var uri: Uri? = null
                try {
                    val values = ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, job.name)
                        put(MediaStore.Images.Media.MIME_TYPE, job.mime)
                        put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/LiteTale")
                        put(MediaStore.Images.Media.IS_PENDING, 1)
                    }
                    uri = activity.contentResolver.insert(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
                        ?: throw IllegalStateException()
                    write(uri, job.bytes)
                    val committed = activity.contentResolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
                    if (committed != 1) throw IllegalStateException()
                    main.post { finish("saved") }
                } catch (_: Exception) {
                    // Roll back only the single item created by this operation.
                    uri?.let { try { activity.contentResolver.delete(it, null, null) } catch (_: Exception) {} }
                    main.post { fail("未能保存到相册，请使用导出原图") }
                }
            }
        }
    }
    private fun write(uri: Uri, bytes: ByteArray) {
        activity.contentResolver.openOutputStream(uri, "w")?.use { it.write(bytes); it.flush() } ?: throw IllegalStateException()
    }
    private fun finish(status: String) { if (closed) return; val job = pending; pending = null; job?.result?.success(status) }
    private fun fail(message: String) { if (closed) return; val job = pending; pending = null; job?.result?.error("image_save", message, null) }
    fun dispose() {
        if (closed) return
        fail("保存窗口已关闭"); closed = true; channel.setMethodCallHandler(null); picker.unregister(); worker.shutdown()
    }
}
