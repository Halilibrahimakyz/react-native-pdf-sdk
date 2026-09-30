import CoreGraphics
import Foundation
import NitroModules

/**
 * An open document, for taking pictures of pages.
 *
 * Drawing happens on a queue of its own: a page of a structural drawing takes a
 * tenth of a second to read whatever size is asked for, and that is not
 * something to do on the thread JavaScript runs on.
 */
final class HybridPdfDocument: HybridPdfDocumentSpec {

  private let source: PdfPageSource
  private let queue = DispatchQueue(label: "pdf-sdk-document", qos: .userInitiated)

  init(source: PdfPageSource) {
    self.source = source
    super.init()
  }

  var pageCount: Double { Double(source.pageCount) }

  func getPageSize(page: Double) throws -> PdfPageSize {
    guard page.isFinite, page >= 0 else { throw PdfFailure.unknown("There is no page \(page)") }
    let size = try source.pageSize(Int(page))
    return PdfPageSize(width: Double(size.width), height: Double(size.height))
  }

  func renderToFile(request: PdfRenderRequest) throws -> Promise<String> {
    guard request.page.isFinite, request.page >= 0 else {
      throw PdfFailure.unknown("There is no page \(request.page)")
    }
    guard request.outWidth >= 1, request.outHeight >= 1 else {
      throw PdfFailure.unknown("An image cannot be smaller than a pixel")
    }
    let page = Int(request.page)
    let size = try source.pageSize(page)
    let rect = PageRect(
      x: CGFloat(request.x ?? 0),
      y: CGFloat(request.y ?? 0),
      width: CGFloat(request.width ?? Double(size.width)),
      height: CGFloat(request.height ?? Double(size.height))
    )
    let pixelWidth = Int(request.outWidth)
    let pixelHeight = Int(request.outHeight)
    let path = request.path ?? HybridPdfDocument.temporaryFile()

    return Promise.parallel(queue) { [source] in
      let image = try source.image(
        page: page,
        rect: rect,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight
      )
      try PdfPageSource.writePNG(image, to: path)
      return path
    }
  }

  func close() throws {
    source.close()
  }

  private static func temporaryFile() -> String {
    let directory = FileManager.default
      .urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("pdf-sdk", isDirectory: true)
    return directory.appendingPathComponent("\(UUID().uuidString).png").path
  }
}
