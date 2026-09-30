import Foundation
import NitroModules

/// Opens documents for whoever wants pictures of pages rather than a viewer.
final class HybridPdfSdk: HybridPdfSdkSpec {
  func open(path: String, password: String?) throws -> any HybridPdfDocumentSpec {
    let file = try PdfSourceLoader.localPath(for: path)
    return HybridPdfDocument(source: try PdfPageSource(path: file, password: password))
  }
}
