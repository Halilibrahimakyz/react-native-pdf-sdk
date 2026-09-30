package com.margelo.nitro.pdfsdk

import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** A rectangle on the screen, in pixels. */
data class ScreenRect(val left: Float, val top: Float, val right: Float, val bottom: Float) {
  val width get() = right - left
  val height get() = bottom - top
}

/**
 * One tile: which page it belongs to, where it is, and how large it is drawn.
 *
 * `rect` is in document points, which is where it is put on screen; `source` is
 * the same rectangle in the page's own points, which is what the renderer is
 * asked for.
 */
data class TileSpec(
  val page: Int,
  val level: Float,
  val column: Int,
  val row: Int,
  val rect: PageRect,
  val source: PageRect,
  val outWidth: Int,
  val outHeight: Int,
) {
  val key: String get() = "${level.toBits()}:$page:$column:$row"
}

/** A tile and where it goes on the screen. */
data class PlannedTile(val spec: TileSpec, val destination: ScreenRect)

/**
 * Which tiles the view needs, which of them to draw, and which to ask for next.
 *
 * All of it is arithmetic over the viewport, the document's layout and a set of
 * keys already drawn, so it can be exercised on its own: whether a drag leaves a
 * gap, whether a change of zoom leaves the screen bare, and in what order the
 * missing ones are asked for are questions that can be answered without a
 * device, a renderer or a single pixel.
 */
class TileGrid(
  private val tilePx: Int = 512,
  private val levelDrift: Float = 1.45f,
  private val lookaheadSeconds: Float = 0.3f,
) {
  var levelScale = 0f
    private set

  /** Set while a zoom is on its way to a scale that is already known. */
  private var aimed = false

  /** The tiles wanted at the current zoom, and the ones wanted at the last one. */
  var current: List<TileSpec> = emptyList()
    private set
  var previous: List<TileSpec> = emptyList()
    private set

  /**
   * Works out what the view needs now. `velocityX` and `velocityY` are how fast
   * the document is moving in pixels a second, which is used to ask for tiles
   * along the way rather than only where the view already is.
   *
   * Answers whether a new grid was started.
   */
  fun update(
    viewport: PdfViewport,
    layout: PdfDocumentLayout,
    velocityX: Float = 0f,
    velocityY: Float = 0f,
  ): Boolean {
    if (!viewport.ready || layout.pageCount == 0) return false

    val drift = if (levelScale > 0f) viewport.scale / levelScale else Float.MAX_VALUE
    val changed = !aimed && (drift > levelDrift || drift < 1f / levelDrift)
    if (changed) {
      previous = current
      levelScale = viewport.scale
    }

    val tilePt = tilePx / levelScale
    val margin = tilePt * TILE_MARGIN
    val visible = viewport.visible()
    val aheadX = -velocityX * lookaheadSeconds / viewport.scale
    val aheadY = -velocityY * lookaheadSeconds / viewport.scale

    val left = min(visible.x, visible.x + aheadX) - margin
    val top = min(visible.y, visible.y + aheadY) - margin
    val right = max(visible.right, visible.right + aheadX) + margin
    val bottom = max(visible.bottom, visible.bottom + aheadY) + margin

    val specs = ArrayList<TileSpec>()
    for (page in layout.pagesIn(top, bottom)) {
      specs.addAll(tilesOf(page, left, top, right, bottom, tilePt))
    }
    current = specs
    return changed
  }

  /** The tiles of one page that fall inside the band being drawn. */
  private fun tilesOf(
    page: PageBox,
    left: Float,
    top: Float,
    right: Float,
    bottom: Float,
    tilePt: Float,
  ): List<TileSpec> {
    val fromX = max(page.x, left)
    val toX = min(page.right, right)
    val fromY = max(page.y, top)
    val toY = min(page.bottom, bottom)
    if (toX <= fromX || toY <= fromY) return emptyList()

    val firstColumn = max(0, floor((fromX - page.x) / tilePt).toInt())
    val lastColumn = min(
      ceil(page.width / tilePt).toInt() - 1,
      floor((toX - page.x) / tilePt).toInt(),
    )
    val firstRow = max(0, floor((fromY - page.y) / tilePt).toInt())
    val lastRow = min(
      ceil(page.height / tilePt).toInt() - 1,
      floor((toY - page.y) / tilePt).toInt(),
    )

    val specs = ArrayList<TileSpec>()
    for (column in firstColumn..lastColumn) {
      for (row in firstRow..lastRow) {
        val x = column * tilePt
        val y = row * tilePt
        val width = min(tilePt, page.width - x)
        val height = min(tilePt, page.height - y)
        if (width <= 0f || height <= 0f) continue

        specs.add(
          TileSpec(
            page = page.index,
            level = levelScale,
            column = column,
            row = row,
            rect = PageRect(page.x + x, page.y + y, width, height),
            source = PageRect(x, y, width, height),
            outWidth = max(1, Math.round(width * levelScale)),
            outHeight = max(1, Math.round(height * levelScale)),
          )
        )
      }
    }
    return specs
  }

  /**
   * Draws for a zoom the view has not reached yet.
   *
   * A double tap knows where it is going before it starts. Asked for at the
   * start, the tiles are there as it lands, and nothing is asked for on the way
   * that will be thrown away when it arrives. Until then they are drawn small,
   * which costs nothing and is never worse than what they replace.
   */
  fun aim(scale: Float) {
    if (scale <= 0f) return
    if (scale != levelScale) {
      previous = current
      current = emptyList()
      levelScale = scale
    }
    aimed = true
  }

  /** Back to choosing the level from the zoom the reader is at. */
  fun stopAiming() {
    aimed = false
  }

  /** Everything to draw, oldest zoom first, skipping what has not been drawn yet. */
  fun toDraw(viewport: PdfViewport, drawn: (String) -> Boolean): List<PlannedTile> {
    val planned = ArrayList<PlannedTile>(previous.size + current.size)
    for (spec in previous) if (drawn(spec.key)) planned.add(place(viewport, spec))
    for (spec in current) if (drawn(spec.key)) planned.add(place(viewport, spec))
    return planned
  }

  /** What is still to be drawn, nearest the middle of the view first. */
  fun missing(viewport: PdfViewport, drawn: (String) -> Boolean): List<TileSpec> {
    val visible = viewport.visible()
    val centreX = visible.x + visible.width / 2f
    val centreY = visible.y + visible.height / 2f
    return current
      .filterNot { drawn(it.key) }
      .sortedBy {
        val dx = it.rect.x + it.rect.width / 2f - centreX
        val dy = it.rect.y + it.rect.height / 2f - centreY
        dx * dx + dy * dy
      }
  }

  /**
   * The share of the screen covered by tiles drawn for the zoom it is shown at,
   * between zero and one. What is left is covered by something coarser, either
   * the tiles of the zoom before or the thumbnail of the page underneath. What
   * falls between two pages counts as covered: there is nothing to draw there.
   */
  fun coverage(viewport: PdfViewport, layout: PdfDocumentLayout, drawn: (String) -> Boolean): Float =
    coverageOf(viewport, layout, current.filter { drawn(it.key) })

  /** The same, counting everything on screen however coarse. */
  fun coarseCoverage(
    viewport: PdfViewport,
    layout: PdfDocumentLayout,
    drawn: (String) -> Boolean,
  ): Float = coverageOf(viewport, layout, (previous + current).filter { drawn(it.key) })

  private fun coverageOf(
    viewport: PdfViewport,
    layout: PdfDocumentLayout,
    tiles: List<TileSpec>,
  ): Float {
    if (!viewport.ready) return 0f
    val visible = viewport.visible()
    if (visible.width <= 0f || visible.height <= 0f) return 0f

    // Sampled rather than measured: the tiles of one grid never overlap, but
    // those of two grids do, and adding areas would count the overlap twice.
    val steps = 40
    var counted = 0
    var covered = 0
    for (row in 0 until steps) {
      for (column in 0 until steps) {
        val x = visible.x + visible.width * (column + 0.5f) / steps
        val y = visible.y + visible.height * (row + 0.5f) / steps

        val onPage = layout.pages.any { x >= it.x && x < it.right && y >= it.y && y < it.bottom }
        if (!onPage) continue

        counted++
        if (tiles.any { x >= it.rect.x && x < it.rect.right && y >= it.rect.y && y < it.rect.bottom }) {
          covered++
        }
      }
    }
    return if (counted == 0) 1f else covered.toFloat() / counted
  }

  fun clear() {
    levelScale = 0f
    current = emptyList()
    previous = emptyList()
    aimed = false
  }

  private fun place(viewport: PdfViewport, spec: TileSpec) = PlannedTile(
    spec,
    ScreenRect(
      viewport.documentToScreenX(spec.rect.x),
      viewport.documentToScreenY(spec.rect.y),
      viewport.documentToScreenX(spec.rect.right),
      viewport.documentToScreenY(spec.rect.bottom),
    ),
  )

  companion object {
    /** Tiles are also drawn this far outside the view, as a share of a tile. */
    const val TILE_MARGIN = 0.35f

    /** Handy for tests and for callers that keep their own set of keys. */
    fun drawnFrom(keys: Set<String>): (String) -> Boolean = { keys.contains(it) }

    fun overlaps(a: ScreenRect, b: ScreenRect): Boolean =
      max(a.left, b.left) < min(a.right, b.right) - 0.01f &&
        max(a.top, b.top) < min(a.bottom, b.bottom) - 0.01f
  }
}
