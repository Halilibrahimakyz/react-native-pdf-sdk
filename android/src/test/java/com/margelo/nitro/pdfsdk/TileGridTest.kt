package com.margelo.nitro.pdfsdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * The complaints, as arithmetic.
 *
 * "It goes blurry when I drag", "a band of it stays coarse", "it slips while I
 * pinch" are all statements about which tiles the view asks for and where it
 * puts them, and none of them needs a renderer to answer. A set of keys stands
 * for the tiles drawn so far, and time passes by adding keys to it.
 */
class TileGridTest {

  private val sheetLayout = PdfDocumentLayout.of(PageSize(37947f, 1712f), 1)
  private val documentLayout = PdfDocumentLayout.of(PageSize(595f, 842f), 8)

  private fun viewportFor(layout: PdfDocumentLayout) = PdfViewport().apply {
    setDocument(layout)
    setView(1080f, 2400f)
    reset()
  }

  private fun drawAll(grid: TileGrid, drawn: MutableSet<String>) {
    grid.current.forEach { drawn.add(it.key) }
  }

  @Test
  fun `the opening view is covered by a handful of tiles`() {
    val viewport = viewportFor(sheetLayout)
    val grid = TileGrid()
    val drawn = mutableSetOf<String>()

    grid.update(viewport, sheetLayout)
    val missing = grid.missing(viewport, TileGrid.drawnFrom(drawn))
    assertTrue("A screenful wanted ${missing.size} tiles", missing.size in 1..40)

    drawAll(grid, drawn)
    assertEquals(1f, grid.coverage(viewport, sheetLayout, TileGrid.drawnFrom(drawn)), 0.001f)
  }

  @Test
  fun `the middle of the view is drawn first`() {
    val viewport = viewportFor(sheetLayout)
    val grid = TileGrid()
    grid.update(viewport, sheetLayout)

    val order = grid.missing(viewport, TileGrid.drawnFrom(emptySet()))
    val visible = viewport.visible()
    val centreX = visible.x + visible.width / 2f
    val centreY = visible.y + visible.height / 2f
    val distance = { spec: TileSpec ->
      val dx = spec.rect.x + spec.rect.width / 2f - centreX
      val dy = spec.rect.y + spec.rect.height / 2f - centreY
      dx * dx + dy * dy
    }

    val first = order.first()
    assertTrue(order.all { distance(first) <= distance(it) + 0.01f })
  }

  @Test
  fun `tiles are drawn edge to edge, with no seam and no overlap`() {
    val viewport = viewportFor(sheetLayout)
    val grid = TileGrid()
    val drawn = mutableSetOf<String>()
    grid.update(viewport, sheetLayout)
    drawAll(grid, drawn)

    val planned = grid.toDraw(viewport, TileGrid.drawnFrom(drawn))
    for (tile in planned) {
      for (other in planned) {
        if (tile === other) continue
        assertTrue(
          "Two tiles overlap on screen, which is where the seams came from",
          !TileGrid.overlaps(tile.destination, other.destination),
        )
      }
    }

    val byRow = planned.groupBy { it.spec.row }
    for ((_, row) in byRow) {
      val sorted = row.sortedBy { it.spec.column }
      for (index in 0 until sorted.size - 1) {
        val gap = abs(sorted[index].destination.right - sorted[index + 1].destination.left)
        assertTrue("A seam of $gap pixels between two tiles", gap < 0.5f)
      }
    }
  }

  @Test
  fun `a drag keeps most of the screen sharp while it moves`() {
    val viewport = viewportFor(sheetLayout)
    val grid = TileGrid()
    val drawn = mutableSetOf<String>()

    grid.update(viewport, sheetLayout)
    drawAll(grid, drawn)

    viewport.panBy(-540f, 0f)
    grid.update(viewport, sheetLayout, velocityX = -2000f)
    val sharp = grid.coverage(viewport, sheetLayout, TileGrid.drawnFrom(drawn))

    assertTrue("Only ${"%.2f".format(sharp)} of the screen was still sharp mid-drag", sharp > 0.55f)
  }

  @Test
  fun `a flick asks for the tiles it is heading towards`() {
    val viewport = viewportFor(sheetLayout)
    val grid = TileGrid()

    grid.update(viewport, sheetLayout)
    val still = grid.current.maxOf { it.column }

    grid.update(viewport, sheetLayout, velocityX = -3000f)
    val moving = grid.current.maxOf { it.column }

    assertTrue("A flick asked for nothing beyond where it already was", moving > still)
  }

  @Test
  fun `changing zoom never leaves the screen bare`() {
    val viewport = viewportFor(sheetLayout)
    val grid = TileGrid()
    val drawn = mutableSetOf<String>()

    grid.update(viewport, sheetLayout)
    drawAll(grid, drawn)

    repeat(4) { viewport.zoomAround(540f, 1200f, 1.3f) }
    val changed = grid.update(viewport, sheetLayout)
    assertTrue("The zoom moved far enough to want a new grid", changed)

    val sharp = grid.coverage(viewport, sheetLayout, TileGrid.drawnFrom(drawn))
    val anything = grid.coarseCoverage(viewport, sheetLayout, TileGrid.drawnFrom(drawn))
    assertEquals("Nothing should be sharp yet", 0f, sharp, 0.001f)
    assertEquals("But the screen should still be covered", 1f, anything, 0.001f)
  }

  @Test
  fun `each tile is drawn at the density it is shown at`() {
    val viewport = viewportFor(sheetLayout)
    viewport.zoomAround(540f, 1200f, 3f)
    val grid = TileGrid()
    grid.update(viewport, sheetLayout)

    for (spec in grid.current) {
      val drawnPixels = spec.outWidth.toFloat()
      val shownPixels = spec.rect.width * viewport.scale
      assertTrue(
        "A tile is drawn at $drawnPixels pixels to be shown at $shownPixels",
        abs(drawnPixels - shownPixels) < 1.5f,
      )
    }
  }

  @Test
  fun `crossing the sheet asks for each tile once`() {
    val viewport = viewportFor(sheetLayout)
    val grid = TileGrid()
    val drawn = mutableSetOf<String>()
    var asked = 0

    repeat(8) {
      viewport.panBy(-1600f, 0f)
      grid.update(viewport, sheetLayout, velocityX = -2500f)
      asked += grid.missing(viewport, TileGrid.drawnFrom(drawn)).size
      drawAll(grid, drawn)
    }

    assertEquals(drawn.size, asked)
    assertEquals(1f, grid.coverage(viewport, sheetLayout, TileGrid.drawnFrom(drawn)), 0.001f)
  }

  @Test
  fun `a movement that knows where it lands asks for that zoom, not the one on the way`() {
    val grid = TileGrid()
    val onTheWay = viewportFor(sheetLayout)
    val landing = viewportFor(sheetLayout).apply { zoomAround(540f, 1200f, 4f) }

    grid.aim(landing.scale)
    grid.update(landing, sheetLayout)
    val asked = grid.current.map { it.key }.toSet()
    assertTrue("A double tap asks for something", asked.isNotEmpty())
    assertTrue(
      "At the zoom it will land at, not the one it starts from",
      grid.current.all { it.level == landing.scale },
    )

    // Half way there it does not change its mind, so nothing is drawn twice.
    onTheWay.zoomAround(540f, 1200f, 2f)
    grid.update(onTheWay, sheetLayout)
    assertTrue(grid.current.all { it.level == landing.scale })

    // And when it lands, those are the tiles it wanted all along.
    grid.stopAiming()
    grid.update(landing, sheetLayout)
    assertEquals(asked, grid.current.map { it.key }.toSet())
  }

  // ─── Documents of more than one page ────────────────────────────────────────

  @Test
  fun `only the pages on screen are asked for`() {
    val viewport = viewportFor(documentLayout)
    val grid = TileGrid()
    grid.update(viewport, documentLayout)

    val pages = grid.current.map { it.page }.toSet()
    assertTrue("The opening view asked for pages $pages", pages.all { it <= 1 })
    assertTrue(pages.contains(0))
  }

  @Test
  fun `scrolling down asks for the pages that come into view`() {
    val viewport = viewportFor(documentLayout)
    val grid = TileGrid()
    val drawn = mutableSetOf<String>()

    grid.update(viewport, documentLayout)
    drawAll(grid, drawn)

    // Four pages down.
    viewport.panBy(0f, -4f * 842f * viewport.scale)
    grid.update(viewport, documentLayout)

    val pages = grid.current.map { it.page }.toSet()
    assertTrue("After scrolling the view is on pages $pages", pages.any { it >= 3 })
    assertTrue("Nothing from the top of the document should still be asked for",
      pages.none { it == 0 })
  }

  @Test
  fun `the same tile of two pages is not the same tile`() {
    val viewport = viewportFor(documentLayout)
    val grid = TileGrid()
    grid.update(viewport, documentLayout)

    val first = grid.current.first { it.page == 0 && it.column == 0 && it.row == 0 }
    val second = grid.current.firstOrNull { it.page == 1 && it.column == 0 && it.row == 0 }
    if (second != null) {
      assertTrue("Two pages shared a tile key", first.key != second.key)
    }
  }

  @Test
  fun `a tile is asked for in the page's own coordinates`() {
    val viewport = viewportFor(documentLayout)
    val grid = TileGrid()
    grid.update(viewport, documentLayout)

    for (spec in grid.current) {
      val page = documentLayout.pages[spec.page]
      assertEquals(spec.rect.x - page.x, spec.source.x, 1e-3f)
      assertEquals(spec.rect.y - page.y, spec.source.y, 1e-3f)
      assertTrue(spec.source.right <= page.width + 1e-3f)
      assertTrue(spec.source.bottom <= page.height + 1e-3f)
    }
  }

  @Test
  fun `the gap between pages is not something to be drawn`() {
    val viewport = viewportFor(documentLayout)
    val grid = TileGrid()
    val drawn = mutableSetOf<String>()

    // Sitting on the join between the first two pages.
    viewport.panBy(0f, -800f * viewport.scale)
    grid.update(viewport, documentLayout)
    drawAll(grid, drawn)

    assertEquals(
      "The gap should not count against the view being covered",
      1f,
      grid.coverage(viewport, documentLayout, TileGrid.drawnFrom(drawn)),
      0.001f,
    )
  }
}
