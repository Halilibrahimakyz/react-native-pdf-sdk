package com.margelo.nitro.pdfsdk

import kotlin.math.max

/** A page's size in PDF points, a point being a 72nd of an inch. */
data class PageSize(val width: Float, val height: Float)

/** Where a page sits in the document, in document points. */
data class PageBox(
  val index: Int,
  val x: Float,
  val y: Float,
  val width: Float,
  val height: Float,
) {
  val right get() = x + width
  val bottom get() = y + height
  val rect get() = PageRect(x, y, width, height)
}

/**
 * The pages of a document, laid out one under another.
 *
 * A reader scrolls through a document; they do not press a button to turn a
 * page. So the pages are placed in one coordinate space, with a gap between
 * them, and everything above this works on that space rather than on a page.
 * The gap is in points and therefore grows with the zoom, which is what keeps
 * it looking like the same gap at every size.
 *
 * Pages narrower than the widest one are centred, the way every viewer draws a
 * document whose pages are not all the same shape.
 */
class PdfDocumentLayout(sizes: List<PageSize>, private val gap: Float = DEFAULT_GAP) {

  val pages: List<PageBox>
  val width: Float
  val height: Float

  init {
    val widest = sizes.maxOfOrNull { it.width } ?: 0f
    var top = 0f
    val boxes = ArrayList<PageBox>(sizes.size)
    for ((index, size) in sizes.withIndex()) {
      boxes.add(
        PageBox(
          index = index,
          x = (widest - size.width) / 2f,
          y = top,
          width = size.width,
          height = size.height,
        )
      )
      top += size.height + gap
    }

    pages = boxes
    width = widest
    height = max(0f, top - gap)
  }

  val pageCount: Int get() = pages.size

  val firstPage: PageSize
    get() = pages.firstOrNull()?.let { PageSize(it.width, it.height) } ?: PageSize(0f, 0f)

  /** The pages that any part of the given band of the document falls on. */
  fun pagesIn(top: Float, bottom: Float): List<PageBox> =
    pages.filter { it.bottom >= top && it.y <= bottom }

  /**
   * The page a reader would say they are on: the one holding the middle of what
   * is on screen, or the nearest one when the middle falls in a gap.
   */
  fun pageAt(y: Float): Int {
    if (pages.isEmpty()) return 0
    for (page in pages) {
      if (y <= page.bottom) return page.index
      val next = pages.getOrNull(page.index + 1) ?: return page.index
      // In the gap between two pages, whichever edge is nearer.
      if (y < next.y) {
        return if (y - page.bottom <= next.y - y) page.index else next.index
      }
    }
    return pages.last().index
  }

  /** The same document with one page's real size in place of the assumed one. */
  fun withPageSize(index: Int, size: PageSize): PdfDocumentLayout {
    val sizes = pages.map { PageSize(it.width, it.height) }.toMutableList()
    if (index !in sizes.indices) return this
    if (sizes[index] == size) return this
    sizes[index] = size
    return PdfDocumentLayout(sizes, gap)
  }

  fun sizes(): List<PageSize> = pages.map { PageSize(it.width, it.height) }

  companion object {
    /**
     * The gap between two pages, in points: about a fifth of an inch, which is
     * enough to read as a break between sheets without wasting the screen.
     */
    const val DEFAULT_GAP = 14f

    /** A document of one page, for the moment before the rest have been measured. */
    fun of(size: PageSize, pageCount: Int, gap: Float = DEFAULT_GAP) =
      PdfDocumentLayout(List(max(1, pageCount)) { size }, gap)
  }
}
