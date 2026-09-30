import Foundation
import NitroModules
import UIKit

/**
 * The view as React Native sees it. It holds the surface and passes on what
 * comes from JavaScript; everything that happens per frame stays inside the
 * surface.
 */
final class HybridPdfView: HybridNativePdfViewSpec {

  let view = PdfSurface(frame: .zero)

  /// Set while props are arriving, so the document and the page are read together.
  private var updating = false
  private var needsLoad = false

  override init() {
    super.init()

    view.onLoad = { [weak self] pageCount, width, height in
      self?.onLoad?(
        PdfLoadEvent(pageCount: Double(pageCount), width: Double(width), height: Double(height))
      )
    }
    view.onPageChange = { [weak self] page, pageCount in
      self?.onPageChange?(PdfPageEvent(page: Double(page), pageCount: Double(pageCount)))
    }
    view.onZoom = { [weak self] zoom, scale in
      self?.onZoom?(PdfZoomEvent(zoom: Double(zoom), scale: Double(scale)))
    }
    view.onFailure = { [weak self] failure in
      self?.onError?(PdfErrorEvent(code: failure.code.reported, message: failure.message))
    }
    view.onTap = { [weak self] x, y, page in
      self?.onTap?(PdfTapEvent(x: Double(x), y: Double(y), page: Double(page)))
    }
  }

  // ─── Props ──────────────────────────────────────────────────────────────────

  var source = PdfViewSource(uri: "", headers: nil, password: nil, cache: nil) {
    didSet { load() }
  }

  var page: Double = 0 {
    didSet { load() }
  }

  var fit: PdfFit = .auto {
    didSet { view.setFit(HybridPdfView.policy(for: fit)) }
  }

  /**
   * Zero means the viewer decides, on all three of these.
   *
   * They are not optional because React hands native a `null` when a property
   * is taken away and nitro reads only `undefined` as empty, so an optional
   * number would throw in the bridge the first time a caller passed a value
   * and then stopped. The wrapper in JavaScript fills the gaps.
   */
  var minZoom: Double = 0 {
    didSet { view.setZoomRange(min: asked(minZoom), max: asked(maxZoom)) }
  }

  var maxZoom: Double = 0 {
    didSet { view.setZoomRange(min: asked(minZoom), max: asked(maxZoom)) }
  }

  var doubleTapZoom: Double = 0 {
    didSet { view.setDoubleTapZoom(asked(doubleTapZoom)) }
  }

  var pageGap: Double = Double(PdfDocumentLayout.defaultGap) {
    didSet { view.setPageGap(CGFloat(pageGap)) }
  }

  var backdropColor: Double = 0 {
    didSet { view.setBackdropColor(UIColor.fromProcessedColor(backdropColor)) }
  }

  var scrollIndicators: Bool = true {
    didSet { view.setScrollIndicators(scrollIndicators) }
  }

  private func asked(_ value: Double) -> CGFloat? {
    value > 0 ? CGFloat(value) : nil
  }

  var onLoad: ((_ event: PdfLoadEvent) -> Void)?
  var onPageChange: ((_ event: PdfPageEvent) -> Void)?
  var onZoom: ((_ event: PdfZoomEvent) -> Void)?
  var onError: ((_ event: PdfErrorEvent) -> Void)?
  var onTap: ((_ event: PdfTapEvent) -> Void)?

  /**
   * The document and the page arrive as separate properties, so opening on the
   * first would open the old page of the new document. React updates props in
   * one batch, and they are read once the batch has landed.
   */
  func beforeUpdate() {
    updating = true
  }

  func afterUpdate() {
    updating = false
    if needsLoad { load() }
  }

  private func load() {
    if updating {
      needsLoad = true
      return
    }
    needsLoad = false

    let uri = source.uri
    guard !uri.isEmpty else { return }
    view.load(
      uri: uri,
      headers: source.headers ?? [:],
      password: source.password,
      cache: source.cache ?? true,
      page: page.isFinite ? Int(max(0, page)) : 0
    )
  }

  func onDropView() {
    view.release()
  }

  // ─── Methods ────────────────────────────────────────────────────────────────

  /**
   * Nitro calls these straight from JavaScript's own thread: there is no hop to
   * the screen's thread anywhere in its view layer. Touching a `UIScrollView`
   * or a layer tree from there is undefined behaviour, and blocks JavaScript
   * for as long as the work takes, which is how a single zoom cost half the
   * frames on both threads. So the work is handed to the main thread and the
   * call returns at once.
   */
  func goToPage(page: Double, animated: Bool) throws {
    guard page.isFinite else { return }
    onScreen { [view] in view.goToPage(Int(max(0, page)), animated: animated) }
  }

  func setZoom(zoom: Double, animated: Bool) throws {
    guard zoom.isFinite, zoom > 0 else { return }
    onScreen { [view] in view.setZoom(CGFloat(zoom), animated: animated) }
  }

  /// The last measurement the view made, which it takes on its own thread.
  func coverage() throws -> Double {
    Double(view.lastCoverage)
  }

  private func onScreen(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  /// The viewer's own idea of a fit, which knows nothing about the bridge.
  private static func policy(for fit: PdfFit) -> PdfFitPolicy {
    switch fit {
    case .width: return .width
    case .height: return .height
    case .page: return .page
    default: return .auto
    }
  }
}



private extension PdfFailureCode {
  var reported: PdfErrorCode {
    switch self {
    case .notFound: return .notfound
    case .password: return .password
    case .unsupported: return .unsupported
    case .network: return .network
    case .unknown: return .unknown
    }
  }
}

private extension UIColor {
  /// What React Native's `processColor` hands over: alpha, red, green, blue.
  static func fromProcessedColor(_ value: Double) -> UIColor? {
    guard value.isFinite, value != 0 else { return nil }
    let packed = UInt32(truncatingIfNeeded: Int64(value))
    return UIColor(
      red: CGFloat((packed >> 16) & 0xff) / 255,
      green: CGFloat((packed >> 8) & 0xff) / 255,
      blue: CGFloat(packed & 0xff) / 255,
      alpha: CGFloat((packed >> 24) & 0xff) / 255
    )
  }
}
