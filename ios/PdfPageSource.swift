import CoreGraphics
import Foundation
import ImageIO
#if canImport(UniformTypeIdentifiers)
  import UniformTypeIdentifiers
#endif

/**
 * Where a page's own coordinates are, and which way up it is.
 *
 * A PDF page is not a rectangle starting at zero: it has a box that may start
 * anywhere, and a rotation the reader is meant to see it through. Both have to
 * be undone before a part of the page can be asked for in the plain top left
 * coordinates the rest of this package works in.
 *
 * Kept as a value with no renderer in it so the arithmetic can be tested.
 */
struct PdfPageGeometry {
  /// The page's box, in its own coordinates, y upwards.
  let box: CGRect
  /// A quarter turn clockwise each, as the file asks for: 0, 90, 180 or 270.
  let rotation: Int

  init(box: CGRect, rotation: Int) {
    self.box = box.standardized
    var turns = rotation % 360
    if turns < 0 { turns += 360 }
    self.rotation = (turns / 90) * 90
  }

  /// The size the reader sees, which is the box with the rotation applied.
  var size: PageSize {
    let turned = rotation == 90 || rotation == 270
    return PageSize(
      width: turned ? box.height : box.width,
      height: turned ? box.width : box.height
    )
  }

  /**
   * Maps the page's own coordinates onto `(0, 0, size.width, size.height)`,
   * y still upwards, with the rotation applied.
   */
  var transform: CGAffineTransform {
    let localise = CGAffineTransform(translationX: -box.minX, y: -box.minY)
    let width = box.width
    let height = box.height
    let turn: CGAffineTransform
    switch rotation {
    case 90:
      turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
    case 180:
      turn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
    case 270:
      turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
    default:
      turn = .identity
    }
    return localise.concatenating(turn)
  }
}

/**
 * A PDF file, open, drawn from one part of one page at a time.
 *
 * `CGPDFDocument` is not safe across threads, hence the lock. It also keeps
 * nothing between draws: a page's content is read again on every call, which on
 * a structural drawing is a tenth of a second whatever size is asked for, and
 * is why the store above opens several of these and draws through them at once.
 */
final class PdfPageSource: @unchecked Sendable {

  private let lock = NSLock()
  private let document: CGPDFDocument

  private var geometries: [Int: PdfPageGeometry] = [:]
  private var closed = false

  init(path: String, password: String? = nil) throws {
    let clean = path.hasPrefix("file://")
      ? (URL(string: path)?.path ?? path)
      : path

    guard FileManager.default.fileExists(atPath: clean) else {
      throw PdfFailure.notFound(clean)
    }
    guard let opened = CGPDFDocument(URL(fileURLWithPath: clean) as CFURL) else {
      throw PdfFailure.unsupported("The file at \(clean) is not a PDF this device can read")
    }

    // An owner password alone is opened with an empty one, which is most of the
    // documents that call themselves encrypted. A reader's password is not.
    if opened.isEncrypted, !opened.isUnlocked {
      let unlocked = password.map { word in
        word.withCString { opened.unlockWithPassword($0) }
      } ?? false
      guard unlocked else {
        throw PdfFailure.password(
          password == nil
            ? "This document is encrypted and needs a password"
            : "That password does not open this document"
        )
      }
    }
    guard opened.numberOfPages > 0 else {
      throw PdfFailure.unsupported("This document has no pages")
    }
    document = opened
  }

  var pageCount: Int { document.numberOfPages }

  /// The page's size in points, a point being a 72nd of an inch.
  func pageSize(_ index: Int) throws -> PageSize {
    lock.lock()
    defer { lock.unlock() }
    return try geometry(index).size
  }

  /**
   * Draws one part of one page, at the size asked for.
   *
   * `rect` is in the page's points with the origin at its top left corner,
   * which is how the layout above thinks; the page itself is drawn upwards from
   * its bottom left, which is what the flip below is for.
   */
  func image(page index: Int, rect: PageRect, pixelWidth: Int, pixelHeight: Int) throws -> CGImage {
    lock.lock()
    defer { lock.unlock() }

    guard !closed else { throw PdfFailure.unknown("This document has been closed") }
    let geometry = try self.geometry(index)
    guard let page = document.page(at: index + 1) else {
      throw PdfFailure.unknown("There is no page \(index) in a document of \(document.numberOfPages)")
    }
    guard rect.width > 0, rect.height > 0, pixelWidth > 0, pixelHeight > 0 else {
      throw PdfFailure.unknown("A page cannot be drawn into nothing")
    }

    guard
      let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue
      )
    else {
      throw PdfFailure.unknown("The page could not be drawn")
    }

    // Paper, not transparency: a PDF paints only what is on the page.
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

    context.interpolationQuality = .high
    context.setShouldAntialias(true)

    // A bitmap context counts upwards from the bottom, as a page does, so the
    // region's distance from the bottom is what puts it at the origin.
    let fromBottom = geometry.size.height - (rect.y + rect.height)
    context.scaleBy(x: CGFloat(pixelWidth) / rect.width, y: CGFloat(pixelHeight) / rect.height)
    context.translateBy(x: -rect.x, y: -fromBottom)
    context.concatenate(geometry.transform)
    context.drawPDFPage(page)

    guard let image = context.makeImage() else {
      throw PdfFailure.unknown("The page could not be drawn")
    }
    return image
  }

  func close() {
    lock.lock()
    defer { lock.unlock() }
    closed = true
    geometries.removeAll()
  }

  /// Writes an image out as a PNG, for the pictures the document object takes.
  static func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard
      let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else {
      throw PdfFailure.unknown("Nothing could be written to \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw PdfFailure.unknown("The image could not be written to \(path)")
    }
  }

  private func geometry(_ index: Int) throws -> PdfPageGeometry {
    if let held = geometries[index] { return held }
    guard index >= 0, index < document.numberOfPages, let page = document.page(at: index + 1) else {
      throw PdfFailure.unknown(
        "There is no page \(index) in a document of \(document.numberOfPages)"
      )
    }

    var box = page.getBoxRect(.cropBox)
    if box.isEmpty || box.isNull || box.isInfinite {
      box = page.getBoxRect(.mediaBox)
    }
    if box.isEmpty || box.isNull || box.isInfinite {
      throw PdfFailure.unsupported("Page \(index) has no size this viewer can read")
    }

    let geometry = PdfPageGeometry(box: box, rotation: Int(page.rotationAngle))
    geometries[index] = geometry
    return geometry
  }
}
