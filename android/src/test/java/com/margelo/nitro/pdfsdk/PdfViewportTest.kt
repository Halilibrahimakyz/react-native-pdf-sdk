package com.margelo.nitro.pdfsdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The arithmetic the reader actually feels: whether the document drifts under a
 * pinch, whether it can be zoomed far enough to read, where it opens. Every one
 * of these was a bug on the way here.
 */
class PdfViewportTest {

  /** A phone, and the formwork sheet this package was written for. */
  private fun strip() = PdfViewport().apply {
    setPage(37947f, 1712f)
    setView(1080f, 2400f)
    reset()
  }

  /** A phone, and an ordinary document of eight A4 pages. */
  private fun document(pages: Int = 8) = PdfViewport().apply {
    setDocument(PdfDocumentLayout.of(PageSize(595f, 842f), pages))
    setView(1080f, 2400f)
    reset()
  }

  @Test
  fun `a wide sheet opens filling the height, at its left edge`() {
    val viewport = strip()
    assertEquals(2400f / 1712f, viewport.scale, 1e-4f)
    assertEquals(0f, viewport.offsetX, 1e-3f)
  }

  @Test
  fun `an ordinary document opens fitted to the width, at the top`() {
    val viewport = document()
    assertEquals(1080f / 595f, viewport.scale, 1e-4f)
    assertEquals(0f, viewport.offsetY, 1e-3f)
  }

  @Test
  fun `a document is read by scrolling, not by fitting every page on screen`() {
    val viewport = document(pages = 8)
    // Eight pages at the opening zoom are far taller than the screen.
    assertTrue(viewport.contentHeight * viewport.scale > viewport.viewHeight * 4f)
  }

  @Test
  fun `there is room to zoom in on both kinds of document`() {
    assertTrue(strip().let { it.maxScale() / it.scale } > 4f)
    assertTrue(document().let { it.maxScale() / it.scale } > 3f)
  }

  @Test
  fun `zooming leaves the point under the fingers where it is`() {
    val viewport = strip()
    val focusX = 700f
    val focusY = 1500f
    val before = viewport.screenToDocumentX(focusX) to viewport.screenToDocumentY(focusY)

    repeat(12) { viewport.zoomAround(focusX, focusY, 1.2f) }

    assertEquals(before.first, viewport.screenToDocumentX(focusX), 0.5f)
    assertEquals(before.second, viewport.screenToDocumentY(focusY), 0.5f)
  }

  @Test
  fun `zooming out and back in returns the document where it was`() {
    val viewport = strip()
    viewport.panBy(-4000f, 0f)
    val scale = viewport.scale
    val offsetX = viewport.offsetX

    viewport.zoomAround(540f, 1200f, 1.7f)
    viewport.zoomAround(540f, 1200f, 1f / 1.7f)

    assertEquals(scale, viewport.scale, 1e-3f)
    assertEquals(offsetX, viewport.offsetX, 0.5f)
  }

  @Test
  fun `the document cannot be pushed off the screen`() {
    val viewport = document()
    viewport.panBy(50_000f, 50_000f)
    assertTrue(viewport.offsetY <= 0.001f)
    assertTrue(viewport.visible().height > 0f)

    viewport.panBy(-500_000f, -500_000f)
    assertTrue(viewport.documentToScreenY(viewport.contentHeight) >= 2400f - 0.001f)
  }

  @Test
  fun `zoom stops at the ends of the range`() {
    val viewport = strip()
    repeat(40) { viewport.zoomAround(540f, 1200f, 1.5f) }
    assertEquals(viewport.maxScale(), viewport.scale, 1e-3f)

    repeat(60) { viewport.zoomAround(540f, 1200f, 0.7f) }
    assertEquals(viewport.minScale(), viewport.scale, 1e-4f)
  }

  // ─── What a caller can ask for ─────────────────────────────────────────────

  @Test
  fun `a document can be asked to open fitted to something else`() {
    val width = PdfViewport().apply {
      fit = PdfFitPolicy.WIDTH
      setPage(37947f, 1712f)
      setView(1080f, 2400f)
      reset()
    }
    assertEquals(1080f / 37947f, width.scale, 1e-7f)

    val height = PdfViewport().apply {
      fit = PdfFitPolicy.HEIGHT
      setPage(595f, 842f)
      setView(1080f, 2400f)
      reset()
    }
    assertEquals(2400f / 842f, height.scale, 1e-4f)

    val whole = PdfViewport().apply {
      fit = PdfFitPolicy.PAGE
      setPage(595f, 842f)
      setView(1080f, 2400f)
      reset()
    }
    assertTrue(842f * whole.scale <= 2400f + 0.5f)
    assertTrue(595f * whole.scale <= 1080f + 0.5f)
  }

  @Test
  fun `the zoom range is measured from the zoom it opened at`() {
    val bounded = PdfViewport().apply {
      maxZoom = 3f
      setPage(595f, 842f)
      setView(1080f, 2400f)
      reset()
    }
    assertEquals(bounded.restScale() * 3f, bounded.maxScale(), 1e-4f)

    val held = PdfViewport().apply {
      minZoom = 1f
      setPage(37947f, 1712f)
      setView(1080f, 2400f)
      reset()
    }
    assertEquals(held.restScale(), held.minScale(), 1e-4f)
    // Left to itself, a strip can be zoomed out until the whole sheet fits.
    assertTrue(strip().minScale() < strip().restScale() / 10f)
  }

  @Test
  fun `a double tap goes where it was told to`() {
    val viewport = PdfViewport().apply {
      doubleTapZoom = 2f
      setPage(595f, 842f)
      setView(1080f, 2400f)
      reset()
    }
    assertEquals(viewport.restScale() * 2f, viewport.doubleTapTarget(), 1e-4f)

    // And a second one comes back out to where the document opened.
    viewport.zoomAround(540f, 1200f, 4f)
    assertEquals(viewport.restScale(), viewport.doubleTapTarget(), 1e-4f)
  }

  @Test
  fun `a url is kept under a name of its own`() {
    val one = PdfSourceLoader.name("https://example.com/a.pdf")
    assertEquals(one, PdfSourceLoader.name("https://example.com/a.pdf"))
    assertTrue(one != PdfSourceLoader.name("https://example.com/b.pdf"))
    assertTrue(!one.contains("/") && !one.contains(":"))
  }

  @Test
  fun `zooming out stops at the width of the document`() {
    val viewport = document()
    repeat(20) { viewport.zoomAround(540f, 1200f, 0.6f) }
    assertEquals(1080f, viewport.contentWidth * viewport.scale, 0.5f)
  }
}
