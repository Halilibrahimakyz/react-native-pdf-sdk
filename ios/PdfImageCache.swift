import CoreGraphics
import Foundation

/**
 * The drawn tiles, kept until the room runs out, oldest use first.
 *
 * `NSCache` was here and had to go: it evicts what it likes, and what it liked
 * was sometimes a tile being drawn on the screen every frame, which was then
 * asked for again, drawn again and evicted again. Least recently used is the
 * rule that suits a viewer, because every tile on screen is read on every
 * frame and so can never be the least recently used one.
 *
 * The same rule as Android's `LruCache`, which is what the Kotlin twin uses.
 */
final class PdfImageCache<Key: Hashable> {

  private struct Held {
    let image: CGImage
    let bytes: Int
    var used: UInt64
  }

  private let limit: Int
  private let lock = NSLock()
  private var held: [Key: Held] = [:]
  private var used: UInt64 = 0
  private(set) var bytes = 0

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func image(_ key: Key) -> CGImage? {
    lock.lock()
    defer { lock.unlock() }
    guard var entry = held[key] else { return nil }
    used += 1
    entry.used = used
    held[key] = entry
    return entry.image
  }

  func put(_ image: CGImage, for key: Key) {
    lock.lock()
    defer { lock.unlock() }

    let size = max(1, image.bytesPerRow * image.height)
    if let existing = held[key] { bytes -= existing.bytes }
    used += 1
    held[key] = Held(image: image, bytes: size, used: used)
    bytes += size
    evict(to: limit)
  }

  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    held.removeAll()
    bytes = 0
  }

  /// Under memory pressure, back down to a share of what is allowed.
  func trim(toShare share: Double) {
    lock.lock()
    defer { lock.unlock() }
    evict(to: Int(Double(limit) * share))
  }

  /// Called with the lock held. Few enough tiles that the oldest is found by
  /// looking, rather than by keeping a second structure in step.
  private func evict(to allowed: Int) {
    while bytes > allowed, held.count > 1 {
      var oldest: Key?
      var oldestUse = UInt64.max
      for (key, entry) in held where entry.used < oldestUse {
        oldestUse = entry.used
        oldest = key
      }
      guard let oldest, let gone = held.removeValue(forKey: oldest) else { return }
      bytes -= gone.bytes
    }
  }
}
