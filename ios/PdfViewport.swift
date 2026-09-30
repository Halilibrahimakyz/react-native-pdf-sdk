import CoreGraphics

/**
 * How a document is sized when it opens, which is also what a zoom of 1 means.
 *
 * The twin of the `PdfFit` union in the JavaScript API, kept apart from it so
 * that everything deciding what the reader sees stays free of the bridge and
 * can be tested on a Mac.
 */
enum PdfFitPolicy {
  case auto
  case width
  case height
  case page
}

/**
 * Where the document sits on the screen, and everything that follows from it.
 *
 * Deliberately free of UIKit: this is the arithmetic that decides what the
 * reader sees, and it is worth being able to test on its own, on a Mac, without
 * a simulator. `PdfSdkTests.swift` does exactly that.
 *
 * `scale` is screen points to the document point, and the offsets are where the
 * document's top left corner sits in the view, so a point maps to
 * `point * scale + offset`.
 *
 * The one difference from the Kotlin twin: there, a scale is in device pixels,
 * because an Android view is measured in them. Here it is in screen points, the
 * unit UIKit lays out in, so the constants below are the Kotlin ones divided by
 * the three pixels a point of the screen has on the phones this runs on. The
 * zoom a reader gets is the same on both.
 *
 * Unlike the Kotlin twin, this does not hold the document against its edges or
 * move it: on iOS a `UIScrollView` owns the position, the momentum and the
 * pinch, and hands them here through `place`.
 */
final class PdfViewport {

  /// The document's bounding box: the widest page, and every page stacked up.
  private(set) var contentWidth: CGFloat = 0
  private(set) var contentHeight: CGFloat = 0

  /// The first page, which is what decides how the document opens.
  private(set) var firstPage = PageSize(width: 0, height: 0)

  private(set) var viewWidth: CGFloat = 0
  private(set) var viewHeight: CGFloat = 0

  private(set) var scale: CGFloat = 1
  private(set) var offsetX: CGFloat = 0
  private(set) var offsetY: CGFloat = 0

  /// What the document is fitted to when it opens.
  var fit: PdfFitPolicy = .auto

  /// How far it may be zoomed, in multiples of the zoom it opened at.
  var minZoom: CGFloat?
  var maxZoom: CGFloat?
  var doubleTapZoom: CGFloat?

  func setDocument(width: CGFloat, height: CGFloat, firstPage: PageSize) {
    contentWidth = width
    contentHeight = height
    self.firstPage = firstPage
  }

  func setDocument(_ layout: PdfDocumentLayout) {
    setDocument(width: layout.width, height: layout.height, firstPage: layout.firstPage)
  }

  /// A document of a single page, which is what most of the tests are about.
  func setPage(width: CGFloat, height: CGFloat) {
    setDocument(width: width, height: height, firstPage: PageSize(width: width, height: height))
  }

  func setView(width: CGFloat, height: CGFloat) {
    viewWidth = width
    viewHeight = height
  }

  var ready: Bool {
    contentWidth > 0 && contentHeight > 0 && viewWidth > 0 && viewHeight > 0
  }

  /**
   * The zoom that fits the document's width.
   *
   * Width rather than the whole document: a document is read by scrolling, and
   * fitting twelve pages on a phone would show twelve stamps.
   */
  func widthScale() -> CGFloat {
    guard ready else { return 1 }
    return viewWidth / contentWidth
  }

  /// The zoom that fills the height with the first page.
  func heightScale() -> CGFloat {
    guard ready, firstPage.height > 0 else { return widthScale() }
    return viewHeight / firstPage.height
  }

  /// The zoom that shows the whole of the first page.
  func pageScale() -> CGFloat {
    min(widthScale(), heightScale())
  }

  /**
   * The zoom a document opens at.
   *
   * Left to itself it fits the width, unless the first page is a strip rather
   * than a page: the formwork plans of a building arrive as one sheet thirteen
   * metres wide, and fitted to the width that is a line across the middle of
   * the screen. Those open filling the height instead, read by panning
   * sideways.
   */
  func restScale() -> CGFloat {
    guard ready else { return 1 }
    switch fit {
    case .width:
      return widthScale()
    case .height:
      return heightScale()
    case .page:
      return pageScale()
    case .auto:
      let width = widthScale()
      guard firstPage.height > 0 else { return width }
      return firstPage.height * width < viewHeight * PdfViewport.stripHeightShare
        ? heightScale()
        : width
    }
  }

  /**
   * The furthest a document can be zoomed in, in screen points to the point.
   *
   * A point is a 72nd of an inch, so this is about thirteen times the printed
   * sheet. It sounds excessive, and on an ordinary page it is; on a formwork
   * plan drawn at 1:50 it is where a dimension written along a beam becomes
   * comfortable rather than merely possible, and nobody is forced to go there.
   */
  func maxScale() -> CGFloat {
    let rest = restScale()
    if let maxZoom { return max(rest, rest * maxZoom) }
    return max(rest, max(PdfViewport.targetPointSize, widthScale() * PdfViewport.minZoomRange))
  }

  /**
   * As far out as it goes. Left to itself, far enough to see the widest page
   * whole, whatever zoom the document opened at.
   */
  func minScale() -> CGFloat {
    let rest = restScale()
    if let minZoom { return min(rest, rest * minZoom) }
    return min(rest, widthScale())
  }

  /**
   * Where a double tap should take the reader.
   *
   * Zoomed in at all, it goes back out to where the document opened; otherwise
   * it goes far enough in one tap to read what is written on the page, rather
   * than a polite step that leaves the reader pinching afterwards.
   */
  func doubleTapTarget() -> CGFloat {
    let rest = restScale()
    if scale > rest * 1.05 { return rest }
    if let doubleTapZoom { return min(maxScale(), rest * doubleTapZoom) }
    return min(maxScale(), max(rest * 3, PdfViewport.doubleTapScale))
  }

  /// Takes the position the scroll view has arrived at.
  func place(scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
    self.scale = scale
    self.offsetX = offsetX
    self.offsetY = offsetY
  }

  func documentToScreenX(_ point: CGFloat) -> CGFloat { point * scale + offsetX }
  func documentToScreenY(_ point: CGFloat) -> CGFloat { point * scale + offsetY }
  func screenToDocumentX(_ pixel: CGFloat) -> CGFloat { (pixel - offsetX) / scale }
  func screenToDocumentY(_ pixel: CGFloat) -> CGFloat { (pixel - offsetY) / scale }

  /// What is on screen, in document points, clipped to the document.
  func visible() -> PageRect {
    let left = max(0, screenToDocumentX(0))
    let top = max(0, screenToDocumentY(0))
    let right = min(contentWidth, screenToDocumentX(viewWidth))
    let bottom = min(contentHeight, screenToDocumentY(viewHeight))
    return PageRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
  }

  static let stripHeightShare: CGFloat = 0.3
  static let targetPointSize: CGFloat = 13
  static let minZoomRange: CGFloat = 8

  /// Where one double tap lands when the document is at rest, at the least.
  static let doubleTapScale: CGFloat = 4
}
