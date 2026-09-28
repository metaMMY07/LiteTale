package opensource.wild

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import ptq.mpga.ptqbookpageview.widget.PTQBookPageCurlNativeView

internal class PTQPageCurlPlatformViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val channel = MethodChannel(messenger, "$CHANNEL_NAME/$viewId")
        val nativeView = PTQBookPageCurlNativeView(context) { method, payload ->
            channel.invokeMethod(method, payload)
        }
        val platformView = PTQPageCurlPlatformView(nativeView, channel)
        val creationParams = args.asStringMap()

        nativeView.updateState(
            pageCount = creationParams.intValue("pageCount", 1),
            index = creationParams.intValue("index", 0),
            paperColor = creationParams.intValue("paperColor", -1),
        )
        creationParams.pageImages().forEach { (index, bytes) ->
            nativeView.setPageImage(index, bytes) { _, _ -> }
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setState" -> {
                    val values = call.arguments.asStringMap()
                    nativeView.updateState(
                        pageCount = values.intValue("pageCount", 1),
                        index = values.intValue("index", 0),
                        paperColor = values.intValue("paperColor", -1),
                    )
                    result.success(null)
                }

                "setPage" -> {
                    val values = call.arguments.asStringMap()
                    val index = values.intValue("index", -1)
                    val bytes = values.byteArray("bytes")
                    if (index < 0 || bytes == null) {
                        result.error("invalid_page", "setPage requires index and PNG bytes", null)
                    } else {
                        nativeView.setPageImage(index, bytes) { success, error ->
                            if (success) result.success(null)
                            else result.error(error ?: "decode_failed", "Could not decode page $index", null)
                        }
                    }
                }

                "turn" -> {
                    val values = call.arguments.asStringMap()
                    val direction = values.intValue("direction", 0)
                    val startY = values.doubleValue("startY", 0.5)
                    nativeView.turn(direction, startY) { accepted ->
                        result.success(accepted)
                    }
                }

                "getReadyIndex" -> result.success(nativeView.readyIndex())

                else -> result.notImplemented()
            }
        }

        return platformView
    }

    private companion object {
        const val CHANNEL_NAME = "litetale/ptq_curl"
    }
}

private class PTQPageCurlPlatformView(
    private val nativeView: PTQBookPageCurlNativeView,
    private val channel: MethodChannel,
) : PlatformView {
    override fun getView() = nativeView

    override fun dispose() {
        channel.setMethodCallHandler(null)
        nativeView.dispose()
    }
}

private fun Any?.asStringMap(): Map<String, Any?> =
    (this as? Map<*, *>)
        ?.entries
        ?.mapNotNull { (key, value) -> (key as? String)?.let { it to value } }
        ?.toMap()
        .orEmpty()

private fun Map<String, Any?>.intValue(key: String, fallback: Int): Int =
    (this[key] as? Number)?.toLong()?.toInt() ?: fallback

private fun Map<String, Any?>.doubleValue(key: String, fallback: Double): Double =
    (this[key] as? Number)?.toDouble() ?: fallback

private fun Map<String, Any?>.byteArray(key: String): ByteArray? = this[key] as? ByteArray

private fun Map<String, Any?>.pageImages(): List<Pair<Int, ByteArray>> {
    val pageMap = this["pages"] as? Map<*, *> ?: return emptyList()
    return pageMap.mapNotNull { (key, value) ->
        val index = (key as? Number)?.toLong()?.toInt() ?: key?.toString()?.toIntOrNull()
        val bytes = value as? ByteArray
        if (index != null && bytes != null) index to bytes else null
    }
}
