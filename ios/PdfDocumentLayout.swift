import CoreGraphics

/// A page's size in PDF points, a point being a 72nd of an inch.
struct PageSize: Equatable {
  let width: CGFloat
  let height: CGFloat

  init(width: CGFloat, height: CGFloat) {
    self.width = width
    self.height = height
  }
}

/// A rectangle of the document, in points.
struct PageRect: Equatable {
  let x: CGFloat
  let y: CGFloat
  let width: CGFloat
  let height: CGFloat

  var right: CGFloat { x + width }
  var bottom: CGFloat { y + height }

  init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

/// Where a page sits in the document, in document points.
struct PageBox: Equatable {
  let index: Int
  let x: CGFloat
  let y: CGFloat
  let width: CGFloat
  let height: CGFloat

  var right: CGFloat { x + width }
  var bottom: CGFloat { y + height }
  var rect: PageRect { PageRect(x: x, y: y, width: width, height: height) }
}

/**
 * The pages of a document, laid out one under another.
 *
 * A reader scrolls through a document; they do not press a button to turn a
 * page. So the pages are placed in one coordinate space, with a gap between
 * them, and everything above this works on that space rather than on a page.
 * The gap is in points and therefore grows with the zoom, which is what keeps
 * it looking like the same gap at every size.
 *
 * Pages narrower than the widest one are centred, the way every viewer draws a
 * document whose pages are not all the same shape.
 *
 * The Kotlin twin of this file is `PdfDocumentLayout.kt`. The two are kept the
 * same deliberately: the viewer should not open a document differently
 * depending on the phone it is opened on, and a difference between the two is a
 * bug in one of them.
 */
final class PdfDocumentLayout {

  let pages: [PageBox]
  let width: CGFloat
  let height: CGFloat
  private let gap: CGFloat

  init(_ sizes: [PageSize], gap: CGFloat = PdfDocumentLayout.defaultGap) {
    self.gap = gap

    let widest = sizes.map(\.width).max() ?? 0
    var top: CGFloat = 0
    var boxes: [PageBox] = []
    boxes.reserveCapacity(sizes.count)

    for (index, size) in sizes.enumerated() {
      boxes.append(
        PageBox(
          index: index,
          x: (widest - size.width) / 2,
          y: top,
          width: size.width,
          height: size.height
        )
      )
      top += size.height + gap
    }

    pages = boxes
    width = widest
    height = max(0, top - gap)
  }

  var pageCount: Int { pages.count }

  var firstPage: PageSize {
    guard let first = pages.first else { return PageSize(width: 0, height: 0) }
    return PageSize(width: first.width, height: first.height)
  }

  /**
   * The pages that any part of the given band of the document falls on.
   *
   * Found rather than filtered for: this is asked several times a frame, once
   * per level drawn, and a document of five hundred pages should not be walked
   * end to end each time. The pages are in order down the document, so the
   * first one in the band can be looked up.
   */
  func pagesIn(top: CGFloat, bottom: CGFloat) -> [PageBox] {
    guard !pages.isEmpty, bottom >= top else { return [] }

    var low = 0
    var high = pages.count
    while low < high {
      let middle = (low + high) / 2
      if pages[middle].bottom < top { low = middle + 1 } else { high = middle }
    }

    var band: [PageBox] = []
    var index = low
    while index < pages.count, pages[index].y <= bottom {
      band.append(pages[index])
      index += 1
    }
    return band
  }

  /**
   * The page a reader would say they are on: the one holding the middle of what
   * is on screen, or the nearest one when the middle falls in a gap.
   */
  func pageAt(_ y: CGFloat) -> Int {
    guard let last = pages.last else { return 0 }
    for page in pages {
      if y <= page.bottom { return page.index }
      guard page.index + 1 < pages.count else { return page.index }
      let next = pages[page.index + 1]
      // In the gap between two pages, whichever edge is nearer.
      if y < next.y {
        return y - page.bottom <= next.y - y ? page.index : next.index
      }
    }
    return last.index
  }

  /// The same document with one page's real size in place of the assumed one.
  func withPageSize(_ index: Int, _ size: PageSize) -> PdfDocumentLayout {
    var sizes = self.sizes()
    guard sizes.indices.contains(index) else { return self }
    guard sizes[index] != size else { return self }
    sizes[index] = size
    return PdfDocumentLayout(sizes, gap: gap)
  }

  func sizes() -> [PageSize] {
    pages.map { PageSize(width: $0.width, height: $0.height) }
  }

  /**
   * The gap between two pages, in points: about a fifth of an inch, which is
   * enough to read as a break between sheets without wasting the screen.
   */
  static let defaultGap: CGFloat = 14

  /// A document of one page, for the moment before the rest have been measured.
  static func of(
    _ size: PageSize,
    pageCount: Int,
    gap: CGFloat = PdfDocumentLayout.defaultGap
  ) -> PdfDocumentLayout {
    PdfDocumentLayout(Array(repeating: size, count: max(1, pageCount)), gap: gap)
  }
}
