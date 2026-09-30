import CoreGraphics

/// A rectangle on the screen, in screen points.
struct ScreenRect: Equatable {
  let left: CGFloat
  let top: CGFloat
  let right: CGFloat
  let bottom: CGFloat

  var width: CGFloat { right - left }
  var height: CGFloat { bottom - top }
  var rect: CGRect { CGRect(x: left, y: top, width: width, height: height) }
}

/**
 * One tile: which page it belongs to, where it is, and how large it is drawn.
 *
 * `rect` is in document points, which is where it is put on screen; `source` is
 * the same rectangle in the page's own points, which is what the renderer is
 * asked for; `outWidth` and `outHeight` are in device pixels, which is what the
 * image is made at.
 */
struct TileSpec {
  let page: Int
  let level: CGFloat
  let column: Int
  let row: Int
  let rect: PageRect
  let source: PageRect
  let outWidth: Int
  let outHeight: Int

  var key: String { "\(level.bitPattern):\(page):\(column):\(row)" }
}

/// A tile and where it goes on the screen.
struct PlannedTile {
  let spec: TileSpec
  let destination: ScreenRect
}

/**
 * Which tiles the view needs, which of them to draw, and which to ask for next.
 *
 * All of it is arithmetic over the viewport, the document's layout and a set of
 * keys already drawn, so it can be exercised on its own: whether a drag leaves a
 * gap, whether a change of zoom leaves the screen bare, and in what order the
 * missing ones are asked for are questions that can be answered without a
 * device, a renderer or a single pixel.
 *
 * Three things here are not in the Kotlin twin, and all three are answers to a
 * tile costing a tenth of a second to draw on this platform however small it is:
 *
 * - Tiles are drawn at zooms from a fixed ladder, the opening zoom times 1.45
 *   to some power, rather than at whatever zoom the reader happened to stop at.
 *   A zoom that comes back to where it was finds the tiles it drew last time
 *   instead of asking for the same picture under a different name.
 * - What is drawn is every level held, coarsest first, not just the last one.
 *   Coming out of a deep zoom and moving sideways used to leave the page's own
 *   small drawing showing, twenty times too coarse; the tiles from the zooms on
 *   the way in are still held, and one of them covers that ground.
 * - A page small enough to be drawn in one go is drawn in one go. Most
 *   documents in this app are reports, and at the zoom they are read at a whole
 *   page fits in a tile, so a page costs one drawing rather than six.
 */
final class PdfTileGrid {

  private let tilePixels: CGFloat
  private let levelDrift: CGFloat
  private let lookaheadSeconds: CGFloat
  private let pixelRatio: CGFloat
  private let tilePoints: CGFloat

  /**
   * `tilePixels` is three times the Kotlin twin's 512, and `lookaheadSeconds`
   * longer, for the same reason.
   *
   * There, a tile costs what its pixels cost, because the platform keeps the
   * page parsed between draws. Here every draw reads the page's content again,
   * which on a structural drawing is a tenth of a second whether the tile is a
   * postage stamp or a screenful: measured, a screenful is 15 draws at 512 and
   * 6 at 1280, which is 1.6 seconds against a quarter of one. Larger still is
   * quicker again, but the tiles are then most of a screen across, and the
   * worst screenful measured goes from 79 MB at 1280 to 113 at 1536 and 189 at
   * the margins this used to reach with.
   *
   * A tile also arrives a quarter of a second after it is asked for, so what is
   * asked for has to be where the document will be by then rather than where it
   * is now.
   */
  init(
    tilePixels: CGFloat = 1280,
    levelDrift: CGFloat = 1.45,
    lookaheadSeconds: CGFloat = 0.5,
    pixelRatio: CGFloat = 1
  ) {
    self.pixelRatio = max(1, pixelRatio)
    self.tilePixels = tilePixels
    self.tilePoints = tilePixels / self.pixelRatio
    self.levelDrift = levelDrift
    self.lookaheadSeconds = lookaheadSeconds
  }

  /// The zoom the document opens at, which is the first rung of the ladder.
  private var ladder: CGFloat = 0

  /// Which rung the tiles being asked for are drawn at, and which the last were.
  private var rung = 0
  private var lastRung = 0
  private var hasLevel = false

  /// The zoom the tiles being asked for are drawn at.
  private(set) var levelScale: CGFloat = 0

  /// The tiles wanted at the level being read at, with what is coming into view.
  private(set) var current: [TileSpec] = []

  /// Set while a zoom is on its way to a level that is already known.
  private var aimed = false

  /// Told what the document opens at, since every level is measured from it.
  func setLadder(base: CGFloat) {
    guard base > 0, base != ladder else { return }
    ladder = base
    clear()
  }

  /// The rung of the ladder nearest a zoom.
  func level(for scale: CGFloat) -> CGFloat {
    guard ladder > 0, scale > 0 else { return scale }
    return self.scale(atRung: rung(for: scale))
  }

  private func rung(for scale: CGFloat) -> Int {
    Int((log(scale / ladder) / log(levelDrift)).rounded())
  }

  /**
   * A rung's zoom, always worked out this way and from the same base, so that a
   * level reached twice is the same number to the last bit and the tiles drawn
   * for it the first time are found again rather than drawn again.
   */
  private func scale(atRung rung: Int) -> CGFloat {
    ladder * pow(levelDrift, CGFloat(rung))
  }

  /**
   * Works out what the view needs now. `velocityX` and `velocityY` are how fast
   * the document is moving in screen points a second, which is used to ask for
   * tiles along the way rather than only where the view already is. `margin` is
   * how far outside the view to reach, in screen points.
   *
   * Answers whether the level changed.
   */
  @discardableResult
  func update(
    _ viewport: PdfViewport,
    _ layout: PdfDocumentLayout,
    velocityX: CGFloat = 0,
    velocityY: CGFloat = 0,
    margin: CGFloat = PdfTileGrid.tileMargin
  ) -> Bool {
    guard viewport.ready, layout.pageCount > 0 else { return false }
    if ladder <= 0 { ladder = viewport.scale }

    var changed = false
    if !aimed {
      // The level holds until the zoom has moved far enough from it to show,
      // and then it snaps to a rung rather than to wherever the fingers were.
      let drift = hasLevel ? viewport.scale / levelScale : .greatestFiniteMagnitude
      if drift > levelDrift || drift < 1 / levelDrift {
        settle(on: rung(for: viewport.scale))
        changed = true
      }
    }

    let ahead = lookaheadSeconds / viewport.scale
    current = specs(
      at: levelScale,
      viewport: viewport,
      layout: layout,
      margin: margin,
      aheadX: -velocityX * ahead,
      aheadY: -velocityY * ahead
    )
    return changed
  }

  /**
   * Draws for a zoom the view has not reached yet.
   *
   * A double tap knows where it is going before it starts, and a tile takes
   * about as long to arrive as the movement does. Asked for at the start, they
   * are there as it lands, instead of the page sitting coarse for a quarter of
   * a second after every tap. Until then they are drawn small, which costs
   * nothing and is never worse than what they replace.
   */
  func aim(at scale: CGFloat) {
    guard ladder > 0, scale > 0 else { return }
    let wanted = rung(for: scale)
    if !hasLevel || wanted != rung {
      settle(on: wanted)
      current = []
    }
    aimed = true
  }

  private func settle(on wanted: Int) {
    lastRung = hasLevel ? rung : wanted
    rung = wanted
    levelScale = scale(atRung: wanted)
    hasLevel = true
  }

  /// Back to choosing the level from the zoom the reader is at.
  func stopAiming() {
    aimed = false
  }

  /**
   * Everything to draw, coarsest first, skipping what has not been drawn yet.
   *
   * The levels below the one being read at are what keeps the screen covered:
   * they were drawn on the way into the zoom, they are still held, and one of
   * them covers whatever the reader has just moved onto. A level above is drawn
   * last, on top, because it is sharper than what was asked for.
   */
  func toDraw(
    _ viewport: PdfViewport,
    _ layout: PdfDocumentLayout,
    _ drawn: (String) -> Bool
  ) -> [PlannedTile] {
    guard levelScale > 0, viewport.ready else { return [] }

    let here = specs(at: levelScale, viewport: viewport, layout: layout, margin: 0)
    var planned: [PlannedTile] = []

    // With the level being read at complete, it covers the screen by itself,
    // and the levels under it would be drawn only to be hidden. That is real
    // work: eight screenfuls of pixels a frame, on a screen being dragged.
    let complete = here.allSatisfy { drawn($0.key) }

    if !complete {
      for level in levels() where level < levelScale {
        planned.append(contentsOf: held(level, viewport, layout, drawn))
      }
    }

    for spec in here where drawn(spec.key) {
      planned.append(place(viewport, spec))
    }

    // A level above the one being read at is sharper than what was asked for,
    // so it goes over the top rather than under.
    if !complete {
      for level in levels() where level > levelScale {
        planned.append(contentsOf: held(level, viewport, layout, drawn))
      }
    }
    return planned
  }

  private func held(
    _ level: CGFloat,
    _ viewport: PdfViewport,
    _ layout: PdfDocumentLayout,
    _ drawn: (String) -> Bool
  ) -> [PlannedTile] {
    specs(at: level, viewport: viewport, layout: layout, margin: 0)
      .filter { drawn($0.key) }
      .map { place(viewport, $0) }
  }

  /**
   * Whether a page is drawn in one go at the level being read at.
   *
   * When it is, that drawing is the page's small drawing as well, and asking
   * for both would be reading the page twice for the same picture.
   */
  func drawsWholePage(_ page: PageBox) -> Bool {
    guard levelScale > 0 else { return false }
    let pixels = page.width * page.height * levelScale * levelScale * pixelRatio * pixelRatio
    return pixels <= PdfTileGrid.wholePagePixels
  }

  /// What is still to be drawn, nearest the middle of the view first.
  func missing(_ viewport: PdfViewport, _ drawn: (String) -> Bool) -> [TileSpec] {
    let visible = viewport.visible()
    let centreX = visible.x + visible.width / 2
    let centreY = visible.y + visible.height / 2
    func distance(_ spec: TileSpec) -> CGFloat {
      let dx = spec.rect.x + spec.rect.width / 2 - centreX
      let dy = spec.rect.y + spec.rect.height / 2 - centreY
      return dx * dx + dy * dy
    }
    return current
      .filter { !drawn($0.key) }
      .sorted { distance($0) < distance($1) }
  }

  /**
   * The share of the screen covered by tiles drawn for the level it is shown
   * at, between zero and one. What is left is covered by something coarser.
   * What falls between two pages counts as covered: there is nothing to draw
   * there.
   */
  func coverage(
    _ viewport: PdfViewport,
    _ layout: PdfDocumentLayout,
    _ drawn: (String) -> Bool
  ) -> CGFloat {
    coverageOf(viewport, layout, current.filter { drawn($0.key) })
  }

  /// The same, counting every level held however coarse.
  func coarseCoverage(
    _ viewport: PdfViewport,
    _ layout: PdfDocumentLayout,
    _ drawn: (String) -> Bool
  ) -> CGFloat {
    coverageOf(viewport, layout, toDraw(viewport, layout, drawn).map(\.spec))
  }

  func clear() {
    levelScale = 0
    rung = 0
    lastRung = 0
    hasLevel = false
    current = []
    aimed = false
  }

  // ─── Working out ────────────────────────────────────────────────────────────

  /// The levels worth drawing, coarsest first.
  private func levels() -> [CGFloat] {
    guard hasLevel else { return [] }
    var rungs = Set((1...PdfTileGrid.coarseLevels).map { rung - $0 })
    rungs.insert(rung)
    // Zoomed out of a level, what it drew is sharper than what is wanted now.
    rungs.insert(lastRung)
    return rungs.sorted().map { scale(atRung: $0) }
  }

  /// The tiles of one level covering what is on screen, plus what is coming.
  private func specs(
    at level: CGFloat,
    viewport: PdfViewport,
    layout: PdfDocumentLayout,
    margin: CGFloat,
    aheadX: CGFloat = 0,
    aheadY: CGFloat = 0
  ) -> [TileSpec] {
    guard level > 0 else { return [] }

    // In screen points rather than in tiles: a tile is most of a screen across,
    // and a margin measured in tiles reaches so far beyond the view that a
    // screenful becomes twenty tiles and two hundred megabytes.
    let reach = margin / viewport.scale
    let visible = viewport.visible()
    let left = min(visible.x, visible.x + aheadX) - reach
    let top = min(visible.y, visible.y + aheadY) - reach
    let right = max(visible.right, visible.right + aheadX) + reach
    let bottom = max(visible.bottom, visible.bottom + aheadY) + reach

    var specs: [TileSpec] = []
    for page in layout.pagesIn(top: top, bottom: bottom) {
      specs.append(
        contentsOf: tilesOf(
          page,
          level: level,
          left: left,
          top: top,
          right: right,
          bottom: bottom
        )
      )
    }
    return specs
  }

  /// The tiles of one page that fall inside the band being drawn.
  private func tilesOf(
    _ page: PageBox,
    level: CGFloat,
    left: CGFloat,
    top: CGFloat,
    right: CGFloat,
    bottom: CGFloat
  ) -> [TileSpec] {
    let fromX = max(page.x, left)
    let toX = min(page.right, right)
    let fromY = max(page.y, top)
    let toY = min(page.bottom, bottom)
    guard toX > fromX, toY > fromY else { return [] }

    // A page that fits in one drawing is drawn in one, since what a drawing
    // costs is reading the page, not the pixels it puts out.
    let whole = page.width * page.height * level * level * pixelRatio * pixelRatio
    let tilePt = whole <= PdfTileGrid.wholePagePixels
      ? max(page.width, page.height)
      : tilePoints / level
    guard tilePt > 0 else { return [] }

    let firstColumn = max(0, Int(((fromX - page.x) / tilePt).rounded(.down)))
    let lastColumn = min(
      Int((page.width / tilePt).rounded(.up)) - 1,
      Int(((toX - page.x) / tilePt).rounded(.down))
    )
    let firstRow = max(0, Int(((fromY - page.y) / tilePt).rounded(.down)))
    let lastRow = min(
      Int((page.height / tilePt).rounded(.up)) - 1,
      Int(((toY - page.y) / tilePt).rounded(.down))
    )
    guard lastColumn >= firstColumn, lastRow >= firstRow else { return [] }

    var specs: [TileSpec] = []
    for column in firstColumn...lastColumn {
      for row in firstRow...lastRow {
        let x = CGFloat(column) * tilePt
        let y = CGFloat(row) * tilePt
        let width = min(tilePt, page.width - x)
        let height = min(tilePt, page.height - y)
        if width <= 0 || height <= 0 { continue }

        specs.append(
          TileSpec(
            page: page.index,
            level: level,
            column: column,
            row: row,
            rect: PageRect(x: page.x + x, y: page.y + y, width: width, height: height),
            source: PageRect(x: x, y: y, width: width, height: height),
            outWidth: max(1, Int((width * level * pixelRatio).rounded())),
            outHeight: max(1, Int((height * level * pixelRatio).rounded()))
          )
        )
      }
    }
    return specs
  }

  private func coverageOf(
    _ viewport: PdfViewport,
    _ layout: PdfDocumentLayout,
    _ tiles: [TileSpec]
  ) -> CGFloat {
    guard viewport.ready else { return 0 }
    let visible = viewport.visible()
    guard visible.width > 0, visible.height > 0 else { return 0 }

    // Sampled rather than measured: the tiles of one level never overlap, but
    // those of two levels do, and adding areas would count the overlap twice.
    let steps = 40
    var counted = 0
    var covered = 0
    for row in 0..<steps {
      for column in 0..<steps {
        let x = visible.x + visible.width * (CGFloat(column) + 0.5) / CGFloat(steps)
        let y = visible.y + visible.height * (CGFloat(row) + 0.5) / CGFloat(steps)

        let onPage = layout.pages.contains { x >= $0.x && x < $0.right && y >= $0.y && y < $0.bottom }
        if !onPage { continue }

        counted += 1
        if tiles.contains(where: {
          x >= $0.rect.x && x < $0.rect.right && y >= $0.rect.y && y < $0.rect.bottom
        }) {
          covered += 1
        }
      }
    }
    return counted == 0 ? 1 : CGFloat(covered) / CGFloat(counted)
  }

  private func place(_ viewport: PdfViewport, _ spec: TileSpec) -> PlannedTile {
    PlannedTile(
      spec: spec,
      destination: ScreenRect(
        left: viewport.documentToScreenX(spec.rect.x),
        top: viewport.documentToScreenY(spec.rect.y),
        right: viewport.documentToScreenX(spec.rect.right),
        bottom: viewport.documentToScreenY(spec.rect.bottom)
      )
    )
  }

  /// Tiles are also drawn this far outside the view, in screen points.
  static let tileMargin: CGFloat = 120

  /**
   * And this far once the document has come to rest, so that the next small
   * movement is already drawn. It is a second of drawing that nobody is
   * waiting on, which is the only kind worth spending.
   */
  static let restMargin: CGFloat = 280

  /**
   * A page is drawn in one go while it is no larger than this. Worth more than
   * a tile's worth of pixels, because it saves the four or five drawings the
   * same page would otherwise be, and an ordinary page read at the zoom it
   * opens at is just inside it.
   */
  static let wholePagePixels: CGFloat = 2_600_000

  /// How many levels below the one being read at are drawn underneath it.
  static let coarseLevels = 6

  /// Handy for tests and for callers that keep their own set of keys.
  static func drawnFrom(_ keys: Set<String>) -> (String) -> Bool {
    { keys.contains($0) }
  }

  static func overlaps(_ a: ScreenRect, _ b: ScreenRect) -> Bool {
    max(a.left, b.left) < min(a.right, b.right) - 0.01
      && max(a.top, b.top) < min(a.bottom, b.bottom) - 0.01
  }
}
