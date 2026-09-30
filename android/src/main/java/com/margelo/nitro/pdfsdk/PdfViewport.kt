package com.margelo.nitro.pdfsdk

import kotlin.math.max
import kotlin.math.min

/** A rectangle of the document, in points. */
data class PageRect(val x: Float, val y: Float, val width: Float, val height: Float) {
  val right get() = x + width
  val bottom get() = y + height
}

/**
 * How a document is sized when it opens, which is also what a zoom of 1 means.
 *
 * The twin of the `PdfFit` union in the JavaScript API, kept apart from it so
 * that everything deciding what the reader sees stays free of the bridge and
 * can be tested on the JVM.
 */
enum class PdfFitPolicy {
  AUTO,
  WIDTH,
  HEIGHT,
  PAGE,
}

/**
 * Where the document sits on the screen, and everything that follows from it.
 *
 * Deliberately free of Android: this is the arithmetic that decides what the
 * reader sees, and it is worth being able to test on its own. `scale` is screen
 * pixels to the document point, and the offsets are where the document's top
 * left corner sits in the view, so a point maps to `point * scale + offset`.
 */
class PdfViewport {
  /** The document's bounding box: the widest page, and every page stacked up. */
  var contentWidth = 0f
    private set
  var contentHeight = 0f
    private set

  /** The first page, which is what decides how the document opens. */
  var firstPage = PageSize(0f, 0f)
    private set

  var viewWidth = 0f
    private set
  var viewHeight = 0f
    private set

  var scale = 1f
    private set
  var offsetX = 0f
    private set
  var offsetY = 0f
    private set

  /** What the document is fitted to when it opens. */
  var fit = PdfFitPolicy.AUTO

  /** How far it may be zoomed, in multiples of the zoom it opened at. */
  var minZoom: Float? = null
  var maxZoom: Float? = null
  var doubleTapZoom: Float? = null

  fun setDocument(width: Float, height: Float, firstPage: PageSize) {
    contentWidth = width
    contentHeight = height
    this.firstPage = firstPage
  }

  fun setDocument(layout: PdfDocumentLayout) {
    setDocument(layout.width, layout.height, layout.firstPage)
  }

  /** A document of a single page, which is what most of the tests are about. */
  fun setPage(width: Float, height: Float) {
    setDocument(width, height, PageSize(width, height))
  }

  fun setView(width: Float, height: Float) {
    viewWidth = width
    viewHeight = height
  }

  val ready: Boolean
    get() = contentWidth > 0f && contentHeight > 0f && viewWidth > 0f && viewHeight > 0f

  /**
   * The zoom that fits the document's width.
   *
   * Width rather than the whole document: a document is read by scrolling, and
   * fitting twelve pages on a phone would show twelve stamps.
   */
  fun widthScale(): Float {
    if (!ready) return 1f
    return viewWidth / contentWidth
  }

  /** The zoom that fills the height with the first page. */
  fun heightScale(): Float {
    if (!ready || firstPage.height <= 0f) return widthScale()
    return viewHeight / firstPage.height
  }

  /** The zoom that shows the whole of the first page. */
  fun pageScale(): Float = min(widthScale(), heightScale())

  /**
   * The zoom a document opens at.
   *
   * Left to itself it fits the width, unless the first page is a strip rather
   * than a page: the formwork plans of a building arrive as one sheet thirteen
   * metres wide, and fitted to the width that is a line across the middle of
   * the screen. Those open filling the height instead, read by panning
   * sideways.
   */
  fun restScale(): Float {
    if (!ready) return 1f
    return when (fit) {
      PdfFitPolicy.WIDTH -> widthScale()
      PdfFitPolicy.HEIGHT -> heightScale()
      PdfFitPolicy.PAGE -> pageScale()
      PdfFitPolicy.AUTO -> {
        val width = widthScale()
        if (firstPage.height <= 0f) width
        else if (firstPage.height * width < viewHeight * STRIP_HEIGHT_SHARE) heightScale()
        else width
      }
    }
  }

  /**
   * The furthest a document can be zoomed in, in pixels to the point.
   *
   * A point is a 72nd of an inch, so this is about forty times the printed
   * sheet. It sounds excessive, and on an ordinary page it is; on a formwork
   * plan drawn at 1:50 it is where a dimension written along a beam becomes
   * comfortable rather than merely possible, and nobody is forced to go there.
   */
  fun maxScale(): Float {
    val rest = restScale()
    maxZoom?.let { return max(rest, rest * it) }
    return max(rest, max(TARGET_POINT_SIZE, widthScale() * MIN_ZOOM_RANGE))
  }

  /**
   * As far out as it goes. Left to itself, far enough to see the widest page
   * whole, whatever zoom the document opened at.
   */
  fun minScale(): Float {
    val rest = restScale()
    minZoom?.let { return min(rest, rest * it) }
    return min(rest, widthScale())
  }

  /**
   * Where a double tap should take the reader.
   *
   * Zoomed in at all, it goes back out to where the document opened; otherwise
   * it goes far enough in one tap to read what is written on the page, rather
   * than a polite step that leaves the reader pinching afterwards.
   */
  fun doubleTapTarget(): Float {
    val rest = restScale()
    if (scale > rest * 1.05f) return rest
    doubleTapZoom?.let { return min(maxScale(), rest * it) }
    return min(maxScale(), max(rest * 3f, DOUBLE_TAP_SCALE))
  }

  /** Opens the document: at rest, at the top, and at the left when it is a strip. */
  fun reset() {
    if (!ready) return
    scale = restScale()
    offsetX = if (restScale() > widthScale()) 0f else centreX()
    offsetY = 0f
    clampOffsets()
  }

  private fun centreX() = (viewWidth - contentWidth * scale) / 2f
  private fun centreY() = (viewHeight - contentHeight * scale) / 2f

  /** Holds the document against its edges, and centres it where it is the smaller. */
  fun clampOffsets() {
    offsetX = if (contentWidth * scale <= viewWidth) centreX()
    else offsetX.coerceIn(viewWidth - contentWidth * scale, 0f)

    offsetY = if (contentHeight * scale <= viewHeight) centreY()
    else offsetY.coerceIn(viewHeight - contentHeight * scale, 0f)
  }

  fun panBy(dx: Float, dy: Float) {
    offsetX += dx
    offsetY += dy
    clampOffsets()
  }

  /**
   * Zooms about a point of the screen, leaving whatever is under that point
   * where it is. Answers the factor actually applied, which is less than the
   * one asked for at the ends of the range.
   */
  fun zoomAround(focusX: Float, focusY: Float, factor: Float): Float {
    val next = (scale * factor).coerceIn(minScale(), maxScale())
    val applied = next / scale
    offsetX = focusX - (focusX - offsetX) * applied
    offsetY = focusY - (focusY - offsetY) * applied
    scale = next
    clampOffsets()
    return applied
  }

  /** Puts the document at a given zoom and position, for working out a landing. */
  fun place(scale: Float, offsetX: Float, offsetY: Float) {
    this.scale = scale
    this.offsetX = offsetX
    this.offsetY = offsetY
    clampOffsets()
  }

  /** Puts the document at a given position, used by the scroller and the tests. */
  fun moveTo(offsetX: Float, offsetY: Float) {
    this.offsetX = offsetX
    this.offsetY = offsetY
    clampOffsets()
  }

  fun documentToScreenX(point: Float) = point * scale + offsetX
  fun documentToScreenY(point: Float) = point * scale + offsetY
  fun screenToDocumentX(pixel: Float) = (pixel - offsetX) / scale
  fun screenToDocumentY(pixel: Float) = (pixel - offsetY) / scale

  /** What is on screen, in document points, clipped to the document. */
  fun visible(): PageRect {
    val left = max(0f, screenToDocumentX(0f))
    val top = max(0f, screenToDocumentY(0f))
    val right = min(contentWidth, screenToDocumentX(viewWidth))
    val bottom = min(contentHeight, screenToDocumentY(viewHeight))
    return PageRect(left, top, max(0f, right - left), max(0f, bottom - top))
  }

  /** How far the document may be moved, for a scroller that needs its limits. */
  fun minOffsetX() = min(0f, viewWidth - contentWidth * scale)
  fun maxOffsetX() = if (contentWidth * scale <= viewWidth) centreX() else 0f
  fun minOffsetY() = min(0f, viewHeight - contentHeight * scale)
  fun maxOffsetY() = if (contentHeight * scale <= viewHeight) centreY() else 0f

  companion object {
    const val STRIP_HEIGHT_SHARE = 0.3f
    const val TARGET_POINT_SIZE = 40f
    const val MIN_ZOOM_RANGE = 8f

    /** Where one double tap lands when the document is at rest, at the least. */
    const val DOUBLE_TAP_SCALE = 12f
  }
}
