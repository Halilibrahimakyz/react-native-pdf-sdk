import CoreGraphics
import Foundation
#if canImport(UIKit)
  import UIKit
#endif

/**
 * Draws tiles away from the screen's thread and keeps the ones drawn.
 *
 * Several at a time, through a renderer each. `CGPDFDocument` keeps nothing
 * between draws: a page's content is read again on every call, which on a
 * structural drawing is a tenth of a second whatever size is asked for. Drawn
 * one after another, a screenful of that arrives a tile at a time over several
 * seconds, which is what it looked like. Drawn through several open copies of
 * the same file, the same screenful arrives in a couple of passes. The copies
 * cost almost nothing: the file is mapped once by the system, and what is not
 * shared is the parsing, which is the part being done in parallel.
 *
 * Which tile comes next is the one nearest the middle of what the reader is
 * looking at, so the middle fills in first. A tile that has left the view
 * before its turn came is dropped rather than drawn.
 *
 * Thumbnails are the same work at a lower priority: a whole page drawn small,
 * kept so that a page coming into view is never a blank rectangle, and so that
 * there is something under a zoom that has outrun its tiles. They are drawn
 * only once nothing sharper is waiting.
 *
 * The Kotlin twin is `PdfTileStore.kt`, which draws on one thread because there
 * the platform keeps the open page parsed and a second thread would only wait
 * for it. `NSCache` stands in for Android's `LruCache`, and lets the system
 * take the images back under memory pressure, which costs nothing here: a tile
 * that has gone is asked for again.
 */
final class PdfTileStore {

  private struct Thumbnail {
    let page: Int
    let size: PageSize
    let outWidth: Int
    let outHeight: Int
  }

  private struct Job {
    let renderer: Int
    let era: Int
    let tile: TileSpec?
    let thumbnail: Thumbnail?
  }

  private let onTileReady: () -> Void
  private let onError: (Error) -> Void

  private let renderers: [PdfPageSource]
  private let renderQueue = DispatchQueue(
    label: "pdf-sdk-tiles",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private let lock = NSLock()

  private let tiles = PdfImageCache<String>(limit: PdfTileStore.cacheBytes())
  /// A page's whole content, drawn small. Far cheaper to keep than a tile.
  private let thumbnails = PdfImageCache<Int>(limit: PdfTileStore.thumbnailCache)

  private var idle: [Int]
  private var queue: [String: TileSpec] = [:]
  private var thumbnailQueue: [Thumbnail] = []
  private var focusX: CGFloat = 0
  private var focusY: CGFloat = 0
  private var era = 0
  private var closed = false

  init(
    path: String,
    password: String? = nil,
    onTileReady: @escaping () -> Void,
    onError: @escaping (Error) -> Void
  ) throws {
    self.onTileReady = onTileReady
    self.onError = onError

    // The first one is the document itself: if the file is missing, malformed
    // or locked, this is where that is found out.
    var pool = [try PdfPageSource(path: path, password: password)]
    while pool.count < PdfTileStore.renderers {
      guard let extra = try? PdfPageSource(path: path, password: password) else { break }
      pool.append(extra)
    }
    renderers = pool
    idle = Array(pool.indices)

    #if canImport(UIKit)
      // What is held is worth holding, but not worth being killed for.
      NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.tiles.trim(toShare: 0.25)
        self?.thumbnails.trim(toShare: 0.25)
      }
    #endif
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  var pageCount: Int { renderers[0].pageCount }

  /// Every page's size, read before the document is shown.
  func pageSizes() throws -> [PageSize] {
    try (0..<pageCount).map { try renderers[0].pageSize($0) }
  }

  func image(_ key: String) -> CGImage? { tiles.image(key) }

  func thumbnail(_ page: Int) -> CGImage? { thumbnails.image(page) }

  /**
   * Takes the tiles the view wants. Anything asked for before and no longer
   * wanted is forgotten, so a drag does not leave a trail of work behind it.
   */
  func request(_ specs: [TileSpec], focusX: CGFloat, focusY: CGFloat) {
    lock.lock()
    if closed {
      lock.unlock()
      return
    }
    self.focusX = focusX
    self.focusY = focusY

    var wanted = Set<String>(minimumCapacity: specs.count)
    for spec in specs {
      wanted.insert(spec.key)
      if tiles.image(spec.key) != nil { continue }
      queue[spec.key] = spec
    }
    queue = queue.filter { wanted.contains($0.key) }
    lock.unlock()

    pump()
  }

  /**
   * Asks for the small drawing of a page, if it is not already held.
   *
   * Small, but not as small as it sounds: the drawing costs what reading the
   * page costs, and almost nothing on top of that for the pixels, so it is
   * asked for at a size worth looking at while the tiles are on their way.
   */
  func requestThumbnail(_ page: Int, size: PageSize) {
    lock.lock()
    let held = closed
      || thumbnails.image(page) != nil
      || thumbnailQueue.contains { $0.page == page }
    if held {
      lock.unlock()
      return
    }

    let aspect = size.height > 0 ? size.width / size.height : 1
    var height = (PdfTileStore.thumbnailPixels / aspect).squareRoot()
    var width = height * aspect
    // A sheet twenty times wider than it is tall would ask for an image wider
    // than the GPU will hold, so the longer side is capped and the other
    // follows it.
    if width > PdfTileStore.thumbnailSide {
      width = PdfTileStore.thumbnailSide
      height = width / aspect
    }
    if height > PdfTileStore.thumbnailSide {
      height = PdfTileStore.thumbnailSide
      width = height * aspect
    }
    thumbnailQueue.append(
      Thumbnail(
        page: page,
        size: size,
        outWidth: max(1, Int(width.rounded())),
        outHeight: max(1, Int(height.rounded()))
      )
    )
    // Scrolling quickly through a long document asks for a page's drawing and
    // leaves it behind in the same breath. Only the pages asked for most
    // recently are near enough to the view to be worth a renderer.
    if thumbnailQueue.count > PdfTileStore.thumbnailsWaiting {
      thumbnailQueue.removeFirst(thumbnailQueue.count - PdfTileStore.thumbnailsWaiting)
    }
    lock.unlock()

    pump()
  }

  /// Everything drawn so far belongs to another document.
  func clear() {
    lock.lock()
    era += 1
    queue.removeAll()
    thumbnailQueue.removeAll()
    lock.unlock()
    tiles.removeAll()
    thumbnails.removeAll()
  }

  func close() {
    lock.lock()
    closed = true
    queue.removeAll()
    thumbnailQueue.removeAll()
    lock.unlock()
    tiles.removeAll()
    thumbnails.removeAll()
    renderers.forEach { $0.close() }
  }

  /// Hands out as much of what is waiting as there are renderers free for it.
  private func pump() {
    var started: [Job] = []

    lock.lock()
    while !closed, let renderer = idle.last {
      var tile: TileSpec?
      var thumbnail: Thumbnail?

      if let next = nearest() {
        queue.removeValue(forKey: next.key)
        tile = next
      } else if !thumbnailQueue.isEmpty {
        // Nothing sharp is waiting, so a page's small drawing can have a turn.
        thumbnail = thumbnailQueue.removeFirst()
      } else {
        break
      }

      idle.removeLast()
      started.append(Job(renderer: renderer, era: era, tile: tile, thumbnail: thumbnail))
    }
    lock.unlock()

    for job in started {
      renderQueue.async { [weak self] in
        guard let self else { return }
        do {
          if !self.isStale(job.era) {
            if let tile = job.tile {
              try self.drawTile(tile, through: job.renderer, job.era)
            } else if let thumbnail = job.thumbnail {
              try self.drawThumbnail(thumbnail, through: job.renderer, job.era)
            }
          }
        } catch {
          self.onError(error)
        }
        self.lock.lock()
        self.idle.append(job.renderer)
        self.lock.unlock()
        self.pump()
      }
    }
  }

  private func drawTile(_ spec: TileSpec, through renderer: Int, _ era: Int) throws {
    let image = try renderers[renderer].image(
      page: spec.page,
      rect: spec.source,
      pixelWidth: spec.outWidth,
      pixelHeight: spec.outHeight
    )
    guard !isStale(era) else { return }
    tiles.put(image, for: spec.key)
    ready()
  }

  private func drawThumbnail(_ thumbnail: Thumbnail, through renderer: Int, _ era: Int) throws {
    let image = try renderers[renderer].image(
      page: thumbnail.page,
      rect: PageRect(x: 0, y: 0, width: thumbnail.size.width, height: thumbnail.size.height),
      pixelWidth: thumbnail.outWidth,
      pixelHeight: thumbnail.outHeight
    )
    guard !isStale(era) else { return }
    thumbnails.put(image, for: thumbnail.page)
    ready()
  }

  /// The view is drawn on the screen's thread, wherever the tile came from.
  private func ready() {
    DispatchQueue.main.async { [onTileReady] in onTileReady() }
  }

  private func isStale(_ era: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed || self.era != era
  }

  /// The tile nearest what is being looked at. Called with the lock held.
  private func nearest() -> TileSpec? {
    var best: TileSpec?
    var bestCost = CGFloat.greatestFiniteMagnitude
    for spec in queue.values {
      let dx = spec.rect.x + spec.rect.width / 2 - focusX
      let dy = spec.rect.y + spec.rect.height / 2 - focusY
      let cost = dx * dx + dy * dy
      if cost < bestCost {
        bestCost = cost
        best = spec
      }
    }
    return best
  }

  /**
   * How many copies of the document are drawn through at once.
   *
   * Two of a phone's cores are the fast ones, and a third renderer is there to
   * keep them fed rather than to add a third core; beyond that the passes get
   * longer without the screen filling any sooner, and each copy is another
   * page being parsed into memory.
   */
  private static var renderers: Int {
    max(1, min(3, ProcessInfo.processInfo.activeProcessorCount - 1))
  }

  /**
   * A share of what the device has, and never more than this.
   *
   * A tile is six and a half megabytes and the worst screenful measured is
   * fifteen of them, so this is about twice what is on the screen at once, plus
   * the coarser levels drawn under it. Less than that and a tile being read
   * every frame can be thrown out to make room for the tile next to it, which
   * is the one thing a cache must never do.
   */
  private static let cacheCeiling = 192 * 1024 * 1024

  private static let thumbnailsWaiting = 4
  private static let thumbnailCache = 32 * 1024 * 1024
  private static let thumbnailPixels: CGFloat = 2_000_000
  private static let thumbnailSide: CGFloat = 8192

  private static func cacheBytes() -> Int {
    let share = Int(ProcessInfo.processInfo.physicalMemory / 12)
    return min(max(share, 48 * 1024 * 1024), cacheCeiling)
  }
}
