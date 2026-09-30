import UIKit

/**
 * The viewer itself: one view that owns the document, the zoom, the movement
 * and the drawing.
 *
 * The Kotlin twin, `PdfSurface.kt`, counts the pinch and the flick by
 * hand, because Android's own detectors would not do what a document needs.
 * Here a `UIScrollView` does that work: it is the same scroll view every iOS
 * app is read through, so the momentum, the rubber band at the edges and the
 * pinch are the ones the reader already knows, and none of them is ours to get
 * wrong. What is left is this: turn a document into a content size and a zoom
 * range, and on every frame the scroll view moves, put the right tiles in the
 * right places.
 *
 * The scroll view is transparent and its content is an empty view. Nothing is
 * drawn inside it, so nothing is stretched by its zoom: the drawing happens
 * underneath it in `PdfTileCanvas`, from numbers read out of it, which is what
 * keeps a sheet thirteen metres wide sharp at every zoom instead of magnifying
 * one picture of it.
 */
final class PdfSurface: UIView, UIScrollViewDelegate {

  // ─── What the view tells whoever is holding it ──────────────────────────────

  var onLoad: ((_ pageCount: Int, _ width: CGFloat, _ height: CGFloat) -> Void)?
  /// Zero based, so it matches the page property. A caller adds one to show it.
  var onPageChange: ((_ page: Int, _ pageCount: Int) -> Void)?
  /// The zoom as a multiple of what the document opened at, and what that is.
  var onZoom: ((_ zoom: CGFloat, _ scale: CGFloat) -> Void)?
  var onFailure: ((PdfFailure) -> Void)?
  /// A tap that was not part of a double tap, and the page under it.
  var onTap: ((_ x: CGFloat, _ y: CGFloat, _ page: Int) -> Void)?

  private let scrollView = UIScrollView()
  private let content = UIView()
  private let canvas = PdfTileCanvas()

  private let viewport = PdfViewport()
  private var grid = PdfTileGrid(pixelRatio: 2)
  private var pixelRatio: CGFloat = 0
  private var plan: PdfScrollPlan?
  private var layout = PdfDocumentLayout([])
  private var pageSizes: [PageSize] = []

  private var store: PdfTileStore?

  private let loader = DispatchQueue(label: "pdf-sdk-loader", qos: .userInitiated)

  // ─── What it was told ───────────────────────────────────────────────────────

  private var uri: String?
  private var headers: [String: String] = [:]
  private var password: String?
  private var cache = true
  private var openAtPage = 0
  private var pageGap = PdfDocumentLayout.defaultGap

  private var reportedPage = -1
  private var reportedZoom: CGFloat = 0
  private var lastZoomAt: CFTimeInterval = 0
  private var zoomQueued = false

  private var viewSize: CGSize = .zero
  private var zoom: ZoomStep?
  private var ticker: CADisplayLink?
  private var lastEnsure: CFTimeInterval = 0
  private var ensureQueued = false
  private var velocity = CGPoint.zero
  private var lastOffset = CGPoint.zero
  private var lastMovedAt: CFTimeInterval = 0

  override init(frame: CGRect) {
    super.init(frame: frame)

    // React Native leaves overflow visible on the views around us, so without
    // this the document is drawn over whatever the screen puts above and below
    // it, the header included.
    clipsToBounds = true
    backgroundColor = .clear

    canvas.frame = bounds
    addSubview(canvas)

    scrollView.frame = bounds
    scrollView.delegate = self
    scrollView.backgroundColor = .clear
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.decelerationRate = .normal
    scrollView.bouncesZoom = true
    scrollView.minimumZoomScale = 1
    scrollView.maximumZoomScale = 1
    content.backgroundColor = .clear
    scrollView.addSubview(content)
    addSubview(scrollView)

    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
    doubleTap.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTap)

    let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    singleTap.require(toFail: doubleTap)
    scrollView.addGestureRecognizer(singleTap)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("PdfSurface is not built from a storyboard")
  }

  // ─── Loading ────────────────────────────────────────────────────────────────

  func load(uri: String, headers: [String: String], password: String?, cache: Bool, page: Int) {
    let same = uri == self.uri && password == self.password && store != nil
    self.headers = headers
    self.cache = cache

    if same {
      if page != openAtPage {
        openAtPage = page
        goToPage(page, animated: false)
      }
      return
    }

    self.uri = uri
    self.password = password
    openAtPage = page
    reportedPage = -1
    reportedZoom = 0

    closeDocument()
    canvas.clear()
    guard !uri.isEmpty else { return }

    loader.async { [weak self] in
      guard let self else { return }

      let tiles: PdfTileStore
      let sizes: [PageSize]
      do {
        let path = try PdfSourceLoader.localPath(for: uri, headers: headers, cache: cache)
        tiles = try PdfTileStore(
          path: path,
          password: password,
          onTileReady: { [weak self] in self?.redraw() },
          onError: { [weak self] error in self?.report(error) }
        )
        // Every page measured before the document is shown. The Kotlin twin
        // assumes they are all the size of the first and corrects it
        // afterwards, because opening a page on Android is where the platform
        // parses its content, and on a large drawing that is a third of a
        // second each. Here a page's size is read from the page's dictionary
        // without touching its content, so all of them cost nothing.
        sizes = try tiles.pageSizes()
      } catch {
        self.report(error)
        return
      }

      DispatchQueue.main.async {
        guard self.uri == uri, self.window != nil else {
          tiles.close()
          return
        }
        self.store = tiles
        self.pageSizes = sizes
        self.layout = PdfDocumentLayout(sizes, gap: self.pageGap)
        self.viewport.setDocument(self.layout)
        if self.viewport.ready {
          self.applyPlan()
          self.goToPage(self.openAtPage, animated: false)
          self.ensureTiles(force: true)
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.uri == uri else { return }
            self.settle()
          }
        }
        let first = self.layout.firstPage
        self.onLoad?(tiles.pageCount, first.width, first.height)
      }
    }
  }

  // ─── What the reader is allowed to do ───────────────────────────────────────

  func setFit(_ policy: PdfFitPolicy) {
    guard viewport.fit != policy else { return }
    viewport.fit = policy
    refit()
  }

  func setZoomRange(min minZoom: CGFloat?, max maxZoom: CGFloat?) {
    guard viewport.minZoom != minZoom || viewport.maxZoom != maxZoom else { return }
    viewport.minZoom = minZoom
    viewport.maxZoom = maxZoom
    refit()
  }

  func setDoubleTapZoom(_ value: CGFloat?) {
    viewport.doubleTapZoom = value
  }

  func setPageGap(_ gap: CGFloat) {
    guard gap != pageGap else { return }
    pageGap = gap
    guard !pageSizes.isEmpty else { return }
    layout = PdfDocumentLayout(pageSizes, gap: gap)
    viewport.setDocument(layout)
    refit()
  }

  func setBackdropColor(_ color: UIColor?) {
    backgroundColor = color ?? .clear
  }

  func setScrollIndicators(_ shown: Bool) {
    scrollView.showsVerticalScrollIndicator = shown
    scrollView.showsHorizontalScrollIndicator = shown
  }

  /// Something about the shape of the document changed, so it opens again.
  private func refit() {
    guard viewport.ready, store != nil else { return }
    let page = reportedPage < 0 ? openAtPage : reportedPage
    applyPlan()
    goToPage(page, animated: false)
    ensureTiles(force: true)
  }

  // ─── What a caller can ask for ──────────────────────────────────────────────

  func goToPage(_ page: Int, animated: Bool) {
    guard let plan, layout.pages.indices.contains(page) else { return }
    let offset = plan.offset(
      atZoom: scrollView.zoomScale,
      pageTop: layout.pages[page].y,
      keepingX: scrollView.contentOffset.x
    )
    stopZooming()
    velocity = .zero
    lastMovedAt = 0
    if animated {
      scrollView.setContentOffset(offset, animated: true)
    } else {
      scrollView.contentOffset = offset
      moved(force: true)
    }
  }

  /// `zoom` is a multiple of the zoom the document opened at.
  func setZoom(_ zoom: CGFloat, animated: Bool) {
    guard let plan, viewport.ready else { return }
    let target = min(max(zoom, plan.minimumZoomScale), plan.maximumZoomScale)
    let middle = CGPoint(x: bounds.midX, y: bounds.midY)
    let anchor = CGPoint(
      x: viewport.screenToDocumentX(middle.x),
      y: viewport.screenToDocumentY(middle.y)
    )

    if animated {
      startZooming(to: target, about: anchor, under: middle)
      return
    }

    stopZooming()
    velocity = .zero
    lastMovedAt = 0
    scrollView.setZoomScale(target, animated: false)
    applyMargin()
    let scale = plan.scale(atZoom: target)
    scrollView.contentOffset = plan.clamp(
      CGPoint(x: anchor.x * scale - middle.x, y: anchor.y * scale - middle.y),
      atZoom: target
    )
    moved(force: true)
  }

  /**
   * How much of what is on screen has been drawn for the zoom it is shown at,
   * worked out whenever the tiles are, and read from anywhere.
   */
  private(set) var lastCoverage: CGFloat = 0

  private func measureCoverage() {
    guard let store else {
      lastCoverage = 0
      return
    }
    lastCoverage = grid.coverage(viewport, layout) { store.image($0) != nil }
  }

  func release() {
    stopZooming()
    closeDocument()
    canvas.clear()
    uri = nil
  }

  private func closeDocument() {
    stopZooming()
    let current = store
    store = nil
    plan = nil
    pageSizes = []
    layout = PdfDocumentLayout([])
    viewport.setDocument(layout)
    grid.clear()
    if let current {
      loader.async { current.close() }
    }
  }

  private func report(_ error: Error) {
    let failure = PdfFailure.from(error)
    DispatchQueue.main.async { [weak self] in self?.onFailure?(failure) }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      // An open PDF is a file handle and a page parsed into memory; a view that
      // has left the screen should be holding neither.
      let current = uri
      closeDocument()
      canvas.clear()
      uri = current
    } else if let current = uri, store == nil {
      let page = openAtPage
      uri = nil
      load(uri: current, headers: headers, password: password, cache: cache, page: page)
    }
  }

  // ─── Layout ─────────────────────────────────────────────────────────────────

  override func layoutSubviews() {
    super.layoutSubviews()
    scrollView.frame = bounds
    canvas.frame = bounds

    // How many pixels a point of the screen has, which is how large a tile is
    // drawn. Read here rather than when the view is made: a view that is not on
    // a screen yet has no screen to answer for.
    let ratio = traitCollection.displayScale
    if ratio > 0, ratio != pixelRatio {
      pixelRatio = ratio
      grid = PdfTileGrid(pixelRatio: ratio)
      if let plan { grid.setLadder(base: plan.baseScale) }
      store?.clear()
      ensureTiles(force: true)
    }

    guard bounds.size != viewSize else { return }
    viewSize = bounds.size
    viewport.setView(width: bounds.width, height: bounds.height)
    guard viewport.ready else { return }

    applyPlan()
    goToPage(openAtPage, animated: false)
    ensureTiles(force: true)
  }

  /**
   * Tells the scroll view what it is holding: how large the document is, how
   * far it may be zoomed either way, and where it opens.
   *
   * The zoom the document opens at is the scroll view's 1, so everything the
   * reader does is a multiple of how the document came up rather than of its
   * printed size, and a sheet thirteen metres wide and a letter page are the
   * same arithmetic.
   */
  private func applyPlan() {
    guard viewport.ready else { return }

    let plan = PdfScrollPlan(viewport: viewport)
    self.plan = plan
    // Every level is a multiple of the zoom the document opens at, so the grid
    // is told what that is before it is asked for anything.
    grid.setLadder(base: plan.baseScale)

    velocity = .zero
    lastMovedAt = 0

    scrollView.minimumZoomScale = plan.minimumZoomScale
    scrollView.maximumZoomScale = plan.maximumZoomScale
    scrollView.zoomScale = 1
    content.frame = CGRect(origin: .zero, size: plan.contentSize)
    scrollView.contentSize = plan.contentSize
    applyMargin()
    scrollView.contentOffset = plan.initialOffset

    plan.place(viewport, offset: scrollView.contentOffset, zoom: 1)
    grid.clear()
    grid.setLadder(base: plan.baseScale)
  }

  /// Holds a document smaller than the screen in the middle of it.
  private func applyMargin() {
    guard let plan else { return }
    let margin = plan.margin(atZoom: scrollView.zoomScale)
    let insets = UIEdgeInsets(
      top: margin.height,
      left: margin.width,
      bottom: margin.height,
      right: margin.width
    )
    guard insets != scrollView.contentInset else { return }
    scrollView.contentInset = insets
  }

  // ─── Movement ───────────────────────────────────────────────────────────────

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

  func scrollViewDidScroll(_ scrollView: UIScrollView) { moved() }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    applyMargin()
    moved()
  }

  func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
    applyMargin()
    moved(force: true)
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { stopZooming() }

  func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
    stopZooming()
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { settle() }
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }

  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }

  /**
   * The document has come to rest, so nothing is being looked ahead of, and the
   * ground around what is on screen is worth drawing before it is asked for.
   */
  private func settle() {
    velocity = .zero
    lastMovedAt = 0
    ensureTiles(force: true, margin: PdfTileGrid.restMargin)
  }

  /**
   * Where the scroll view has arrived, read into the viewport.
   *
   * The speed is measured from the movement itself rather than taken from the
   * pan gesture, because it has to cover the glide after the finger has left as
   * well, and that is what the tiles are asked for ahead of.
   */
  private func moved(force: Bool = false) {
    guard let plan else { return }

    let offset = scrollView.contentOffset
    let now = CACurrentMediaTime()
    let elapsed = now - lastMovedAt
    if lastMovedAt > 0, elapsed > 0.001 {
      velocity = CGPoint(
        x: -(offset.x - lastOffset.x) / elapsed,
        y: -(offset.y - lastOffset.y) / elapsed
      )
    }
    lastMovedAt = now
    lastOffset = offset

    plan.place(viewport, offset: offset, zoom: scrollView.zoomScale)
    notifyZoom()
    ensureTiles(force: force)
    redraw()
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
  private func notifyZoom() {
    let zoom = scrollView.zoomScale
    guard abs(zoom - reportedZoom) > reportedZoom * 0.005 else { return }

    let now = CACurrentMediaTime()
    guard now - lastZoomAt >= PdfSurface.zoomSecondsApart else {
      if !zoomQueued {
        zoomQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + PdfSurface.zoomSecondsApart) {
          [weak self] in
          self?.zoomQueued = false
          self?.notifyZoom()
        }
      }
      return
    }

    lastZoomAt = now
    reportedZoom = zoom
    onZoom?(zoom, viewport.scale)
  }

  // ─── Taps ───────────────────────────────────────────────────────────────────

  @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
    guard onTap != nil, viewport.ready else { return }
    let point = recognizer.location(in: self)
    let page = layout.pageAt(viewport.screenToDocumentY(point.y))
    onTap?(point.x, point.y, page)
  }

  /// A double tap, from where it is to where it is going, and what it turns about.
  private struct ZoomStep {
    let from: CGFloat
    let to: CGFloat
    /// The point of the document under the finger, which stays under it.
    let anchor: CGPoint
    let finger: CGPoint
    let started: CFTimeInterval
  }

  @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
    guard let plan, viewport.ready else { return }

    let finger = recognizer.location(in: self)
    velocity = .zero
    lastMovedAt = 0

    let anchor = CGPoint(
      x: viewport.screenToDocumentX(finger.x),
      y: viewport.screenToDocumentY(finger.y)
    )
    startZooming(to: plan.zoom(forScale: viewport.doubleTapTarget()), about: anchor, under: finger)
  }

  /**
   * Moves the zoom over a quarter of a second, a frame at a time.
   *
   * The scroll view can animate a zoom itself, and asking it to was the first
   * thing tried, but it does that with one animation on its content and tells
   * its delegate once. The document is not drawn inside it, so what the reader
   * saw was the page arriving at its new size in a single step. Stepped here,
   * every frame goes through the same path a finger does.
   */
  private func startZooming(to target: CGFloat, about anchor: CGPoint, under finger: CGPoint) {
    stopZooming()
    guard scrollView.zoomScale != target else { return }

    zoom = ZoomStep(
      from: scrollView.zoomScale,
      to: target,
      anchor: anchor,
      finger: finger,
      started: CACurrentMediaTime()
    )
    askForWhereItLands(zoom: target, anchor: anchor, finger: finger)

    let ticker = CADisplayLink(target: self, selector: #selector(stepZoom))
    ticker.add(to: .main, forMode: .common)
    self.ticker = ticker
  }

  @objc private func stepZoom() {
    guard let plan, let zoom else {
      stopZooming()
      return
    }

    let elapsed = CACurrentMediaTime() - zoom.started
    let through = min(1, elapsed / PdfSurface.zoomSeconds)
    // Slow at both ends, quickest in the middle, which is the shape Android's
    // animator uses and what a step of this size needs to read as one movement.
    let eased = through < 0.5
      ? 2 * through * through
      : 1 - pow(-2 * through + 2, 2) / 2

    let next = zoom.from + (zoom.to - zoom.from) * eased
    let scale = plan.scale(atZoom: next)
    scrollView.zoomScale = next
    scrollView.contentOffset = plan.clamp(
      CGPoint(x: zoom.anchor.x * scale - zoom.finger.x, y: zoom.anchor.y * scale - zoom.finger.y),
      atZoom: next
    )
    applyMargin()

    if through >= 1 {
      stopZooming()
      settle()
    }
  }

  private func stopZooming() {
    ticker?.invalidate()
    ticker = nil
    zoom = nil
    grid.stopAiming()
  }

  /**
   * Asks for the tiles of where the zoom is going, before it goes.
   *
   * Worked out from a viewport put where the movement will end, so that what is
   * asked for is the screenful that will be there rather than the one that is
   * there now, which at eight times the zoom is sixty times the tiles. While
   * the movement runs, nothing else is asked for: the renderers have exactly
   * the right work in front of them.
   */
  private func askForWhereItLands(zoom: CGFloat, anchor: CGPoint, finger: CGPoint) {
    guard let plan, let store else { return }

    let scale = plan.scale(atZoom: zoom)
    let landing = PdfViewport()
    landing.setDocument(layout)
    landing.setView(width: bounds.width, height: bounds.height)
    plan.place(
      landing,
      offset: plan.clamp(
        CGPoint(x: anchor.x * scale - finger.x, y: anchor.y * scale - finger.y),
        atZoom: zoom
      ),
      zoom: zoom
    )

    grid.aim(at: scale)
    grid.update(landing, layout)
    let visible = landing.visible()
    store.request(
      grid.missing(landing) { store.image($0) != nil },
      focusX: visible.x + visible.width / 2,
      focusY: visible.y + visible.height / 2
    )
    redraw()
  }

  // ─── Tiles ──────────────────────────────────────────────────────────────────

  private func ensureTiles(force: Bool = false, margin: CGFloat = PdfTileGrid.tileMargin) {
    guard let store, viewport.ready, layout.pageCount > 0 else { return }
    // A movement that knows where it is going has already asked for what it
    // needs, and what is on screen on the way there is not worth a renderer.
    guard zoom == nil else { return }

    let now = CACurrentMediaTime()
    if !force, now - lastEnsure < PdfSurface.ensureSeconds {
      if !ensureQueued {
        ensureQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + PdfSurface.ensureSeconds) {
          [weak self] in
          self?.ensureQueued = false
          self?.ensureTiles(force: true)
        }
      }
      return
    }
    lastEnsure = now

    grid.update(
      viewport,
      layout,
      velocityX: velocity.x,
      velocityY: velocity.y,
      margin: margin
    )

    let visible = viewport.visible()
    store.request(
      grid.missing(viewport) { store.image($0) != nil },
      focusX: visible.x + visible.width / 2,
      focusY: visible.y + visible.height / 2
    )

    // A page coming into view should never be a blank rectangle, so each one on
    // screen is asked for its own small drawing as well, unless the whole page
    // is already one of the tiles above.
    for page in layout.pagesIn(top: visible.y, bottom: visible.bottom)
    where !grid.drawsWholePage(page) {
      store.requestThumbnail(page.index, size: PageSize(width: page.width, height: page.height))
    }

    notifyPage(visible)
    measureCoverage()
    redraw()
  }

  private func redraw() {
    canvas.update(viewport: viewport, layout: layout, grid: grid, store: store)
  }

  /// The page the reader would say they are on: the one under the middle of the view.
  private func notifyPage(_ visible: PageRect) {
    let page = layout.pageAt(visible.y + visible.height / 2)
    guard page != reportedPage else { return }
    reportedPage = page
    onPageChange?(page, layout.pageCount)
  }

  private static let ensureSeconds: CFTimeInterval = 0.06

  /// How often the zoom is worth telling anyone about.
  private static let zoomSecondsApart: CFTimeInterval = 0.12
  private static let zoomSeconds: CFTimeInterval = 0.25
}
