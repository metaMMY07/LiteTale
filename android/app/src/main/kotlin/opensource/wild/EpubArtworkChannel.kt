package opensource.wild

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.Handler
import android.os.Build
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.*
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import kotlin.math.ceil
import kotlin.math.roundToInt

/**
 * One-shot, offline import rendering. This view is separate from source browser
 * sessions: no source navigation, CookieManager mutation, JS bridge, file access,
 * downloads, or network requests. Only sanitized data images/fonts are allowed.
 */
class EpubArtworkChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "litetale/epub_artwork")
    private val handler = Handler(Looper.getMainLooper())
    private val encoder = Executors.newSingleThreadExecutor()
    private var active: Render? = null
    private var disposed = false
    private val probeScript by lazy {
        activity.assets.open("flutter_assets/lib/assets/epub_artwork_probe.js")
            .bufferedReader(Charsets.UTF_8).use { it.readText() }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            val html = call.argument<String>("html")
            when {
                call.method != "render" -> result.notImplemented()
                disposed || activity.isFinishing -> result.success(null)
                active != null -> result.error("busy", "特殊页面正在排版", null)
                html == null || html.toByteArray(Charsets.UTF_8).size > 12 * 1024 * 1024 ->
                    result.success(null)
                else -> {
                    try {
                        Render(html, result).also { active = it }.start()
                    } catch (_: Exception) {
                        val pending = active
                        if (pending == null) result.success(null) else pending.finish(null)
                    }
                }
            }
        }
    }

    fun dispose() {
        disposed = true
        active?.finish(null)
        channel.setMethodCallHandler(null)
        encoder.shutdown()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private inner class Render(
        val html: String,
        val result: MethodChannel.Result,
    ) {
        val web = WebView(activity)
        val host = FrameLayout(activity)
        val density = activity.resources.displayMetrics.density
        val width = (360 * density).roundToInt().coerceAtLeast(360)
        var height = (800 * density).roundToInt()
        var finished = false
        var startedPolling = false
        var readySamples = 0
        val timeout = Runnable { finish(null) }
        val poll = Runnable { checkReady() }

        fun start() {
            web.settings.apply {
                javaScriptEnabled = true // Only our evaluateJavascript probe.
                javaScriptCanOpenWindowsAutomatically = false
                domStorageEnabled = false
                databaseEnabled = false
                allowFileAccess = false
                allowContentAccess = false
                blockNetworkLoads = true
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                cacheMode = WebSettings.LOAD_NO_CACHE
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    offscreenPreRaster = true
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    isAlgorithmicDarkeningAllowed = false
                }
                loadsImagesAutomatically = true
                setSupportMultipleWindows(false)
                builtInZoomControls = false
                displayZoomControls = false
                textZoom = 100
                defaultFontSize = 16
                minimumFontSize = 1
                minimumLogicalFontSize = 1
                layoutAlgorithm = WebSettings.LayoutAlgorithm.NORMAL
            }
            web.isFocusable = false
            web.isFocusableInTouchMode = false
            web.isSaveEnabled = false
            web.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            web.isVerticalScrollBarEnabled = false
            web.isHorizontalScrollBarEnabled = false
            web.setBackgroundColor(Color.WHITE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                web.isForceDarkAllowed = false
            }
            web.setLayerType(View.LAYER_TYPE_SOFTWARE, null)
            web.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                    if (request.url.toString() == "https://litetale-epub.invalid/reader-serif.ttf") {
                        try {
                            return WebResourceResponse("font/ttf", null,
                                activity.assets.open("flutter_assets/lib/assets/fonts/LXGWNeoZhiSongPlus.ttf"))
                        } catch (_: Exception) { /* Keep the readable serif fallback. */ }
                    }
                    return WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(ByteArray(0)))
                }

                override fun onPageFinished(view: WebView, url: String) {
                    if (finished || startedPolling) return
                    startedPolling = true
                    checkReady()
                }
                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                    finish(null)
                    return true
                }
            }
            web.webChromeClient = WebChromeClient()
            // Visible and attached behind the opaque Flutter view, so Chromium
            // submits real visual frames; no hidden WebView screenshot guesses.
            host.addView(web, FrameLayout.LayoutParams(width, height))
            (activity.findViewById<ViewGroup>(android.R.id.content)).addView(
                host, 0, ViewGroup.LayoutParams(width, height),
            )
            layout()
            handler.postDelayed(timeout, 12000)
            web.loadDataWithBaseURL("https://litetale-epub.invalid/", html, "text/html", "UTF-8", null)
        }

        fun layout() {
            host.layoutParams?.apply { width = this@Render.width; height = this@Render.height }
            web.layoutParams?.apply { width = this@Render.width; height = this@Render.height }
            val w = View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY)
            val h = View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY)
            host.measure(w, h)
            host.layout(0, 0, width, height)
            web.measure(w, h)
            web.layout(0, 0, width, height)
        }

        fun checkReady() {
            if (finished) return
            web.evaluateJavascript(probeScript) { raw ->
                if (finished) return@evaluateJavascript
                try {
                    val state = JSONObject(raw)
                    if (!state.optBoolean("ready")) {
                        readySamples = 0
                        handler.postDelayed(poll, 80)
                        return@evaluateJavascript
                    }
                    val cssHeight = ceil(state.getDouble("height")).toInt()
                    val cssWidth = ceil(state.getDouble("width")).toInt()
                    if (cssHeight > 4096 || cssWidth > 400) {
                        finish(null) // Too large for one artwork leaf: use text.
                        return@evaluateJavascript
                    }
                    if (++readySamples < 2) {
                        handler.postDelayed(poll, 80)
                        return@evaluateJavascript
                    }
                    height = (cssHeight.coerceAtLeast(800) * density).roundToInt()
                    layout()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        web.postVisualStateCallback(1L, object : WebView.VisualStateCallback() {
                            override fun onComplete(requestId: Long) {
                                if (!finished) handler.post { capture() }
                            }
                        })
                    } else {
                        handler.postDelayed({ if (!finished) capture() }, 200)
                    }
                } catch (_: Exception) {
                    finish(null)
                }
            }
        }

        fun capture() {
            if (finished) return
            try {
                val outputHeight = ceil(height * 720.0 / width).toInt()
                if (outputHeight > 8192 || 720L * outputHeight > 6 * 1024 * 1024) {
                    finish(null)
                    return
                }
                val bitmap = Bitmap.createBitmap(720, outputHeight, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bitmap)
                canvas.drawColor(Color.WHITE)
                canvas.scale(720f / width, 720f / width)
                web.draw(canvas)
                // PNG encoding does not block either reader gestures or UI.
                encoder.execute {
                    val bytes = try {
                        ByteArrayOutputStream().use { output ->
                            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                            output.toByteArray().takeIf { it.size <= 8 * 1024 * 1024 }
                        }
                    } catch (_: Exception) { null }
                    finally { bitmap.recycle() }
                    handler.post { finish(bytes) }
                }
            } catch (_: Exception) {
                finish(null)
            }
        }

        fun finish(bytes: ByteArray?) {
            if (finished) return
            finished = true
            handler.removeCallbacks(timeout)
            handler.removeCallbacks(poll)
            try {
                web.stopLoading()
                web.webChromeClient = null
                host.removeView(web)
                (host.parent as? ViewGroup)?.removeView(host)
                web.destroy()
            } catch (_: Exception) { /* Do not affect any source WebView. */ }
            if (active === this) active = null
            result.success(bytes)
        }
    }

}
