package com.margelo.nitro.pdfsdk

import android.content.Context
import android.view.View
import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip

/**
 * The view as React Native sees it. It holds the surface and passes on what
 * comes from JavaScript; everything that happens per frame stays inside the
 * surface.
 */
@DoNotStrip
@Keep
class HybridPdfView(context: Context) : HybridNativePdfViewSpec() {
  private val surface = PdfSurface(context)

  override val view: View = surface

  /**
   * What a screen point is worth in pixels here.
   *
   * An Android view is measured in pixels and iOS is measured in points, and
   * the API this sits behind promises points. Without this, the same document
   * on the same screen reports a zoom three times larger on one platform than
   * on the other.
   */
  private val density = context.resources.displayMetrics.density

  /** Set while props are arriving, so the document and the page are read together. */
  private var updating = false
  private var needsLoad = false

  init {
    surface.onLoad = { pageCount, width, height ->
      onLoad?.invoke(PdfLoadEvent(pageCount.toDouble(), width.toDouble(), height.toDouble()))
    }
    surface.onPageChange = { page, pageCount ->
      onPageChange?.invoke(PdfPageEvent(page.toDouble(), pageCount.toDouble()))
    }
    surface.onZoom = { zoom, scale ->
      onZoom?.invoke(PdfZoomEvent(zoom.toDouble(), (scale / density).toDouble()))
    }
    surface.onFailure = { failure ->
      onError?.invoke(PdfErrorEvent(failure.code.reported(), failure.message))
    }
    surface.onTap = { x, y, page ->
      onTap?.invoke(PdfTapEvent((x / density).toDouble(), (y / density).toDouble(), page.toDouble()))
    }
  }

  // ─── Props ──────────────────────────────────────────────────────────────────

  override var source: PdfViewSource = PdfViewSource("", null, null, null)
    set(value) {
      field = value
      load()
    }

  override var page: Double = 0.0
    set(value) {
      field = value
      load()
    }

  override var fit: PdfFit = PdfFit.AUTO
    set(value) {
      field = value
      surface.setFit(policy(value))
    }

  /**
   * Zero means the viewer decides, on all three of these.
   *
   * They are not optional because React hands native a `null` when a property
   * is taken away and nitro reads only `undefined` as empty, so an optional
   * number would throw in the bridge the first time a caller passed a value
   * and then stopped. The wrapper in JavaScript fills the gaps.
   */
  override var minZoom: Double = 0.0
    set(value) {
      field = value
      surface.setZoomRange(asked(value), asked(maxZoom))
    }

  override var maxZoom: Double = 0.0
    set(value) {
      field = value
      surface.setZoomRange(asked(minZoom), asked(value))
    }

  override var doubleTapZoom: Double = 0.0
    set(value) {
      field = value
      surface.setDoubleTapZoom(asked(value))
    }

  override var pageGap: Double = PdfDocumentLayout.DEFAULT_GAP.toDouble()
    set(value) {
      field = value
      surface.setPageGap(value.toFloat())
    }

  override var backdropColor: Double = 0.0
    set(value) {
      field = value
      surface.setBackdropColor(if (value == 0.0) null else value.toLong().toInt())
    }

  /** iOS draws scroll indicators; this view draws none, so there is none to hide. */
  override var scrollIndicators: Boolean = true

  private fun asked(value: Double): Float? = if (value > 0.0) value.toFloat() else null

  override var onLoad: ((event: PdfLoadEvent) -> Unit)? = null
  override var onPageChange: ((event: PdfPageEvent) -> Unit)? = null
  override var onZoom: ((event: PdfZoomEvent) -> Unit)? = null
  override var onError: ((event: PdfErrorEvent) -> Unit)? = null
  override var onTap: ((event: PdfTapEvent) -> Unit)? = null

  /**
   * The document and the page arrive as separate properties, so opening on the
   * first would open the old page of the new document. React updates props in
   * one batch, and they are read once the batch has landed.
   */
  override fun beforeUpdate() {
    updating = true
  }

  override fun afterUpdate() {
    updating = false
    if (needsLoad) load()
  }

  private fun load() {
    if (updating) {
      needsLoad = true
      return
    }
    needsLoad = false

    val uri = source.uri
    if (uri.isEmpty()) return
    surface.load(
      uri = uri,
      headers = source.headers ?: emptyMap(),
      password = source.password,
      cache = source.cache ?: true,
      page = if (page.isFinite()) page.toInt().coerceAtLeast(0) else 0,
    )
  }

  override fun onDropView() {
    surface.release()
  }

  // ─── Methods ────────────────────────────────────────────────────────────────

  /**
   * Nitro calls these straight from JavaScript's own thread: there is no hop to
   * the screen's thread anywhere in its view layer. A view may only be touched
   * from the thread that made it, and JavaScript is blocked for as long as the
   * work takes. So the work is handed to the view's own queue and the call
   * returns at once.
   */
  override fun goToPage(page: Double, animated: Boolean) {
    if (!page.isFinite()) return
    surface.post { surface.goToPage(page.toInt().coerceAtLeast(0), animated) }
  }

  override fun setZoom(zoom: Double, animated: Boolean) {
    if (!zoom.isFinite() || zoom <= 0.0) return
    surface.post { surface.setZoom(zoom.toFloat(), animated) }
  }

  /** The last measurement the view made, which it takes on its own thread. */
  override fun coverage(): Double = surface.lastCoverage.toDouble()

  /** The viewer's own idea of a fit, which knows nothing about the bridge. */
  private fun policy(fit: PdfFit): PdfFitPolicy = when (fit) {
    PdfFit.WIDTH -> PdfFitPolicy.WIDTH
    PdfFit.HEIGHT -> PdfFitPolicy.HEIGHT
    PdfFit.PAGE -> PdfFitPolicy.PAGE
    else -> PdfFitPolicy.AUTO
  }

  private fun PdfFailureCode.reported(): PdfErrorCode = when (this) {
    PdfFailureCode.NOT_FOUND -> PdfErrorCode.NOTFOUND
    PdfFailureCode.PASSWORD -> PdfErrorCode.PASSWORD
    PdfFailureCode.UNSUPPORTED -> PdfErrorCode.UNSUPPORTED
    PdfFailureCode.NETWORK -> PdfErrorCode.NETWORK
    PdfFailureCode.UNKNOWN -> PdfErrorCode.UNKNOWN
  }
}
