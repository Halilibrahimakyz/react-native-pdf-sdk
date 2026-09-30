import CoreGraphics
import Foundation

/**
 * The viewer's arithmetic, checked on a Mac.
 *
 * Everything the reader feels about this viewer is a number worked out before
 * anything is drawn: where a document opens, how far it can be zoomed, which
 * tiles the view asks for and where it puts them. So none of it needs a
 * simulator, a renderer or a pixel, and all of it is here.
 *
 * The Kotlin twin of this file is `PdfViewportTest.kt`, `TileGridTest.kt` and
 * `PdfDocumentLayoutTest.kt`. Both sides ask the same questions, which is how a
 * difference between the two platforms turns up as a failure rather than as a
 * complaint about one phone.
 *
 * Run with `npm run test:ios` in this package.
 */
@main
struct PdfSdkTests {

  // ─── The document and the screen, as the scroll view holds them ─────────────

  /**
   * A phone with a document on it: the plan, the zoom and the offset, moved the
   * way a `UIScrollView` would move them.
   */
  final class Screen {
    let layout: PdfDocumentLayout
    let viewport: PdfViewport
    let plan: PdfScrollPlan
    var zoom: CGFloat = 1
    var offset: CGPoint

    init(
      _ layout: PdfDocumentLayout,
      view: CGSize = CGSize(width: 390, height: 844),
      viewport: PdfViewport = PdfViewport()
    ) {
      self.layout = layout
      self.viewport = viewport
      viewport.setDocument(layout)
      viewport.setView(width: view.width, height: view.height)
      plan = PdfScrollPlan(viewport: viewport)
      offset = plan.initialOffset
      plan.place(viewport, offset: offset, zoom: zoom)
    }

    var scale: CGFloat { plan.scale(atZoom: zoom) }

    /// A drag: the document follows the finger, and stops at its edges.
    func pan(dx: CGFloat, dy: CGFloat) {
      offset = plan.clamp(CGPoint(x: offset.x - dx, y: offset.y - dy), atZoom: zoom)
      plan.place(viewport, offset: offset, zoom: zoom)
    }

    /// A pinch: whatever is between the fingers stays between them.
    func pinch(_ factor: CGFloat, atX x: CGFloat, y: CGFloat) {
      let onDocument = CGPoint(
        x: viewport.screenToDocumentX(x),
        y: viewport.screenToDocumentY(y)
      )
      zoom = min(max(zoom * factor, plan.minimumZoomScale), plan.maximumZoomScale)
      let scale = plan.scale(atZoom: zoom)
      offset = plan.clamp(
        CGPoint(x: onDocument.x * scale - x, y: onDocument.y * scale - y),
        atZoom: zoom
      )
      plan.place(viewport, offset: offset, zoom: zoom)
    }

    /// One frame of a zoom on its way somewhere, as the surface steps it.
    func zoom(to next: CGFloat, about anchor: CGPoint, under finger: CGPoint) {
      zoom = next
      let scale = plan.scale(atZoom: next)
      offset = plan.clamp(
        CGPoint(x: anchor.x * scale - finger.x, y: anchor.y * scale - finger.y),
        atZoom: next
      )
      plan.place(viewport, offset: offset, zoom: next)
    }

    /// A double tap, as `PdfSurface` performs it.
    func doubleTap(atX x: CGFloat, y: CGFloat) {
      let target = viewport.doubleTapTarget()
      let onDocument = CGPoint(
        x: viewport.screenToDocumentX(x),
        y: viewport.screenToDocumentY(y)
      )
      zoom = plan.zoom(forScale: target)
      let scale = plan.scale(atZoom: zoom)
      offset = plan.clamp(
        CGPoint(x: onDocument.x * scale - x, y: onDocument.y * scale - y),
        atZoom: zoom
      )
      plan.place(viewport, offset: offset, zoom: zoom)
    }

    func scroll(toPage page: Int) {
      offset = plan.offset(atZoom: zoom, pageTop: layout.pages[page].y, keepingX: offset.x)
      plan.place(viewport, offset: offset, zoom: zoom)
    }
  }

  /// The formwork sheet this package was written for: thirteen metres by sixty centimetres.
  static let sheet = PageSize(width: 37947, height: 1712)
  static let a4 = PageSize(width: 595, height: 842)

  static func strip() -> Screen { Screen(PdfDocumentLayout.of(sheet, pageCount: 1)) }
  static func document(pages: Int = 8) -> Screen {
    Screen(PdfDocumentLayout.of(a4, pageCount: pages))
  }
  static func grid() -> PdfTileGrid { PdfTileGrid(pixelRatio: 3) }

  // ─── How the pages of a document are laid out ───────────────────────────────

  static func layoutTests() {
    let stacked = PdfDocumentLayout.of(a4, pageCount: 3, gap: 10)
    near(stacked.pages[0].y, 0, "the first page starts at the top")
    near(stacked.pages[1].y, 852, "pages are stacked with a gap between them")
    near(stacked.pages[2].y, 1704, "and the gap is the same all the way down")
    // The gap belongs between pages, not after the last one.
    near(stacked.height, 842 * 3 + 10 * 2, "the document ends at its last page")

    let mixed = PdfDocumentLayout([a4, PageSize(width: 400, height: 842)], gap: 0)
    near(mixed.width, 595, "the document is as wide as its widest page")
    near(mixed.pages[0].x, 0, "the widest page starts at the left")
    near(mixed.pages[1].x, (595 - 400) / 2, "a narrower page is centred against it")

    let ten = PdfDocumentLayout.of(a4, pageCount: 10, gap: 10)
    check(
      ten.pagesIn(top: 2000, bottom: 2600).map(\.index) == [2, 3],
      "only the pages a band falls on are returned"
    )

    let five = PdfDocumentLayout.of(a4, pageCount: 5, gap: 10)
    check(five.pageAt(10) == 0, "the page under a point is the one a reader would name")
    check(five.pageAt(900) == 1, "and the next one after that")
    // A point in the gap belongs to the page above it rather than to nothing.
    check(five.pageAt(845) == 0, "a point in the gap belongs to the nearer page")
    check(five.pageAt(100_000) == 4, "past the end is the last page")

    let corrected = stacked.withPageSize(1, PageSize(width: 595, height: 1200))
    near(corrected.pages[1].y, 852, "correcting a page leaves the ones above it alone")
    near(corrected.pages[2].y, 852 + 1200 + 10, "and moves the ones below it")

    let one = PdfDocumentLayout.of(sheet, pageCount: 1)
    near(one.height, 1712, "a document of one page has no gap in it")
    near(one.width, 37947, "and is as wide as that page")
  }

  // ─── How a document opens ───────────────────────────────────────────────────

  static func openingTests() {
    let strip = self.strip()
    near(strip.scale, 844 / 1712, "a wide sheet opens filling the height", within: 1e-4)
    near(strip.offset.x, 0, "at its left edge")
    near(strip.offset.y, 0, "and at its top")

    let document = self.document()
    near(document.scale, 390 / 595, "an ordinary document opens fitted to the width", within: 1e-4)
    near(document.offset.y, 0, "at the top")
    check(
      document.plan.contentSize.height > 844 * 4,
      "a document is read by scrolling, not by fitting every page on screen"
    )

    check(strip.plan.maximumZoomScale > 4, "there is room to zoom into a sheet")
    check(document.plan.maximumZoomScale > 3, "and into a document")
    near(
      strip.plan.minimumZoomScale * strip.plan.baseScale * 37947,
      390,
      "zooming out stops at the width of the document",
      within: 0.5
    )
    check(
      document.plan.minimumZoomScale >= 1 - 1e-6,
      "a document that opens fitted to the width cannot be zoomed out further"
    )

    // A page shorter than the screen sits in the middle of it rather than
    // against the top, which is what every viewer does with a single page.
    let single = Screen(PdfDocumentLayout.of(a4, pageCount: 1))
    near(
      single.plan.contentSize.height,
      842 * 390 / 595,
      "one page, fitted to the width",
      within: 0.5
    )
    near(
      single.offset.y,
      -(844 - 842 * 390 / 595) / 2,
      "opens in the middle of the screen",
      within: 0.5
    )

    // A page ten points tall would open past the zoom ceiling, and the scroll
    // view cannot be given a scale outside its own range.
    let sliver = Screen(PdfDocumentLayout.of(PageSize(width: 4000, height: 10), pageCount: 1))
    check(sliver.plan.baseScale <= sliver.viewport.maxScale() + 1e-6, "the ceiling wins")
    check(sliver.plan.minimumZoomScale <= 1, "and the range still holds 1")
    check(sliver.plan.maximumZoomScale >= 1, "on both sides")
  }

  // ─── Moving about ───────────────────────────────────────────────────────────

  static func movementTests() {
    let strip = self.strip()
    let focus = CGPoint(x: 260, y: 500)
    let before = CGPoint(
      x: strip.viewport.screenToDocumentX(focus.x),
      y: strip.viewport.screenToDocumentY(focus.y)
    )
    for _ in 0..<12 { strip.pinch(1.2, atX: focus.x, y: focus.y) }
    near(
      strip.viewport.screenToDocumentX(focus.x),
      before.x,
      "a pinch holds what is under it",
      within: 0.5
    )
    near(strip.viewport.screenToDocumentY(focus.y), before.y, "in both directions", within: 0.5)

    let back = self.strip()
    back.pan(dx: -1200, dy: 0)
    let scale = back.scale
    let offsetX = back.offset.x
    back.pinch(1.7, atX: 195, y: 422)
    back.pinch(1 / 1.7, atX: 195, y: 422)
    near(
      back.scale,
      scale,
      "zooming out and back in returns the document where it was",
      within: 1e-3
    )
    near(back.offset.x, offsetX, "and leaves it where it was", within: 0.5)

    let document = self.document()
    document.pan(dx: 50_000, dy: 50_000)
    check(document.offset.y <= 0.001, "the document cannot be pushed off the screen")
    check(document.viewport.visible().height > 0, "there is always something on screen")
    document.pan(dx: -500_000, dy: -500_000)
    check(
      document.viewport.documentToScreenY(document.viewport.contentHeight) >= 844 - 0.001,
      "nor pulled past its last page"
    )

    let ends = self.strip()
    for _ in 0..<40 { ends.pinch(1.5, atX: 195, y: 422) }
    near(
      ends.scale,
      ends.viewport.maxScale(),
      "zoom stops at the far end of the range",
      within: 1e-3
    )
    for _ in 0..<60 { ends.pinch(0.7, atX: 195, y: 422) }
    near(ends.scale, ends.viewport.minScale(), "and at the near end", within: 1e-4)

    // A double tap goes far enough in to read what is written, and the second
    // one comes back out to where the document opened.
    let tapped = self.strip()
    let rest = tapped.scale
    let under = tapped.viewport.screenToDocumentX(195)
    tapped.doubleTap(atX: 195, y: 422)
    check(tapped.scale > rest * 3, "a double tap is worth making")
    near(
      tapped.viewport.screenToDocumentX(195),
      under,
      "and lands on what was under the finger",
      within: 1.0
    )
    tapped.doubleTap(atX: 195, y: 422)
    near(tapped.scale, rest, "a second one comes back out", within: 1e-4)

    let paged = self.document()
    paged.scroll(toPage: 3)
    near(
      paged.viewport.documentToScreenY(paged.layout.pages[3].y),
      0,
      "a page scrolled to lands at the top of the view",
      within: 0.5
    )
    check(paged.layout.pageAt(paged.viewport.visible().y + 10) == 3, "and is the page shown")
  }

  // ─── Which tiles the view asks for ──────────────────────────────────────────

  static func tileTests() {
    let screen = strip()
    let grid = self.grid()
    var drawn = Set<String>()

    grid.update(screen.viewport, screen.layout)
    let missing = grid.missing(screen.viewport) { drawn.contains($0) }
    check(
      missing.count >= 1 && missing.count <= 40,
      "a screenful is a handful of tiles, not \(missing.count)"
    )

    let visible = screen.viewport.visible()
    let centre = CGPoint(x: visible.x + visible.width / 2, y: visible.y + visible.height / 2)
    func distance(_ spec: TileSpec) -> CGFloat {
      let dx = spec.rect.x + spec.rect.width / 2 - centre.x
      let dy = spec.rect.y + spec.rect.height / 2 - centre.y
      return dx * dx + dy * dy
    }
    if let first = missing.first {
      check(
        missing.allSatisfy { distance(first) <= distance($0) + 0.01 },
        "the middle of the view is drawn first"
      )
    }

    grid.current.forEach { drawn.insert($0.key) }
    near(
      grid.coverage(screen.viewport, screen.layout) { drawn.contains($0) },
      1,
      "and once they are drawn the view is covered",
      within: 0.001
    )

    // Where the seams came from: two tiles that overlap on screen, or two that
    // do not quite meet.
    let planned = grid.toDraw(screen.viewport, screen.layout) { drawn.contains($0) }
    var overlapping = 0
    for tile in planned {
      for other in planned where other.spec.key != tile.spec.key {
        if PdfTileGrid.overlaps(tile.destination, other.destination) { overlapping += 1 }
      }
    }
    check(overlapping == 0, "tiles are drawn edge to edge, with no overlap")

    var worstSeam: CGFloat = 0
    for (_, row) in Dictionary(grouping: planned, by: { $0.spec.row }) {
      let sorted = row.sorted { $0.spec.column < $1.spec.column }
      for index in 0..<max(0, sorted.count - 1) {
        worstSeam = max(
          worstSeam,
          abs(sorted[index].destination.right - sorted[index + 1].destination.left)
        )
      }
    }
    check(worstSeam < 0.5, "and with no seam, the worst being \(worstSeam)")

    // Each tile is drawn at the density it is shown at: that is what a tiled
    // viewer is for, and getting it wrong is the blurry band.
    let zoomed = strip()
    zoomed.pinch(3, atX: 195, y: 422)
    let zoomedGrid = self.grid()
    zoomedGrid.update(zoomed.viewport, zoomed.layout)
    var worstDensity: CGFloat = 0
    for spec in zoomedGrid.current {
      let shown = spec.rect.width * zoomed.scale * 3
      worstDensity = max(worstDensity, abs(CGFloat(spec.outWidth) - shown))
    }
    check(worstDensity < 1.5, "each tile is drawn at the density it is shown at")

    // A drag keeps most of the screen sharp while it moves, and asks for what
    // it is heading towards rather than only for where it already is.
    let dragged = strip()
    let dragGrid = self.grid()
    var dragDrawn = Set<String>()
    dragGrid.update(dragged.viewport, dragged.layout)
    dragGrid.current.forEach { dragDrawn.insert($0.key) }
    dragged.pan(dx: -195, dy: 0)
    dragGrid.update(dragged.viewport, dragged.layout, velocityX: -800)
    let sharp = dragGrid.coverage(dragged.viewport, dragged.layout) { dragDrawn.contains($0) }
    check(sharp > 0.55, "a drag keeps the screen sharp, not \(sharp)")

    let still = strip()
    let aheadGrid = self.grid()
    aheadGrid.update(still.viewport, still.layout)
    let standing = aheadGrid.current.map(\.column).max() ?? 0
    aheadGrid.update(still.viewport, still.layout, velocityX: -1200)
    let moving = aheadGrid.current.map(\.column).max() ?? 0
    check(moving > standing, "a flick asks for the tiles it is heading towards")

    // Changing zoom never leaves the screen bare: nothing is sharp yet, but
    // what was drawn for the zoom before is still covering it.
    let zooming = strip()
    let zoomGrid = self.grid()
    var zoomDrawn = Set<String>()
    zoomGrid.update(zooming.viewport, zooming.layout)
    zoomGrid.current.forEach { zoomDrawn.insert($0.key) }
    for _ in 0..<4 { zooming.pinch(1.3, atX: 195, y: 422) }
    check(zoomGrid.update(zooming.viewport, zooming.layout), "a big change of zoom wants a new grid")
    near(
      zoomGrid.coverage(zooming.viewport, zooming.layout) { zoomDrawn.contains($0) },
      0,
      "nothing should be sharp yet",
      within: 0.001
    )
    near(
      zoomGrid.coarseCoverage(zooming.viewport, zooming.layout) { zoomDrawn.contains($0) },
      1,
      "but the screen should still be covered",
      within: 0.001
    )

    // Crossing the sheet asks for each tile once, which is what keeps a flick
    // across thirteen metres from redrawing the same tile twenty times.
    let crossing = strip()
    let crossingGrid = self.grid()
    var crossingDrawn = Set<String>()
    var asked = 0
    for _ in 0..<8 {
      crossing.pan(dx: -600, dy: 0)
      crossingGrid.update(crossing.viewport, crossing.layout, velocityX: -900)
      asked += crossingGrid.missing(crossing.viewport) { crossingDrawn.contains($0) }.count
      crossingGrid.current.forEach { crossingDrawn.insert($0.key) }
    }
    check(asked == crossingDrawn.count, "crossing the sheet asks for each tile once")
    near(
      crossingGrid.coverage(crossing.viewport, crossing.layout) { crossingDrawn.contains($0) },
      1,
      "and arrives with the screen covered",
      within: 0.001
    )
  }

  // ─── What a caller can ask for ──────────────────────────────────────────────

  static func policyTests() {
    let view = CGSize(width: 390, height: 844)

    func screen(_ page: PageSize, _ apply: (PdfViewport) -> Void) -> Screen {
      let layout = PdfDocumentLayout.of(page, pageCount: 4)
      let viewport = PdfViewport()
      viewport.setDocument(layout)
      viewport.setView(width: view.width, height: view.height)
      apply(viewport)
      return Screen(layout, view: view, viewport: viewport)
    }

    // Left to itself, a sheet twenty times wider than it is tall fills the
    // height; asked for the width, it is the line across the screen the reader
    // asked for.
    let auto = screen(sheet) { _ in }
    near(auto.plan.baseScale, 844 / 1712, "a strip opens filling the height", within: 1e-4)
    let width = screen(sheet) { $0.fit = .width }
    near(width.plan.baseScale, 390 / 37947, "fitting the width is fitting the width", within: 1e-6)

    let height = screen(a4) { $0.fit = .height }
    near(height.plan.baseScale, 844 / 842, "a page can be asked to fill the height", within: 1e-4)
    let whole = screen(a4) { $0.fit = .page }
    near(whole.plan.baseScale, 390 / 595, "or to be shown whole", within: 1e-4)
    check(
      whole.layout.pages[0].height * whole.plan.baseScale <= 844 + 0.5,
      "which means the whole of the first page is on the screen"
    )

    // The zoom range, in multiples of what it opened at.
    let bounded = screen(a4) { $0.maxZoom = 3 }
    near(bounded.plan.maximumZoomScale, 3, "a ceiling is a multiple of the opening zoom", within: 1e-6)
    let held = screen(sheet) { $0.minZoom = 1 }
    near(held.plan.minimumZoomScale, 1, "and so is a floor", within: 1e-6)
    check(
      screen(sheet) { _ in }.plan.minimumZoomScale < 0.1,
      "left to itself a strip can be zoomed out until the sheet fits"
    )

    let tapped = screen(a4) { $0.doubleTapZoom = 2 }
    near(
      tapped.viewport.doubleTapTarget(),
      tapped.plan.baseScale * 2,
      "a double tap goes where it was told to",
      within: 1e-4
    )
  }

  // ─── Where a document comes from ────────────────────────────────────────────

  static func sourceTests() {
    let one = PdfSourceLoader.name(for: "https://example.com/a.pdf")
    let again = PdfSourceLoader.name(for: "https://example.com/a.pdf")
    let other = PdfSourceLoader.name(for: "https://example.com/b.pdf")
    check(one == again, "the same url is kept under the same name")
    check(one != other, "and two urls are not the same document")
    check(
      !one.contains("/") && !one.contains(":"),
      "a name is a name rather than half a url"
    )

    do {
      _ = try PdfSourceLoader.localPath(for: "/no/such/file.pdf")
      check(false, "a missing file is a failure")
    } catch {
      check(PdfFailure.from(error).code == .notFound, "a missing file says so")
    }

    do {
      _ = try PdfSourceLoader.localPath(for: "ftp://example.com/a.pdf")
      check(false, "a scheme this cannot open is a failure")
    } catch {
      check(PdfFailure.from(error).code == .unsupported, "and so does a scheme it cannot open")
    }
  }

  // ─── The ladder of zooms tiles are drawn at ─────────────────────────────────

  static func ladderTests() {
    // A zoom that comes back to where it was finds what it drew there.
    let screen = strip()
    let grid = self.grid()
    grid.setLadder(base: screen.plan.baseScale)
    var drawn = Set<String>()

    grid.update(screen.viewport, screen.layout)
    let atRest = Set(grid.current.map(\.key))
    drawn.formUnion(atRest)

    for _ in 0..<3 { screen.pinch(1.3, atX: 195, y: 422) }
    grid.update(screen.viewport, screen.layout)
    let zoomedIn = Set(grid.current.map(\.key))
    drawn.formUnion(zoomedIn)
    check(zoomedIn.isDisjoint(with: atRest), "a zoom far enough in wants tiles of its own")

    for _ in 0..<3 { screen.pinch(1 / 1.3, atX: 195, y: 422) }
    grid.update(screen.viewport, screen.layout)
    check(
      Set(grid.current.map(\.key)) == atRest,
      "and coming back asks for the ones it drew on the way in, not new ones"
    )
    near(
      grid.coverage(screen.viewport, screen.layout) { drawn.contains($0) },
      1,
      "so the screen is sharp the moment it arrives",
      within: 0.001
    )

    // Deep in, a small movement is covered by a level drawn on the way in.
    let deep = strip()
    let deepGrid = self.grid()
    deepGrid.setLadder(base: deep.plan.baseScale)
    var held = Set<String>()
    for _ in 0..<12 {
      deep.pinch(1.45, atX: 195, y: 422)
      deepGrid.update(deep.viewport, deep.layout)
      held.formUnion(deepGrid.current.map(\.key))
    }
    // Far enough to leave the ground the tiles on screen were asked with.
    deep.pan(dx: -900, dy: -400)
    deepGrid.update(deep.viewport, deep.layout)
    let sharp = deepGrid.coverage(deep.viewport, deep.layout) { held.contains($0) }
    let anything = deepGrid.coarseCoverage(deep.viewport, deep.layout) { held.contains($0) }
    check(sharp < 1, "a movement at a deep zoom uncovers ground")
    near(anything, 1, "which the zooms on the way in have already drawn", within: 0.001)

    // Resting asks for the ground around the screen as well.
    let resting = strip()
    let restingGrid = self.grid()
    restingGrid.setLadder(base: resting.plan.baseScale)
    // In the middle of the sheet, where there is ground on every side of the
    // screen rather than the document's own edge.
    resting.pinch(2, atX: 195, y: 422)
    resting.pan(dx: -4000, dy: 0)
    restingGrid.update(resting.viewport, resting.layout)
    let moving = restingGrid.current.count
    restingGrid.update(resting.viewport, resting.layout, margin: PdfTileGrid.restMargin)
    check(
      restingGrid.current.count > moving,
      "a document at rest asks for more than one that is moving"
    )
  }

  // ─── Pages small enough to draw in one go ───────────────────────────────────

  static func wholePageTests() {
    let screen = document()
    let grid = self.grid()
    grid.setLadder(base: screen.plan.baseScale)
    grid.update(screen.viewport, screen.layout)

    for page in Set(grid.current.map(\.page)) {
      let tiles = grid.current.filter { $0.page == page }
      check(tiles.count == 1, "a page read at the opening zoom is one drawing, not \(tiles.count)")
      check(
        tiles[0].source.width >= screen.layout.pages[page].width - 0.001,
        "and it is the whole page"
      )
    }

    // Zoomed in, the same page is more than one drawing again.
    for _ in 0..<4 { screen.pinch(1.45, atX: 195, y: 422) }
    grid.update(screen.viewport, screen.layout)
    let first = grid.current.filter { $0.page == 0 }
    check(first.count > 1, "a page zoomed into is drawn in pieces")
    check(
      first.allSatisfy { CGFloat($0.outWidth * $0.outHeight) <= PdfTileGrid.wholePagePixels },
      "none of which is larger than a page drawn in one go"
    )
  }

  // ─── A movement that knows where it is going ────────────────────────────────

  static func aimingTests() {
    let screen = strip()
    let grid = self.grid()
    let finger = CGPoint(x: 195, y: 422)
    let anchor = CGPoint(
      x: screen.viewport.screenToDocumentX(finger.x),
      y: screen.viewport.screenToDocumentY(finger.y)
    )
    let target = screen.plan.zoom(forScale: screen.viewport.doubleTapTarget())
    let scale = screen.plan.scale(atZoom: target)

    // Where the tap lands, worked out before it starts.
    let landing = PdfViewport()
    landing.setDocument(screen.layout)
    landing.setView(width: 390, height: 844)
    screen.plan.place(
      landing,
      offset: screen.plan.clamp(
        CGPoint(x: anchor.x * scale - finger.x, y: anchor.y * scale - finger.y),
        atZoom: target
      ),
      zoom: target
    )
    grid.aim(at: scale)
    grid.update(landing, screen.layout)
    let asked = Set(grid.current.map(\.key))
    check(!asked.isEmpty, "a double tap asks for the tiles of where it lands")
    check(
      grid.current.allSatisfy { abs($0.level - scale) < 1e-6 },
      "at the zoom it will land at, not the one it starts from"
    )

    // Half way there they are drawn small, which is what covers the movement.
    screen.zoom(to: screen.zoom + (target - screen.zoom) / 2, about: anchor, under: finger)
    let onTheWay = grid.toDraw(screen.viewport, screen.layout) { asked.contains($0) }
    check(
      onTheWay.contains { $0.destination.rect.intersects(CGRect(x: 0, y: 0, width: 390, height: 844)) },
      "and they are on the screen while it moves"
    )

    // And when it lands, they are the ones it wanted all along.
    screen.zoom(to: target, about: anchor, under: finger)
    grid.stopAiming()
    grid.update(screen.viewport, screen.layout)
    check(
      Set(grid.current.map(\.key)) == asked,
      "so nothing is drawn twice for the sake of the movement"
    )
    near(
      grid.coverage(screen.viewport, screen.layout) { asked.contains($0) },
      1,
      "and the screen is sharp as it arrives",
      within: 0.001
    )
  }

  // ─── Documents of more than one page ────────────────────────────────────────

  static func pageTests() {
    let screen = document()
    let grid = self.grid()
    grid.update(screen.viewport, screen.layout)

    let pages = Set(grid.current.map(\.page))
    check(pages.allSatisfy { $0 <= 1 }, "only the pages on screen are asked for, not \(pages)")
    check(pages.contains(0), "the first of them being the one being read")

    for spec in grid.current {
      let page = screen.layout.pages[spec.page]
      near(
        spec.source.x,
        spec.rect.x - page.x,
        "a tile is asked for in the page's own x",
        within: 1e-3
      )
      near(spec.source.y, spec.rect.y - page.y, "and in its own y", within: 1e-3)
      check(spec.source.right <= page.width + 1e-3, "and never past the page's width")
      check(spec.source.bottom <= page.height + 1e-3, "or its height")
    }

    let first = grid.current.first { $0.page == 0 && $0.column == 0 && $0.row == 0 }
    let second = grid.current.first { $0.page == 1 && $0.column == 0 && $0.row == 0 }
    if let first, let second {
      check(first.key != second.key, "the same tile of two pages is not the same tile")
    }

    let scrolled = document()
    let scrolledGrid = self.grid()
    scrolledGrid.update(scrolled.viewport, scrolled.layout)
    scrolled.pan(dx: 0, dy: -4 * 842 * scrolled.scale)
    scrolledGrid.update(scrolled.viewport, scrolled.layout)
    let after = Set(scrolledGrid.current.map(\.page))
    check(after.contains { $0 >= 3 }, "scrolling down asks for the pages that come into view")
    check(!after.contains(0), "and stops asking for the ones left behind")

    // Sitting on the join between two pages: the gap is not something to be
    // drawn, so it should not count against the view being covered.
    let joined = document()
    let joinedGrid = self.grid()
    var drawn = Set<String>()
    joined.pan(dx: 0, dy: -800 * joined.scale)
    joinedGrid.update(joined.viewport, joined.layout)
    joinedGrid.current.forEach { drawn.insert($0.key) }
    near(
      joinedGrid.coverage(joined.viewport, joined.layout) { drawn.contains($0) },
      1,
      "the gap between pages is not something to be drawn",
      within: 0.001
    )
  }

  // ─── Which way up a page is ─────────────────────────────────────────────────

  static func geometryTests() {
    // A page whose box does not start at zero still draws from its own corner.
    let offset = PdfPageGeometry(box: CGRect(x: 20, y: 30, width: 595, height: 842), rotation: 0)
    near(offset.size.width, 595, "a box that starts elsewhere is still its own size")
    near(offset.size.height, 842, "in both directions")
    let corner = CGPoint(x: 20, y: 30).applying(offset.transform)
    near(corner.x, 0, "and its corner maps onto the origin")
    near(corner.y, 0, "in both directions")

    // A quarter turn clockwise, as the file asks for: the top left corner of
    // the page as printed ends up at the top left of what the reader sees.
    let turned = PdfPageGeometry(box: CGRect(x: 0, y: 0, width: 595, height: 842), rotation: 90)
    near(turned.size.width, 842, "a rotated page is as wide as it was tall")
    near(turned.size.height, 595, "and as tall as it was wide")
    let topLeft = CGPoint(x: 0, y: 842).applying(turned.transform)
    near(topLeft.x, 842, "the page's top left corner goes to the top right")
    near(topLeft.y, 595, "of the space the reader sees")
    let bottomLeft = CGPoint(x: 0, y: 0).applying(turned.transform)
    near(bottomLeft.x, 0, "and its bottom left corner to the top left")
    near(bottomLeft.y, 595, "of the same space")

    let upsideDown = PdfPageGeometry(box: CGRect(x: 0, y: 0, width: 595, height: 842), rotation: 180)
    let moved = CGPoint(x: 0, y: 0).applying(upsideDown.transform)
    near(moved.x, 595, "half a turn puts the near corner at the far one")
    near(moved.y, 842, "in both directions")

    check(PdfPageGeometry(box: .zero, rotation: -90).rotation == 270, "a turn is read the long way round")
    check(PdfPageGeometry(box: .zero, rotation: 450).rotation == 90, "and past the whole turn")
  }

  // ─── Running them ───────────────────────────────────────────────────────────

  static var failures: [String] = []
  static var checks = 0

  static func main() {
    layoutTests()
    openingTests()
    policyTests()
    sourceTests()
    movementTests()
    tileTests()
    ladderTests()
    wholePageTests()
    aimingTests()
    pageTests()
    geometryTests()

    if failures.isEmpty {
      print("\(checks) checks passed")
      exit(0)
    }
    print("\(failures.count) of \(checks) checks failed:")
    failures.forEach { print("  ✗ \($0)") }
    exit(1)
  }

  static func check(_ passed: Bool, _ what: String) {
    checks += 1
    if !passed { failures.append(what) }
  }

  static func near(
    _ was: CGFloat,
    _ wanted: CGFloat,
    _ what: String,
    within epsilon: CGFloat = 0.001
  ) {
    checks += 1
    if abs(was - wanted) > epsilon {
      failures.append("\(what) (expected \(wanted), got \(was))")
    }
  }
}
