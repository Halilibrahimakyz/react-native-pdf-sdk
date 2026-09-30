package com.margelo.nitro.pdfsdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** How the pages of a document are laid out for reading, one under another. */
class PdfDocumentLayoutTest {

  private val a4 = PageSize(595f, 842f)

  @Test
  fun `pages are stacked with a gap between them`() {
    val layout = PdfDocumentLayout.of(a4, 3, gap = 10f)
    assertEquals(0f, layout.pages[0].y, 1e-3f)
    assertEquals(852f, layout.pages[1].y, 1e-3f)
    assertEquals(1704f, layout.pages[2].y, 1e-3f)
    // The gap belongs between pages, not after the last one.
    assertEquals(842f * 3 + 10f * 2, layout.height, 1e-3f)
  }

  @Test
  fun `a narrower page is centred against the widest`() {
    val layout = PdfDocumentLayout(listOf(a4, PageSize(400f, 842f)), gap = 0f)
    assertEquals(595f, layout.width, 1e-3f)
    assertEquals(0f, layout.pages[0].x, 1e-3f)
    assertEquals((595f - 400f) / 2f, layout.pages[1].x, 1e-3f)
  }

  @Test
  fun `only the pages a band falls on are returned`() {
    val layout = PdfDocumentLayout.of(a4, 10, gap = 10f)
    val band = layout.pagesIn(2000f, 2600f)
    assertEquals(listOf(2, 3), band.map { it.index })
  }

  @Test
  fun `the page under a point is the one a reader would name`() {
    val layout = PdfDocumentLayout.of(a4, 5, gap = 10f)
    assertEquals(0, layout.pageAt(10f))
    assertEquals(1, layout.pageAt(900f))
    // A point in the gap belongs to the page above it rather than to nothing.
    assertEquals(0, layout.pageAt(845f))
    assertEquals(4, layout.pageAt(100_000f))
  }

  @Test
  fun `a page that turns out to be a different size moves the ones below it`() {
    val layout = PdfDocumentLayout.of(a4, 3, gap = 10f)
    val corrected = layout.withPageSize(1, PageSize(595f, 1200f))

    assertEquals(852f, corrected.pages[1].y, 1e-3f)
    assertEquals(852f + 1200f + 10f, corrected.pages[2].y, 1e-3f)
    assertTrue(corrected.height > layout.height)
  }

  @Test
  fun `a document of one page has no gap in it`() {
    val layout = PdfDocumentLayout.of(PageSize(37947f, 1712f), 1)
    assertEquals(1712f, layout.height, 1e-3f)
    assertEquals(37947f, layout.width, 1e-3f)
  }
}
