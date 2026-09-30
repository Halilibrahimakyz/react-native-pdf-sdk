package com.margelo.nitro.pdfsdk

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.widget.OverScroller
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.roundToInt

/**
 * The viewer itself: one view that owns the document, the zoom, the movement
 * and the drawing.
 *
 * Keeping all of that in one place is the point. When the transform lived in
 * one thread and the layout of what it moved in another, the two could not be
 * changed together, and every change of zoom showed a frame or two of the
 * document in the wrong place. Here the zoom, the tile grid and the drawing are
 * read from the same numbers in the same pass.
 */
class PdfSurface(context: Context) : View(context) {

  val viewport = PdfViewport()

  var onLoad: ((pageCount: Int, width: Float, height: Float) -> Unit)? = null
  /** Zero based, so it matches the page property. A caller adds one to show it. */
  var onPageChange: ((page: Int, pageCount: Int) -> Unit)? = null
  /** The zoom as a multiple of what the document opened at, and what that is. */
  var onZoom: ((zoom: Float, scale: Float) -> Unit)? = null
  var onFailure: ((failure: PdfFailure) -> Unit)? = null
  /** A tap that was not part of a double tap, and the page under it. */
  var onTap: ((x: Float, y: Float, page: Int) -> Unit)? = null

  private val main = Handler(Looper.getMainLooper())
  private val loader = Executors.newSingleThreadExecutor { runnable ->
    Thread(runnable, "pdf-sdk-loader")
  }

  private var source: PdfPageSource? = null
  private var store: PdfTileStore? = null
  private var layout = PdfDocumentLayout(emptyList())

  private var uri: String? = null
  private var headers: Map<String, String> = emptyMap()
  private var password: String? = null
  private var cache = true
  private var openAtPage = 0
  private var pageGap = PdfDocumentLayout.DEFAULT_GAP
  private var pageSizes: List<PageSize> = emptyList()
  private var reportedPage = -1
  private var reportedZoom = 0f
  private var lastZoomAt = 0L
  private var zoomQueued = false

  /** Which tiles are wanted and where they go: arithmetic, tested on its own. */
  private val grid = TileGrid(TILE_PX, LEVEL_DRIFT, LOOKAHEAD_SECONDS)

  private val tilePaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
  private val pagePaint = Paint().apply { color = Color.WHITE }
  private val destination = RectF()

  private val scroller = OverScroller(context)
  private var zoomAnimator: ValueAnimator? = null
  private var lastEnsure = 0L
  private var ensureQueued = false
  private var velocityX = 0f
  private var velocityY = 0f
  private var lastFlingAt = 0L

  private val configuration = ViewConfiguration.get(context)
  private val touchSlop = configuration.scaledTouchSlop.toFloat()
  private val doubleTapSlop = configuration.scaledDoubleTapSlop.toFloat()
  private val doubleTapTimeout = ViewConfiguration.getDoubleTapTimeout().toLong()
  private var downX = 0f
  private var downY = 0f
  private var wasDragged = false
  private var lastTapAt = 0L
  private var lastTapX = 0f
  private var lastTapY = 0f

  // ─── Loading ────────────────────────────────────────────────────────────────

  fun load(
    uri: String,
    headers: Map<String, String>,
    password: String?,
    cache: Boolean,
    page: Int,
  ) {
    val same = uri == this.uri && password == this.password && source != null
    this.headers = headers
    this.cache = cache

    if (same) {
      if (page != openAtPage) {
        openAtPage = page
        goToPage(page, animated = false)
      }
      return
    }

    this.uri = uri
    this.password = password
    this.openAtPage = page
    reportedPage = -1
    reportedZoom = 0f

    closeDocument()
    invalidate()
    if (uri.isEmpty()) return

    loader.execute {
      val opened = try {
        PdfPageSource(PdfSourceLoader.open(context, uri, headers, cache), password)
      } catch (error: Throwable) {
        report(error)
        return@execute
      }

      val first = try {
        opened.pageSize(0)
      } catch (error: Throwable) {
        opened.close()
        report(error)
        return@execute
      }

      val size = PageSize(first.first, first.second)
      val tiles = PdfTileStore(
        source = opened,
        onTileReady = { postInvalidateOnAnimation() },
        onError = { error -> report(error) },
      )

      main.post {
        if (this.uri != uri || !isAttachedToWindow) {
          tiles.close()
          opened.close()
          return@post
        }
        source = opened
        store = tiles
        // Every page is taken to be the size of the first one until it has been
        // measured, which is true of almost every document and lets the first
        // page be drawn now rather than after the whole file has been walked.
        pageSizes = List(opened.pageCount) { size }
        layout = PdfDocumentLayout.of(size, opened.pageCount, pageGap)
        viewport.setDocument(layout)
        if (viewport.ready) {
          viewport.reset()
          scrollToPage(openAtPage)
          ensureTiles(force = true)
        }
        onLoad?.invoke(opened.pageCount, size.width, size.height)
        invalidate()
      }

      measureRemainingPages(opened, uri, size)
    }
  }

  private fun report(error: Throwable) {
    val failure = PdfFailure.from(error)
    main.post { onFailure?.invoke(failure) }
  }

  /**
   * Measures the pages that were assumed to be the size of the first.
   *
   * Done after the document is on screen rather than before: opening a page is
   * where the platform parses it, and on a large drawing that is a third of a
   * second each. Almost every document has pages of one size, so this usually
   * confirms what is already drawn and changes nothing.
   */
  private fun measureRemainingPages(source: PdfPageSource, uri: String, first: PageSize) {
    if (source.pageCount <= 1) return

    val sizes = ArrayList<PageSize>(source.pageCount)
    sizes.add(first)
    var differs = false

    for (index in 1 until source.pageCount) {
      if (this.uri != uri) return
      val size = try {
        val measured = source.pageSize(index)
        PageSize(measured.first, measured.second)
      } catch (error: Throwable) {
        first
      }
      if (size != first) differs = true
      sizes.add(size)
    }

    if (!differs) return

    main.post {
      if (this.uri != uri || this.source !== source) return@post
      pageSizes = sizes
      applyLayout(PdfDocumentLayout(sizes, pageGap))
    }
  }

  /**
   * Puts a corrected layout in place without moving what the reader is looking
   * at: the page they are on stays where it is on screen, and the pages below
   * it move instead.
   */
  private fun applyLayout(next: PdfDocumentLayout) {
    val anchor = layout.pageAt(viewport.screenToDocumentY(0f))
    val before = layout.pages.getOrNull(anchor)?.y ?: 0f
    val after = next.pages.getOrNull(anchor)?.y ?: 0f

    layout = next
    viewport.setDocument(next)
    viewport.panBy(0f, -(after - before) * viewport.scale)
    grid.clear()
    ensureTiles(force = true)
    invalidate()
  }

  fun scrollToPage(page: Int) {
    val box = layout.pages.getOrNull(page) ?: return
    if (!viewport.ready) return
    viewport.moveTo(viewport.offsetX, -box.y * viewport.scale)
    ensureTiles(force = true)
    invalidate()
  }

  // ─── What the reader is allowed to do ──────────────────────────────────────

  fun setFit(policy: PdfFitPolicy) {
    if (viewport.fit == policy) return
    viewport.fit = policy
    refit()
  }

  fun setZoomRange(min: Float?, max: Float?) {
    if (viewport.minZoom == min && viewport.maxZoom == max) return
    viewport.minZoom = min
    viewport.maxZoom = max
    refit()
  }

  fun setDoubleTapZoom(value: Float?) {
    viewport.doubleTapZoom = value
  }

  fun setPageGap(gap: Float) {
    if (gap == pageGap) return
    pageGap = gap
    if (pageSizes.isEmpty()) return
    layout = PdfDocumentLayout(pageSizes, gap)
    viewport.setDocument(layout)
    refit()
  }

  fun setBackdropColor(color: Int?) {
    setBackgroundColor(color ?: Color.TRANSPARENT)
  }

  /** Something about the shape of the document changed, so it opens again. */
  private fun refit() {
    if (!viewport.ready || source == null) return
    val page = if (reportedPage < 0) openAtPage else reportedPage
    viewport.reset()
    scrollToPage(page)
    grid.clear()
    ensureTiles(force = true)
    invalidate()
  }

  // ─── What a caller can ask for ─────────────────────────────────────────────

  fun goToPage(page: Int, animated: Boolean) {
    val box = layout.pages.getOrNull(page) ?: return
    if (!viewport.ready) return
    zoomAnimator?.cancel()
    scroller.forceFinished(true)
    val target = -box.y * viewport.scale
    if (!animated) {
      scrollToPage(page)
      return
    }
    scroller.startScroll(
      viewport.offsetX.roundToInt(),
      viewport.offsetY.roundToInt(),
      0,
      (target - viewport.offsetY).roundToInt(),
      SCROLL_MS,
    )
    lastFlingAt = 0L
    postInvalidateOnAnimation()
  }

  /** `zoom` is a multiple of the zoom the document opened at. */
  fun setZoom(zoom: Float, animated: Boolean) {
    if (!viewport.ready) return
    val rest = viewport.restScale()
    val target = (rest * zoom).coerceIn(viewport.minScale(), viewport.maxScale())
    if (animated) {
      animateZoom(target, width / 2f, height / 2f)
      return
    }
    zoomAnimator?.cancel()
    scroller.forceFinished(true)
    viewport.zoomAround(width / 2f, height / 2f, target / viewport.scale)
    velocityX = 0f
    velocityY = 0f
    ensureTiles(force = true)
    invalidate()
  }

  fun release() {
    closeDocument()
    loader.shutdown()
  }

  private fun closeDocument() {
    zoomAnimator?.cancel()
    scroller.forceFinished(true)
    val currentStore = store
    val currentSource = source
    store = null
    source = null
    pageSizes = emptyList()
    layout = PdfDocumentLayout(emptyList())
    grid.clear()
    if (currentStore != null || currentSource != null) {
      loader.execute {
        currentStore?.close()
        currentSource?.close()
      }
    }
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    val current = uri ?: return
    if (source == null) {
      val page = openAtPage
      uri = null
      load(current, headers, password, cache, page)
    }
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    // An open PDF is a file handle and a page parsed into memory; a view that
    // has left the screen should be holding neither.
    val current = uri
    closeDocument()
    uri = current
  }

  // ─── Layout ─────────────────────────────────────────────────────────────────

  override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
    super.onSizeChanged(width, height, oldWidth, oldHeight)
    viewport.setView(width.toFloat(), height.toFloat())
    if (viewport.ready) {
      viewport.reset()
      scrollToPage(openAtPage)
      ensureTiles(force = true)
    }
  }

  // ─── Drawing ────────────────────────────────────────────────────────────────

  override fun onDraw(canvas: Canvas) {
    if (!viewport.ready) return

    // Kept inside our own bounds. React Native leaves overflow visible on the
    // views around us, so without this the document is drawn over whatever the
    // screen puts above and below it, the header included.
    canvas.clipRect(0, 0, width, height)

    val tiles = store ?: return
    val visible = viewport.visible()

    // The pages themselves: a white sheet each, with the page's own small
    // drawing on it until the tiles for this zoom arrive. What falls between
    // two pages is left to the background behind this view.
    for (page in layout.pagesIn(visible.y, visible.bottom)) {
      destination.set(
        viewport.documentToScreenX(page.x),
        viewport.documentToScreenY(page.y),
        viewport.documentToScreenX(page.right),
        viewport.documentToScreenY(page.bottom),
      )
      canvas.drawRect(destination, pagePaint)
      tiles.thumbnail(page.index)?.let { canvas.drawBitmap(it, null, destination, tilePaint) }
    }

    // What was drawn for the zoom before this one keeps the screen covered
    // until the tiles for this one have arrived.
    for (planned in grid.toDraw(viewport) { tiles.bitmap(it) != null }) {
      val bitmap = tiles.bitmap(planned.spec.key) ?: continue
      destination.set(
        planned.destination.left,
        planned.destination.top,
        planned.destination.right,
        planned.destination.bottom,
      )
      canvas.drawBitmap(bitmap, null, destination, tilePaint)
    }
  }

  // ─── Tiles ──────────────────────────────────────────────────────────────────

  private fun ensureTiles(force: Boolean = false) {
    val tiles = store ?: return
    if (!viewport.ready || layout.pageCount == 0) return
    // A movement that knows where it is going has already asked for what it
    // needs, and what is on screen on the way there is not worth a renderer.
    if (zoomAnimator?.isRunning == true) return

    val now = System.currentTimeMillis()
    if (!force && now - lastEnsure < ENSURE_MS) {
      if (!ensureQueued) {
        ensureQueued = true
        main.postDelayed({
          ensureQueued = false
          ensureTiles(force = true)
        }, ENSURE_MS)
      }
      return
    }
    lastEnsure = now

    grid.update(viewport, layout, velocityX, velocityY)

    val visible = viewport.visible()
    tiles.request(
      specs = grid.missing(viewport) { tiles.bitmap(it) != null },
      focusX = visible.x + visible.width / 2f,
      focusY = visible.y + visible.height / 2f,
    )

    // A page coming into view should never be a blank rectangle, so each one
    // on screen is asked for its own small drawing as well.
    for (page in layout.pagesIn(visible.y, visible.bottom)) {
      tiles.requestThumbnail(page.index, PageSize(page.width, page.height))
    }

    notifyPage(visible)
    notifyZoom()
    measureCoverage()
    invalidate()
  }

  /** The page the reader would say they are on: the one under the middle of the view. */
  private fun notifyPage(visible: PageRect) {
    val page = layout.pageAt(visible.y + visible.height / 2f)
    if (page == reportedPage) return
    reportedPage = page
    onPageChange?.invoke(page, layout.pageCount)
  }

  /**
   * The zoom, as a multiple of what the document opened at.
   *
   * Held to a few a second on purpose. A pinch changes the zoom on every frame,
   * and whoever is listening is almost certainly putting the number on the
   * screen, which means a React render per frame and a JavaScript thread on its
   * knees while the fingers are still moving. What matters is that the reader
   * sees a number that keeps up and that the last one is right, so one that
   * comes too early is sent late rather than dropped.
   */
  private fun notifyZoom() {
    if (!viewport.ready) return
    val rest = viewport.restScale()
    if (rest <= 0f) return
    val zoom = viewport.scale / rest
    if (abs(zoom - reportedZoom) <= reportedZoom * 0.005f) return

    val now = System.currentTimeMillis()
    if (now - lastZoomAt < ZOOM_REPORT_MS) {
      if (!zoomQueued) {
        zoomQueued = true
        main.postDelayed({
          zoomQueued = false
          notifyZoom()
        }, ZOOM_REPORT_MS)
      }
      return
    }

    lastZoomAt = now
    reportedZoom = zoom
    onZoom?.invoke(zoom, viewport.scale)
  }

  // ─── Movement ───────────────────────────────────────────────────────────────

  /**
   * Pinch, counted here.
   *
   * Android's own detector stops reporting once the fingers come within a few
   * centimetres of each other, so zooming out died halfway through the
   * movement and had to be started again. The distance between two fingers and
   * the point between them is all this needs, and neither has a lower bound.
   */
  private var isPinching = false
  private var lastSpan = 0f
  private var lastFocusX = 0f
  private var lastFocusY = 0f
  /** Set when a finger lands or leaves, so the span and focus are taken afresh. */
  private var focusIsStale = true

  private fun trackPinch(event: MotionEvent) {
    if (event.pointerCount < 2) {
      isPinching = false
      return
    }

    val span = hypot(event.getX(1) - event.getX(0), event.getY(1) - event.getY(0))
    val focusX = (event.getX(0) + event.getX(1)) / 2f
    val focusY = (event.getY(0) + event.getY(1)) / 2f

    // A finger landing or leaving moves the point between them and changes the
    // distance, neither of which the reader did. Taken as movement, that jump
    // threw the document sideways.
    if (!isPinching || focusIsStale) {
      isPinching = true
      focusIsStale = false
      lastSpan = span
      lastFocusX = focusX
      lastFocusY = focusY
      zoomAnimator?.cancel()
      scroller.forceFinished(true)
      return
    }

    if (span > 1f && lastSpan > 1f) {
      // Two fingers do two things at once: what is between them moves the
      // document, and how far apart they are zooms it.
      viewport.panBy(focusX - lastFocusX, focusY - lastFocusY)
      viewport.zoomAround(focusX, focusY, pinchGain(span / lastSpan))
      velocityX = 0f
      velocityY = 0f
      ensureTiles()
      invalidate()
    }

    lastSpan = span
    lastFocusX = focusX
    lastFocusY = focusY
  }

  private val gestureDetector = GestureDetector(context, object :
    GestureDetector.SimpleOnGestureListener() {

    override fun onDown(event: MotionEvent): Boolean {
      scroller.forceFinished(true)
      zoomAnimator?.cancel()
      velocityX = 0f
      velocityY = 0f
      return true
    }

    override fun onScroll(
      down: MotionEvent?,
      event: MotionEvent,
      distanceX: Float,
      distanceY: Float,
    ): Boolean {
      if (isPinching || event.pointerCount > 1) return false
      viewport.panBy(-distanceX, -distanceY)
      velocityX = -distanceX * 60f
      velocityY = -distanceY * 60f
      ensureTiles()
      invalidate()
      return true
    }

    override fun onFling(
      down: MotionEvent?,
      event: MotionEvent,
      speedX: Float,
      speedY: Float,
    ): Boolean {
      if (isPinching || event.pointerCount > 1) return false
      // The document carries on and slows down, so that crossing a sheet metres
      // wide, or a document of forty pages, is one flick rather than a dozen
      // drags.
      scroller.forceFinished(true)
      lastFlingAt = 0L
      scroller.fling(
        viewport.offsetX.roundToInt(),
        viewport.offsetY.roundToInt(),
        speedX.roundToInt(),
        speedY.roundToInt(),
        viewport.minOffsetX().roundToInt(),
        viewport.maxOffsetX().roundToInt(),
        viewport.minOffsetY().roundToInt(),
        viewport.maxOffsetY().roundToInt(),
      )
      velocityX = speedX
      velocityY = speedY
      postInvalidateOnAnimation()
      return true
    }
  })

  init {
    // A long press has no meaning on a document, and left on it interrupts a drag.
    gestureDetector.setIsLongpressEnabled(false)
  }

  /**
   * Double tap, counted here.
   *
   * The platform's gesture detector was given the job first and never called
   * back: its pinch detector claims the second tap as the start of a one
   * fingered zoom, and turning that off was not enough, with the events also
   * passing through react-native's own touch handling on the way here. Two taps
   * close together in time and place is a small enough thing to count.
   */
  private fun onDoubleTapAt(x: Float, y: Float) {
    animateZoom(viewport.doubleTapTarget(), x, y)
  }

  private fun pinchGain(factor: Float): Float {
    if (factor <= 0f) return 1f
    return Math.pow(factor.toDouble(), PINCH_GAIN.toDouble()).toFloat()
  }

  /**
   * Moves the zoom over a fifth of a second, and asks for where it lands before
   * it starts.
   *
   * The tiles of the zoom being arrived at take about as long to draw as the
   * movement takes to run, so asking for them at the start means they are there
   * as it lands. Without this the level changed in the middle of the movement,
   * the tiles were thrown away and asked for again, and the page stepped from
   * coarse to sharp two or three times on the way. That reads as a stuttering
   * animation even while every frame is drawn on time.
   */
  private fun animateZoom(target: Float, focusX: Float, focusY: Float) {
    zoomAnimator?.cancel()
    askForWhereItLands(target, focusX, focusY)

    val from = viewport.scale
    zoomAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
      duration = ZOOM_MS
      addUpdateListener { animation ->
        val progress = animation.animatedValue as Float
        val wanted = from + (target - from) * progress
        viewport.zoomAround(focusX, focusY, wanted / viewport.scale)
        invalidate()
      }
      addListener(object : AnimatorListenerAdapter() {
        override fun onAnimationEnd(animation: Animator) {
          grid.stopAiming()
          velocityX = 0f
          velocityY = 0f
          ensureTiles(force = true)
        }
      })
      start()
    }
  }

  /** The tiles of where a movement is going, worked out before it goes. */
  private fun askForWhereItLands(target: Float, focusX: Float, focusY: Float) {
    val tiles = store ?: return
    if (!viewport.ready) return

    val anchorX = viewport.screenToDocumentX(focusX)
    val anchorY = viewport.screenToDocumentY(focusY)
    val landing = PdfViewport().apply {
      fit = viewport.fit
      minZoom = viewport.minZoom
      maxZoom = viewport.maxZoom
      setDocument(layout)
      setView(width.toFloat(), height.toFloat())
      place(target, focusX - anchorX * target, focusY - anchorY * target)
    }

    grid.aim(landing.scale)
    grid.update(landing, layout)
    val visible = landing.visible()
    tiles.request(
      specs = grid.missing(landing) { tiles.bitmap(it) != null },
      focusX = visible.x + visible.width / 2f,
      focusY = visible.y + visible.height / 2f,
    )
    invalidate()
  }

  override fun computeScroll() {
    if (!scroller.computeScrollOffset()) {
      if (velocityX != 0f || velocityY != 0f) {
        velocityX = 0f
        velocityY = 0f
        ensureTiles(force = true)
      }
      return
    }

    // Measured from the movement itself rather than taken from the scroller,
    // which reports a speed without a direction.
    val now = System.nanoTime()
    val seconds = ((now - lastFlingAt) / 1_000_000_000.0).toFloat()
    val x = scroller.currX.toFloat()
    val y = scroller.currY.toFloat()
    if (lastFlingAt != 0L && seconds > 0.001f) {
      velocityX = (x - viewport.offsetX) / seconds
      velocityY = (y - viewport.offsetY) / seconds
    }
    lastFlingAt = now

    viewport.moveTo(x, y)
    ensureTiles()
    postInvalidateOnAnimation()
    invalidate()
  }

  @Suppress("ClickableViewAccessibility")
  override fun onTouchEvent(event: MotionEvent): Boolean {
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        // A drag on the document is the document's own, not a list's underneath it.
        parent?.requestDisallowInterceptTouchEvent(true)
        downX = event.x
        downY = event.y
        wasDragged = false
      }
      MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_POINTER_UP -> {
        focusIsStale = true
        wasDragged = true
      }
      MotionEvent.ACTION_MOVE -> {
        if (!wasDragged &&
          (abs(event.x - downX) > touchSlop || abs(event.y - downY) > touchSlop)
        ) {
          wasDragged = true
        }
        trackPinch(event)
      }
      MotionEvent.ACTION_UP -> {
        countTap(event)
        isPinching = false
      }
      MotionEvent.ACTION_CANCEL -> isPinching = false
    }

    gestureDetector.onTouchEvent(event)

    if (event.actionMasked == MotionEvent.ACTION_UP ||
      event.actionMasked == MotionEvent.ACTION_CANCEL
    ) {
      if (scroller.isFinished) {
        velocityX = 0f
        velocityY = 0f
        ensureTiles(force = true)
      }
      parent?.requestDisallowInterceptTouchEvent(false)
    }
    return true
  }

  private fun countTap(event: MotionEvent) {
    if (wasDragged || isPinching) {
      lastTapAt = 0L
      return
    }

    val now = event.eventTime
    val nearLast = abs(event.x - lastTapX) < doubleTapSlop &&
      abs(event.y - lastTapY) < doubleTapSlop
    if (lastTapAt != 0L && now - lastTapAt <= doubleTapTimeout && nearLast) {
      lastTapAt = 0L
      removeCallbacks(reportTap)
      onDoubleTapAt(event.x, event.y)
      return
    }

    lastTapAt = now
    lastTapX = event.x
    lastTapY = event.y

    // A single tap is only a single tap once the moment for a second one has
    // passed, so whoever is listening is told then rather than now.
    if (onTap != null) {
      tapX = event.x
      tapY = event.y
      removeCallbacks(reportTap)
      postDelayed(reportTap, doubleTapTimeout)
    }
  }

  private var tapX = 0f
  private var tapY = 0f
  private val reportTap = Runnable {
    if (viewport.ready) {
      onTap?.invoke(tapX, tapY, layout.pageAt(viewport.screenToDocumentY(tapY)))
    }
  }

  /**
   * How much of what is on screen has been drawn for the zoom it is shown at,
   * worked out whenever the tiles are, and read from anywhere.
   */
  @Volatile
  var lastCoverage = 0f
    private set

  private fun measureCoverage() {
    val tiles = store
    lastCoverage = if (tiles == null) 0f
    else grid.coverage(viewport, layout) { tiles.bitmap(it) != null }
  }

  private companion object {
    const val TILE_PX = 512
    const val LEVEL_DRIFT = 1.45f
    const val LOOKAHEAD_SECONDS = 0.3f
    const val ENSURE_MS = 60L

    /** How often the zoom is worth telling anyone about. */
    const val ZOOM_REPORT_MS = 120L
    const val ZOOM_MS = 220L
    const val SCROLL_MS = 260
    const val PINCH_GAIN = 1.8f
  }
}
