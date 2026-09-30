import UIKit

/**
 * What the reader sees: the pages, and the tiles drawn for them.
 *
 * One layer per page and one per tile, positioned from the viewport on every
 * pass. Layers rather than a `draw(_:)` of its own because the images are
 * already drawn by then: handing them to the compositor means a drag moves
 * finished pictures on the GPU, where redrawing them into a context would
 * refill the whole screen on the main thread at every frame.
 *
 * Nothing here decides anything. Where each tile goes is `PdfTileGrid`'s
 * answer, which is arithmetic and tested; this puts it on the screen.
 */
final class PdfTileCanvas: UIView {

  private var pageLayers: [Int: CALayer] = [:]
  private var tileLayers: [String: CALayer] = [:]

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    layer.masksToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("PdfTileCanvas is not built from a storyboard")
  }

  func update(
    viewport: PdfViewport,
    layout: PdfDocumentLayout,
    grid: PdfTileGrid,
    store: PdfTileStore?
  ) {
    guard let store, viewport.ready, viewport.scale > 0 else {
      clear()
      return
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    let visible = viewport.visible()

    // The pages themselves: a white sheet each, with the page's own small
    // drawing on it until the tiles for this zoom arrive. What falls between
    // two pages is left to whatever is behind this view.
    var livePages = Set<Int>()
    for page in layout.pagesIn(top: visible.y, bottom: visible.bottom) {
      let whole = CGRect(
        x: viewport.documentToScreenX(page.x),
        y: viewport.documentToScreenY(page.y),
        width: page.width * viewport.scale,
        height: page.height * viewport.scale
      )
      guard whole.width > 0, whole.height > 0 else { continue }

      // Clipped to the view, so that a sheet metres wide is not handed to the
      // compositor as a layer metres wide.
      let shown = whole.intersection(bounds)
      guard !shown.isNull, shown.width >= 0.5, shown.height >= 0.5 else { continue }

      livePages.insert(page.index)
      let layer = pageLayers[page.index] ?? makeLayer(white: true, key: page.index.description)
      pageLayers[page.index] = layer
      layer.frame = shown
      layer.zPosition = 0

      if let thumbnail = store.thumbnail(page.index) {
        layer.contents = thumbnail
        layer.contentsRect = share(of: shown, in: whole)
      } else if layer.contents != nil {
        layer.contents = nil
        layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
      }
    }

    // What was drawn for the zoom before this one keeps the screen covered
    // until the tiles for this one have arrived, so both are drawn, oldest
    // underneath.
    var liveTiles = Set<String>()
    let planned = grid.toDraw(viewport, layout) { store.image($0) != nil }
    for (order, tile) in planned.enumerated() {
      guard let image = store.image(tile.spec.key) else { continue }
      let frame = tile.destination.rect
      guard frame.width > 0, frame.height > 0, frame.intersects(bounds) else { continue }

      liveTiles.insert(tile.spec.key)
      let layer = tileLayers[tile.spec.key] ?? makeLayer(white: false, key: tile.spec.key)
      tileLayers[tile.spec.key] = layer
      layer.frame = frame
      layer.contents = image
      layer.zPosition = CGFloat(order + 1)
    }

    for (page, layer) in pageLayers where !livePages.contains(page) {
      layer.removeFromSuperlayer()
      pageLayers.removeValue(forKey: page)
    }
    for (key, layer) in tileLayers where !liveTiles.contains(key) {
      layer.removeFromSuperlayer()
      tileLayers.removeValue(forKey: key)
    }
  }

  func clear() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pageLayers.values.forEach { $0.removeFromSuperlayer() }
    tileLayers.values.forEach { $0.removeFromSuperlayer() }
    pageLayers.removeAll()
    tileLayers.removeAll()
    CATransaction.commit()
  }

  /// Which part of a page's picture is left after clipping it to the view.
  private func share(of shown: CGRect, in whole: CGRect) -> CGRect {
    CGRect(
      x: max(0, (shown.minX - whole.minX) / whole.width),
      y: max(0, (shown.minY - whole.minY) / whole.height),
      width: min(1, shown.width / whole.width),
      height: min(1, shown.height / whole.height)
    )
  }

  private func makeLayer(white: Bool, key: String) -> CALayer {
    let layer = CALayer()
    layer.name = key
    layer.anchorPoint = .zero
    layer.contentsGravity = .resize
    layer.magnificationFilter = .linear
    layer.minificationFilter = .linear
    layer.isOpaque = true
    // Two tiles meet on a fraction of a point. Left to antialias its edges,
    // each one fades into the other and the join shows as a seam.
    layer.allowsEdgeAntialiasing = false
    layer.edgeAntialiasingMask = []
    if white {
      layer.backgroundColor = UIColor.white.cgColor
    }
    self.layer.addSublayer(layer)
    return layer
  }
}
