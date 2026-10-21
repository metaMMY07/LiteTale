package opensource.wild

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
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
import kotlin.math.roundToInt

/** Persistent, bounded, offline CSS pagination. Never touches source sessions. */
class EpubPageChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "litetale/epub_pages")
    private val handler = Handler(Looper.getMainLooper())
    private val encoder = Executors.newSingleThreadExecutor()
    private val sessions = LinkedHashMap<String, Session>(4, .75f, true)
    private var pending: MethodChannel.Result? = null
    private var active: Session? = null
    private var closed = false
    private var operationStarted = 0L
    private val paginatorBytes by lazy { activity.assets.open("flutter_assets/lib/assets/epub_foliate_paginator.js").use { it.readBytes() } }
    private val engineBytes by lazy { activity.assets.open("flutter_assets/lib/assets/epub_page_engine.js").use { it.readBytes() } }
    private val serifBytes by lazy { activity.assets.open("flutter_assets/lib/assets/fonts/LXGWNeoZhiSongPlus.ttf").use { it.readBytes() } }
    private val timeout = Runnable {
        active?.let { sessions.remove(it.id); it.destroy() }
        finishError("epub_timeout", "本地 CSS 排版超时，请重试")
    }
    private val origin = "https://litetale-epub.invalid"

    init {
        channel.setMethodCallHandler { call, result ->
            if (closed || activity.isFinishing) { result.error("closed", "阅读器已关闭", null); return@setMethodCallHandler }
            if (call.method == "close") {
                if (call.argument<Boolean>("all") == true) {
                    if (Log.isLoggable("LiteTaleEpub", Log.DEBUG)) Log.d("LiteTaleEpub", "release pool=${sessions.size}")
                    sessions.values.forEach { it.destroy() }; sessions.clear()
                }
                (call.argument<List<String>>("ids") ?: emptyList()).forEach { id ->
                    sessions.remove(id)?.destroy()
                }
                result.success(null); return@setMethodCallHandler
            }
            if (pending != null) { result.error("busy", "阅读器正在排版", null); return@setMethodCallHandler }
            val id = call.argument<String>("id")
            if (id == null || !id.matches(Regex("[a-f0-9]{64}"))) { result.error("invalid", "页面编号无效", null); return@setMethodCallHandler }
            try {
                when (call.method) {
                    "prepare" -> {
                        sessions[id]?.let { result.success(it.metadata); return@setMethodCallHandler }
                        val html = call.argument<String>("html") ?: throw IllegalArgumentException()
                        val options = call.argument<Map<String, Any>>("options") ?: throw IllegalArgumentException()
                        val width = (options["width"] as Number).toDouble()
                        val height = (options["height"] as Number).toDouble()
                        if (Log.isLoggable("LiteTaleEpub", Log.DEBUG)) Log.d("LiteTaleEpub", "layout key=${id.take(8)} scope=${call.argument<Int>("cacheScope")} rev=${call.argument<Int>("revision")} w=$width h=$height top=${options["top"]} content=${options["contentHeight"]} dpr=${options["pixelRatio"]}")
                        if (html.toByteArray().size > 12*1024*1024 || width !in 100.0..3000.0 || height !in 100.0..5000.0) throw IllegalArgumentException()
                        val resources = call.argument<Map<String, ByteArray>>("resources") ?: emptyMap()
                        if (resources.keys.any { !it.matches(Regex("[a-f0-9]{64}\\.(png|jpe?g|gif|webp|bmp|avif|ttf|otf|woff2?)")) } ||
                            resources.values.sumOf { it.size.toLong() } > 40L*1024*1024) throw IllegalArgumentException()
                        val userFont = call.argument<ByteArray>("userFont")
                        if (userFont != null && userFont.size > 64*1024*1024) throw IllegalArgumentException()
                        while (sessions.size >= 3) sessions.remove(sessions.keys.first())?.destroy()
                        val session = Session(id, html, JSONObject(options), resources, userFont, width, height)
                        sessions[id] = session
                        begin(result, session)
                        session.start()
                    }
                    "capture" -> {
                        val session = sessions[id]
                        if (session == null) { result.error("missing_session", "页面需要重新排版", null); return@setMethodCallHandler }
                        val page = call.argument<Int>("page") ?: -1
                        if (page < 0 || page >= (session.metadata?.get("count") as? Int ?: 0)) throw IllegalArgumentException()
                        begin(result, session)
                        session.web.evaluateJavascript("EpubEngine.select($page).catch(e=>EpubEngine.error=String(e));null") { session.poll(true) }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                if (pending === result) finishError("epub_render", "无法排版本地页面")
                else result.error("invalid", "本地页面参数无效", null)
            }
        }
    }

    private fun begin(result: MethodChannel.Result, session: Session) {
        operationStarted = SystemClock.elapsedRealtime()
        pending = result; active = session
        handler.postDelayed(timeout, 18000)
    }
    private fun finish(value: Any?) {
        if (Log.isLoggable("LiteTaleEpub", Log.DEBUG)) {
            val operation = if (value is ByteArray) "capture" else "prepare"
            Log.d("LiteTaleEpub", "$operation ms=${SystemClock.elapsedRealtime()-operationStarted} pool=${sessions.size}")
        }
        handler.removeCallbacks(timeout)
        val result = pending; pending = null; active = null
        result?.success(value)
    }
    private fun finishError(code: String, message: String) {
        handler.removeCallbacks(timeout)
        val result = pending; pending = null; active = null
        result?.error(code, message, null)
    }
    fun dispose() {
        closed = true
        finishError("closed", "阅读器已关闭")
        sessions.values.forEach { it.destroy() }; sessions.clear()
        channel.setMethodCallHandler(null); encoder.shutdown()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private inner class Session(val id: String, val html: String, val options: JSONObject,
        val resources: Map<String, ByteArray>, val userFont: ByteArray?, cssWidth: Double, cssHeight: Double) {
        val web = WebView(activity)
        val host = FrameLayout(activity)
        val density = activity.resources.displayMetrics.density
        val width = (cssWidth*density).roundToInt()
        val height = (cssHeight*density).roundToInt()
        val background = Color.parseColor(options.getString("paper"))
        var metadata: Map<String, Any>? = null
        var destroyed = false
        var started = false
        fun response(mime: String, bytes: ByteArray) = WebResourceResponse(mime, null, 200, "OK",
            mapOf("Access-Control-Allow-Origin" to origin, "Cache-Control" to "no-store"), ByteArrayInputStream(bytes))
        fun start() {
            web.settings.apply {
                javaScriptEnabled=true; javaScriptCanOpenWindowsAutomatically=false
                domStorageEnabled=false; databaseEnabled=false; allowFileAccess=false; allowContentAccess=false
                blockNetworkLoads=true; mixedContentMode=WebSettings.MIXED_CONTENT_NEVER_ALLOW
                cacheMode=WebSettings.LOAD_NO_CACHE; textZoom=100; minimumFontSize=1; minimumLogicalFontSize=1
                useWideViewPort=true; loadWithOverviewMode=false
                builtInZoomControls=false; displayZoomControls=false; setSupportMultipleWindows(false)
                // A long multi-column iframe can be hundreds of viewports wide.
                // Pre-rasterizing its offscreen tiles exhausts Chromium's tile
                // budget. Explicit visual callbacks capture only the viewport.
                if(Build.VERSION.SDK_INT>=23) offscreenPreRaster=false
                if(Build.VERSION.SDK_INT>=33) isAlgorithmicDarkeningAllowed=false
            }
            web.isFocusable=false; web.isFocusableInTouchMode=false; web.isSaveEnabled=false
            web.importantForAccessibility=View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            web.isVerticalScrollBarEnabled=false; web.isHorizontalScrollBarEnabled=false
            web.setBackgroundColor(background)
            if(Build.VERSION.SDK_INT>=29) web.isForceDarkAllowed=false
            web.setLayerType(View.LAYER_TYPE_SOFTWARE,null)
            web.webViewClient=object:WebViewClient() {
                override fun shouldOverrideUrlLoading(view:WebView, request:WebResourceRequest)=
                    request.isForMainFrame || request.url.toString() != "$origin/chapter"
                override fun shouldInterceptRequest(view:WebView, request:WebResourceRequest):WebResourceResponse {
                    val uri=request.url
                    if(uri.scheme!="https" || uri.host!="litetale-epub.invalid" || uri.port != -1 || uri.query!=null)
                        return response("text/plain",ByteArray(0))
                    return try {
                        when(uri.path) {
                            "/chapter" -> response("text/html",html.toByteArray(Charsets.UTF_8))
                            "/paginator.js" -> response("text/javascript", paginatorBytes)
                            "/engine.js" -> response("text/javascript", engineBytes)
                            "/reader-serif.ttf" -> response("font/ttf",serifBytes)
                            "/user-font" -> response("font/ttf",userFont ?: ByteArray(0))
                            else -> {
                                val name=uri.path?.removePrefix("/resource/")
                                val bytes=resources[name] ?: ByteArray(0)
                                val mime=when(name?.substringAfterLast('.')) {
                                    "ttf" -> "font/ttf"; "otf" -> "font/otf"; "woff" -> "font/woff"; "woff2" -> "font/woff2"
                                    "jpg","jpeg" -> "image/jpeg"; else -> "image/${name?.substringAfterLast('.')}"
                                }
                                response(mime,bytes)
                            }
                        }
                    } catch (_:Exception) {response("text/plain",ByteArray(0))}
                }
                override fun onPageFinished(view:WebView,url:String) {
                    if(started || destroyed) return
                    started=true; options.put("chapterUrl", "$origin/chapter")
                    web.evaluateJavascript("startEpub($options);null") {poll(false)}
                }
                override fun onRenderProcessGone(view:WebView,detail:RenderProcessGoneDetail):Boolean {
                    sessions.remove(id);destroy()
                    if(active===this@Session) finishError("epub_process", "本地排版组件已退出，请重试")
                    return true
                }
            }
            host.addView(web,FrameLayout.LayoutParams(width,height))
            activity.findViewById<ViewGroup>(android.R.id.content).addView(host,0,ViewGroup.LayoutParams(width,height))
            val w=View.MeasureSpec.makeMeasureSpec(width,View.MeasureSpec.EXACTLY)
            val h=View.MeasureSpec.makeMeasureSpec(height,View.MeasureSpec.EXACTLY)
            host.measure(w,h);host.layout(0,0,width,height);web.measure(w,h);web.layout(0,0,width,height)
            web.loadDataWithBaseURL("$origin/index", """<!doctype html><html><head>
                <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; frame-src 'self'; img-src 'self' data:; font-src 'self';">
                <script type="module" src="$origin/paginator.js"></script><script src="$origin/engine.js"></script>
                </head><body></body></html>""", "text/html","UTF-8",null)
        }
        fun poll(capture:Boolean) {
            if(destroyed || active!==this) return
            val expression=if(capture)
                "({ready:!!window.EpubEngine?.ready,selected:!!window.EpubEngine?.selected,error:window.EpubEngine?.error})"
                else "(window.EpubEngine?.ready?{ready:true,error:window.EpubEngine.error,pages:window.EpubEngine.pages,textLength:window.EpubEngine.textLength,text:window.EpubEngine.text}:{ready:false,error:window.EpubEngine?.error})"
            web.evaluateJavascript(expression) { raw ->
                if(destroyed || active!==this) return@evaluateJavascript
                try {
                    val info=JSONObject(raw)
                    if(!info.isNull("error")) {
                        sessions.remove(id);destroy();finishError("epub_layout", "本章 CSS 排版失败");return@evaluateJavascript
                    }
                    if(!info.optBoolean("ready") || capture && !info.optBoolean("selected")) {
                        handler.postDelayed({poll(capture)},35);return@evaluateJavascript
                    }
                    if(capture) {
                        if(Build.VERSION.SDK_INT>=23) web.postVisualStateCallback(System.nanoTime(),object:WebView.VisualStateCallback(){
                            override fun onComplete(requestId:Long) { if(!destroyed && active===this@Session) handler.post {capture()} }
                        }) else handler.postDelayed({capture()},60)
                    } else {
                        val pages=info.getJSONArray("pages")
                        val ranges=(0 until pages.length()).map {i -> val p=pages.getJSONObject(i)
                            mapOf("start" to p.getInt("start"),"end" to p.getInt("end"))}
                        val text=info.optString("text")
                        require(text.length<=12*1024*1024)
                        metadata=mapOf("count" to ranges.size,"ranges" to ranges,"textLength" to info.optInt("textLength"),"text" to text)
                        finish(metadata)
                    }
                } catch (_:Exception) { sessions.remove(id);destroy();finishError("epub_render", "本地排版返回无效结果") }
            }
        }
        fun capture() {
            if(destroyed || active!==this) return
            try {
                val drawStarted=SystemClock.elapsedRealtime()
                val outputWidth=width.coerceAtMost(1440)
                val outputHeight=(height*outputWidth.toDouble()/width).roundToInt()
                if(outputWidth.toLong()*outputHeight>6L*1024*1024) throw IllegalArgumentException()
                val bitmap=Bitmap.createBitmap(outputWidth,outputHeight,Bitmap.Config.ARGB_8888)
                val canvas=Canvas(bitmap);canvas.drawColor(background)
                canvas.scale(outputWidth.toFloat()/width,outputWidth.toFloat()/width);web.draw(canvas)
                val drawMs=SystemClock.elapsedRealtime()-drawStarted
                encoder.execute {
                    val encodeStarted=SystemClock.elapsedRealtime()
                    // For lossless WebP, quality is encoding effort, not image
                    // quality. Zero preserves every pixel with the fastest mode.
                    val fastLossless=Build.VERSION.SDK_INT>=30
                    val format=if(fastLossless) Bitmap.CompressFormat.WEBP_LOSSLESS else Bitmap.CompressFormat.PNG
                    val bytes=try {
                        val encoded=ByteArrayOutputStream().use {out ->
                            if(bitmap.compress(format,if(fastLossless) 0 else 100,out)) out.toByteArray() else null
                        }
                        val encodeMs=SystemClock.elapsedRealtime()-encodeStarted
                        if(Log.isLoggable("LiteTaleEpub",Log.DEBUG)) Log.d("LiteTaleEpub","capture-detail drawMs=$drawMs encodeMs=$encodeMs bytes=${encoded?.size ?: 0} format=$format")
                        // Explicit QA opt-in only: compare the decoded result
                        // with its source bitmap and time PNG on the same pixels.
                        if(encoded!=null && Log.isLoggable("LiteTaleEpubPixels",Log.DEBUG)) {
                            val decoded=BitmapFactory.decodeByteArray(encoded,0,encoded.size)
                            val sameBitmap=decoded!=null && bitmap.sameAs(decoded)
                            val decodedAlpha=decoded?.hasAlpha()
                            var identical=false
                            if(decoded!=null && decoded.width==bitmap.width && decoded.height==bitmap.height) {
                                // sameAs also compares bitmap storage metadata.
                                // Compare the actual decoded ARGB pixels instead.
                                val sourcePixels=IntArray(bitmap.width*bitmap.height)
                                val decodedPixels=IntArray(sourcePixels.size)
                                bitmap.getPixels(sourcePixels,0,bitmap.width,0,0,bitmap.width,bitmap.height)
                                decoded.getPixels(decodedPixels,0,decoded.width,0,0,decoded.width,decoded.height)
                                identical=sourcePixels.contentEquals(decodedPixels)
                            }
                            decoded?.recycle()
                            val pngStarted=SystemClock.elapsedRealtime()
                            val pngSize=ByteArrayOutputStream().use {out ->
                                bitmap.compress(Bitmap.CompressFormat.PNG,100,out);out.size()
                            }
                            Log.d("LiteTaleEpub","capture-verify identical=$identical format=$format encodeMs=$encodeMs bytes=${encoded.size} pngMs=${SystemClock.elapsedRealtime()-pngStarted} pngBytes=$pngSize sameBitmap=$sameBitmap sourceAlpha=${bitmap.hasAlpha()} decodedAlpha=$decodedAlpha")
                        }
                        encoded
                    } catch(_:Exception){null} finally {bitmap.recycle()}
                    handler.post {if(!destroyed && active===this) {if(bytes!=null) finish(bytes) else finishError("epub_image","页面绘制失败")}}
                }
            } catch(_:Exception){finishError("epub_image","页面绘制失败")}
        }
        fun destroy() {
            if(destroyed)return;destroyed=true
            try {web.stopLoading();host.removeView(web);(host.parent as? ViewGroup)?.removeView(host);web.destroy()}catch(_:Exception){}
        }
    }
}
