package ptq.mpga.ptqbookpageview.widget

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color as AndroidColor
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.widget.FrameLayout
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/** Android host for the upstream PTQBookPageView geometry used by Flutter's AndroidView. */
class PTQBookPageCurlNativeView(
    context: Context,
    private val sendEvent: (String, Any?) -> Unit,
) : FrameLayout(context) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val decoder = Executors.newSingleThreadExecutor { task ->
        Thread(task, "ptq-page-image-decoder").apply { isDaemon = true }
    }
    private val pageBitmaps = mutableStateMapOf<Int, Bitmap>()
    private val rightLeafBitmaps = mutableStateMapOf<Int, Bitmap>()
    private val spreadState = mutableStateOf(false)
    private val tapToTurnState = mutableStateOf(true)
    private val pageCountState = mutableIntStateOf(1)
    private val pageIndexState = mutableIntStateOf(0)
    private val renderedPageIndexState = mutableIntStateOf(-1)
    private val paperColorState = mutableIntStateOf(AndroidColor.WHITE)
    private val loadingPages = mutableSetOf<Int>()
    private val requestedPages = mutableSetOf<Int>()
    private val pageGenerationIds = mutableMapOf<Int, Int>()
    private var nextPageGeneration = 0
    private var refreshPTQPages: (() -> Unit)? = null
    private var pendingProgrammaticDirection: Int? = null
    private var announcedReadyIndex: Int? = null
    private var turnInProgress = false
    private var disposed = false
    private val imageRegions = mutableMapOf<Int, List<android.graphics.RectF>>()
    private val holdSlop = ViewConfiguration.get(context).scaledTouchSlop.toFloat()
    private var holdX = 0f
    private var holdY = 0f
    private var holdDownTime = 0L
    private var holdPage = -1
    private var holdConsumed = false
    private val selectOnHold = Runnable {
        if (disposed || holdPage < 0 || readyIndex() != holdPage ||
            width <= 0 || height <= 0 || !isAttachedToWindow) return@Runnable
        // The same pointer must not release into PTQ's tap/turn recognizer.
        holdConsumed = true
        val cancel = MotionEvent.obtain(holdDownTime, SystemClock.uptimeMillis(),
            MotionEvent.ACTION_CANCEL, holdX, holdY, 0)
        composeView.dispatchTouchEvent(cancel)
        cancel.recycle()
        sendEvent("textHold", mapOf("index" to holdPage, "x" to holdX / width, "y" to holdY / height))
    }

    private val composeView = ComposeView(context).apply {
        setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnDetachedFromWindow)
        setContent {
            val pageCount = pageCountState.intValue.coerceAtLeast(1)
            val pageIndex = pageIndexState.intValue.coerceIn(0, pageCount - 1)
            val opaqueColor = opaqueArgb(paperColorState.intValue)
            val paper = Color(opaqueColor)
            val isSpread = spreadState.value
            // The Flutter index can change while this Compose tree is still
            // rendering its previous page. Do not accept a tap until the PTQ
            // bitmap controller has caught up with the visible index.
            val readyForTurn = renderedPageIndexState.intValue == pageIndex &&
                hasTurnBitmaps(pageIndex, pageCount)
            val state = remember(pageCount, pageIndex) {
                PTQBookPageViewState(pageCount = pageCount, currentPage = pageIndex)
            }

            PTQBookPageView(
                state = state,
                directBitmapAt = { pageBitmaps[it] },
                directLeafBitmapAt = { index, right ->
                    if (right) rightLeafBitmaps[index] else pageBitmaps[index]
                },
                onSynchronizedPage = {
                    renderedPageIndexState.intValue = it
                },
                config = PTQBookPageViewConfig(
                    pageColor = paper,
                    disabled = !readyForTurn,
                    isSpread = isSpread,
                ),
            ) {
                onTurnStarted {
                    if (!turnInProgress) {
                        turnInProgress = true
                        announcedReadyIndex = null
                        sendEvent("turnStarted", null)
                    }
                }

                onTurnSettled {
                    if (turnInProgress) {
                        turnInProgress = false
                        sendEvent("turnFinished", null)
                        val current = pageIndexState.intValue
                        if (renderedPageIndexState.intValue == current && hasTurnBitmaps(current, pageCount)) {
                            announcedReadyIndex = current
                            sendEvent("ready", mapOf("index" to current))
                        }
                    }
                }

                onTurnPageRequest { currentPage, isNext, success ->
                    val direction = if (isNext) 1 else -1
                    if (!success) {
                        sendEvent("turnLimit", mapOf("direction" to direction))
                    } else {
                        val committedIndex = (currentPage + direction).coerceIn(0, pageCount - 1)
                        pageIndexState.intValue = committedIndex
                        trimPageCache(committedIndex, pageCount)
                        sendEvent("pageChanged", mapOf("index" to committedIndex))
                    }
                }

                tapBehavior { _, rightDown, touchPoint ->
                    val requestedDirection = pendingProgrammaticDirection
                    if (requestedDirection != null) {
                        pendingProgrammaticDirection = null
                        requestedDirection > 0 // PTQ returns true for next, false for previous.
                    } else {
                        val width = rightDown.x.coerceAtLeast(1f)
                        val height = rightDown.y.coerceAtLeast(1f)
                        when {
                            imageRegions[pageIndex]?.any { it.contains(touchPoint.x / width, touchPoint.y / height) } == true -> {
                                sendEvent("imageTap", mapOf("index" to pageIndex, "x" to touchPoint.x / width, "y" to touchPoint.y / height)); null
                            }
                            !tapToTurnState.value -> { sendEvent("centerTap", null); null }
                            touchPoint.x < width * 0.30f || (!isSpread && touchPoint.y < height * 0.30f) -> false
                            touchPoint.x > width * 0.70f || (!isSpread && touchPoint.y > height * 0.70f) -> true
                            else -> {
                                sendEvent("centerTap", null)
                                null
                            }
                        }
                    }
                }

                contents { requestedPage, refresh ->
                    val image = pageBitmaps[requestedPage]
                    val displayImage = remember(image) { image?.asImageBitmap() }
                    val rightImage = rightLeafBitmaps[requestedPage]
                    val displayRight = remember(rightImage) { rightImage?.asImageBitmap() }
                    Box(
                        Modifier
                            .fillMaxSize()
                            .background(paper),
                    ) {
                        if (isSpread && displayImage != null && displayRight != null) {
                            Row(Modifier.fillMaxSize()) {
                                Image(displayImage, null, Modifier.weight(1f).fillMaxSize(), contentScale = ContentScale.FillBounds)
                                Image(displayRight, null, Modifier.weight(1f).fillMaxSize(), contentScale = ContentScale.FillBounds)
                            }
                        } else if (displayImage != null) {
                            Image(
                                bitmap = displayImage,
                                contentDescription = null,
                                modifier = Modifier.fillMaxSize(),
                                contentScale = ContentScale.FillBounds,
                            )
                        }
                    }
                    SideEffect {
                        refreshPTQPages = refresh
                        if (image == null) requestPage(requestedPage, pageCount)
                    }
                }
            }
            SideEffect {
                if (!readyForTurn || turnInProgress) {
                    announcedReadyIndex = null
                } else if (announcedReadyIndex != pageIndex) {
                    announcedReadyIndex = pageIndex
                    sendEvent("ready", mapOf("index" to pageIndex))
                }
            }
        }
    }

    init {
        clipChildren = true
        clipToPadding = true
        addView(
            composeView,
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
        )
        setBackgroundColor(AndroidColor.WHITE)
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        val action = event.actionMasked
        if (action == MotionEvent.ACTION_DOWN) {
            mainHandler.removeCallbacks(selectOnHold)
            holdConsumed = false
            holdPage = -1
            val current = readyIndex()
            if (current != null && width > 0 && height > 0 &&
                imageRegions[current]?.any { it.contains(event.x / width, event.y / height) } != true) {
                holdX = event.x
                holdY = event.y
                holdDownTime = event.downTime
                holdPage = current
                mainHandler.postDelayed(selectOnHold, ViewConfiguration.getLongPressTimeout().toLong())
            }
        } else if (holdConsumed) {
            if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) holdConsumed = false
            return true
        } else if (action != MotionEvent.ACTION_MOVE ||
            kotlin.math.abs(event.x - holdX) > holdSlop ||
            kotlin.math.abs(event.y - holdY) > holdSlop) {
            mainHandler.removeCallbacks(selectOnHold)
            holdPage = -1
        }
        return super.dispatchTouchEvent(event)
    }

    fun setImageRegions(index: Int, regions: List<*>) {
        imageRegions[index] = regions.take(256).mapNotNull { item ->
            val rect = (item as? Map<*, *>)?.get("rect") as? List<*> ?: return@mapNotNull null
            if (rect.size != 4) return@mapNotNull null
            val values = rect.map { (it as? Number)?.toFloat() ?: return@mapNotNull null }
            if (values.any { !it.isFinite() } || values[2] <= values[0] || values[3] <= values[1]) return@mapNotNull null
            android.graphics.RectF(values[0], values[1], values[2], values[3])
        }
        imageRegions.keys.removeAll { kotlin.math.abs(it - pageIndexState.intValue) > 3 }
    }

    fun updateState(pageCount: Int, index: Int, paperColor: Int, isSpread: Boolean = false, tapToTurn: Boolean = true) {
        if (disposed) return
        tapToTurnState.value = tapToTurn
        val safeCount = pageCount.coerceAtLeast(1)
        val safeIndex = index.coerceIn(0, safeCount - 1)
        if (spreadState.value != isSpread) {
            pageBitmaps.clear()
            rightLeafBitmaps.clear()
            renderedPageIndexState.intValue = -1
            announcedReadyIndex = null
        }
        spreadState.value = isSpread
        if (safeIndex != pageIndexState.intValue) {
            renderedPageIndexState.intValue = -1
            announcedReadyIndex = null
        }
        pageCountState.intValue = safeCount
        pageIndexState.intValue = safeIndex
        paperColorState.intValue = opaqueArgb(paperColor)
        setBackgroundColor(paperColorState.intValue)
        trimPageCache(safeIndex, safeCount)
    }

    fun setPageImage(index: Int, pngBytes: ByteArray, onComplete: (Boolean, String?) -> Unit) {
        if (disposed) {
            onComplete(false, "view_disposed")
            return
        }
        if (index !in 0 until pageCountState.intValue) {
            onComplete(false, "page_index_out_of_range")
            return
        }
        // Flutter can rasterize the same page index again after typography,
        // theme, background, or chapter content changes. Always replace it.
        val generation = ++nextPageGeneration
        pageGenerationIds[index] = generation
        loadingPages.add(index)
        val splitLeaves = spreadState.value

        decoder.execute {
            // Split once off the UI thread. Keep only the two half-size
            // textures, rather than a full spread plus redundant leaf copies.
            val decoded = try {
                BitmapFactory.decodeByteArray(pngBytes, 0, pngBytes.size)?.let { bitmap ->
                    if (splitLeaves && bitmap.width >= 2) {
                        val half = bitmap.width / 2
                        val left = Bitmap.createBitmap(bitmap, 0, 0, half, bitmap.height)
                        val right = Bitmap.createBitmap(bitmap, half, 0, bitmap.width - half, bitmap.height)
                        bitmap.recycle()
                        left to right
                    } else bitmap to null
                }
            } catch (error: Exception) {
                null
            }
            mainHandler.post {
                if (disposed) {
                    decoded?.first?.recycle()
                    decoded?.second?.recycle()
                    onComplete(false, "view_disposed")
                    return@post
                }
                if (pageGenerationIds[index] != generation || splitLeaves != spreadState.value) {
                    decoded?.first?.recycle()
                    decoded?.second?.recycle()
                    onComplete(true, null)
                    return@post
                }
                loadingPages.remove(index)
                if (decoded == null) {
                    requestedPages.remove(index)
                    onComplete(false, "invalid_png")
                    return@post
                }
                if (index in (pageIndexState.intValue - 2)..(pageIndexState.intValue + 2)) {
                    decoded.second?.let { rightLeafBitmaps[index] = it }
                    pageBitmaps[index] = decoded.first
                    trimPageCache(pageIndexState.intValue, pageCountState.intValue)
                    refreshPTQPages?.invoke()
                } else {
                    decoded.first.recycle()
                    decoded.second?.recycle()
                }
                requestedPages.remove(index)
                onComplete(true, null)
            }
        }
    }

    fun turn(direction: Int, startY: Double, onComplete: (Boolean) -> Unit) {
        if (disposed || turnInProgress || direction !in -1..1 || direction == 0) {
            onComplete(false)
            return
        }
        val target = pageIndexState.intValue + direction
        if (target !in 0 until pageCountState.intValue) {
            sendEvent("turnLimit", mapOf("direction" to direction))
            onComplete(false)
            return
        }
        if (renderedPageIndexState.intValue != pageIndexState.intValue ||
            !hasTurnBitmaps(pageIndexState.intValue, pageCountState.intValue)) {
            requestMissingTurnBitmaps(pageIndexState.intValue, pageCountState.intValue)
            onComplete(false)
            return
        }
        if (!isAttachedToWindow || width <= 0 || height <= 0) {
            onComplete(false)
            return
        }

        pendingProgrammaticDirection = direction
        val x = if (direction > 0) width * 0.94f else width * 0.06f
        val minY = height / 170f + 1f
        val y = (startY.coerceIn(0.0, 1.0) * height).toFloat()
            .coerceIn(minY, (height - 1f).coerceAtLeast(minY))
        val downTime = SystemClock.uptimeMillis()
        val down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, x, y, 0)
        down.source = InputDevice.SOURCE_TOUCHSCREEN
        val acceptedDown = composeView.dispatchTouchEvent(down)
        down.recycle()

        mainHandler.postDelayed({
            if (disposed) {
                pendingProgrammaticDirection = null
                onComplete(false)
                return@postDelayed
            }
            val upTime = SystemClock.uptimeMillis()
            val up = MotionEvent.obtain(downTime, upTime, MotionEvent.ACTION_UP, x, y, 0)
            up.source = InputDevice.SOURCE_TOUCHSCREEN
            val acceptedUp = composeView.dispatchTouchEvent(up)
            up.recycle()
            if (!acceptedDown || !acceptedUp) pendingProgrammaticDirection = null
            onComplete(acceptedDown && acceptedUp)
        }, 16L)
    }

    fun readyIndex(): Int? {
        val index = pageIndexState.intValue
        return index.takeIf {
            !turnInProgress && announcedReadyIndex == it && renderedPageIndexState.intValue == it &&
                hasTurnBitmaps(it, pageCountState.intValue)
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        mainHandler.removeCallbacks(selectOnHold)
        turnInProgress = false
        pendingProgrammaticDirection = null
        refreshPTQPages = null
        requestedPages.clear()
        loadingPages.clear()
        decoder.shutdownNow()
    }

    private fun hasTurnBitmaps(current: Int, count: Int): Boolean {
        val first = maxOf(0, current - 1)
        val last = minOf(count - 1, current + 1)
        return (first..last).all {
            pageBitmaps.containsKey(it) && (!spreadState.value || rightLeafBitmaps.containsKey(it))
        }
    }

    private fun requestMissingTurnBitmaps(current: Int, count: Int) {
        val first = maxOf(0, current - 1)
        val last = minOf(count - 1, current + 1)
        (first..last).filterNot(pageBitmaps::containsKey).forEach { requestPage(it, count) }
    }

    private fun requestPage(index: Int, count: Int) {
        if (index !in 0 until count || pageBitmaps.containsKey(index) || index in loadingPages || !requestedPages.add(index)) return
        sendEvent("pageNeeded", mapOf("index" to index))
    }

    private fun trimPageCache(current: Int, count: Int) {
        val first = maxOf(0, current - 2)
        val last = minOf(count - 1, current + 2)
        pageBitmaps.keys.toList().filter { it !in first..last }.forEach { index ->
            pageBitmaps.remove(index)
            rightLeafBitmaps.remove(index)
        }
        pageGenerationIds.keys.toList().filter { it !in first..last && it !in loadingPages }.forEach { index ->
            pageGenerationIds.remove(index)
        }
        requestedPages.removeAll { it !in first..last }
    }

    private fun opaqueArgb(color: Int): Int = color or AndroidColor.BLACK
}
