import CoreGraphics

/**
 * The document as a scroll view has to be told about it.
 *
 * On iOS the reader's fingers are Apple's business: a `UIScrollView` carries
 * the pan, the momentum, the rubber band at the edges and the pinch, all of
 * which are better than anything written here would be, and all of which it
 * does in terms of a content size, a zoom scale and a content offset. This
 * turns a document and a screen into those three numbers, and back again.
 *
 * It is a separate, UIKit-free type because it is where a viewer drifts: a
 * document that opens half off the screen, a page that cannot be zoomed as far
 * as it should, a jump when a double tap lands. Those are all arithmetic, and
 * `PdfSdkTests.swift` asks about them without a simulator.
 *
 * The document opens at zoom 1, whatever that is in points: the scroll view's
 * scale is a multiple of how the document came up, not of its printed size.
 */
struct PdfScrollPlan {

  /// The document's bounding box, in its own points.
  let documentSize: CGSize
  let viewSize: CGSize

  /// Document points to screen points at zoom 1.
  let baseScale: CGFloat
  let minimumZoomScale: CGFloat
  let maximumZoomScale: CGFloat

  init(viewport: PdfViewport) {
    documentSize = CGSize(width: viewport.contentWidth, height: viewport.contentHeight)
    viewSize = CGSize(width: viewport.viewWidth, height: viewport.viewHeight)

    let floor = viewport.minScale()
    let ceiling = viewport.maxScale()
    // A page ten points tall would open at a zoom past the ceiling, so the
    // ceiling wins: zoom 1 has to be inside the range the scroll view allows.
    baseScale = min(max(viewport.restScale(), floor), ceiling)
    minimumZoomScale = min(1, floor / baseScale)
    maximumZoomScale = max(1, ceiling / baseScale)
  }

  /// The size of the content at zoom 1, which is what the scroll view is given.
  var contentSize: CGSize {
    CGSize(width: documentSize.width * baseScale, height: documentSize.height * baseScale)
  }

  func scale(atZoom zoom: CGFloat) -> CGFloat { baseScale * zoom }

  /// The zoom that reaches a given scale, as far as the range allows.
  func zoom(forScale scale: CGFloat) -> CGFloat {
    min(max(scale / baseScale, minimumZoomScale), maximumZoomScale)
  }

  /**
   * The space around a document smaller than the view, so that it sits in the
   * middle of it rather than against the top left corner.
   */
  func margin(atZoom zoom: CGFloat) -> CGSize {
    let scale = self.scale(atZoom: zoom)
    return CGSize(
      width: max(0, (viewSize.width - documentSize.width * scale) / 2),
      height: max(0, (viewSize.height - documentSize.height * scale) / 2)
    )
  }

  /**
   * Where the document sits when it opens: at the top, at its left edge when it
   * is wider than the screen, and in the middle of whichever direction it is
   * smaller than the screen in.
   */
  var initialOffset: CGPoint {
    let margin = self.margin(atZoom: 1)
    return CGPoint(x: -margin.width, y: -margin.height)
  }

  /// Holds an offset inside what the scroll view would allow at that zoom.
  func clamp(_ offset: CGPoint, atZoom zoom: CGFloat) -> CGPoint {
    let margin = self.margin(atZoom: zoom)
    let scale = self.scale(atZoom: zoom)
    let furthestX = max(-margin.width, documentSize.width * scale - viewSize.width + margin.width)
    let furthestY = max(-margin.height, documentSize.height * scale - viewSize.height + margin.height)
    return CGPoint(
      x: min(max(offset.x, -margin.width), furthestX),
      y: min(max(offset.y, -margin.height), furthestY)
    )
  }

  /// The offset that puts a point of the document in the middle of the view.
  func offset(atZoom zoom: CGFloat, centredOn point: CGPoint) -> CGPoint {
    let scale = self.scale(atZoom: zoom)
    return clamp(
      CGPoint(x: point.x * scale - viewSize.width / 2, y: point.y * scale - viewSize.height / 2),
      atZoom: zoom
    )
  }

  /// The offset that puts the top of a page at the top of the view.
  func offset(atZoom zoom: CGFloat, pageTop top: CGFloat, keepingX x: CGFloat) -> CGPoint {
    clamp(CGPoint(x: x, y: top * scale(atZoom: zoom)), atZoom: zoom)
  }

  /// What the viewport is looking at, given where the scroll view has arrived.
  func place(_ viewport: PdfViewport, offset: CGPoint, zoom: CGFloat) {
    viewport.place(scale: scale(atZoom: zoom), offsetX: -offset.x, offsetY: -offset.y)
  }
}
