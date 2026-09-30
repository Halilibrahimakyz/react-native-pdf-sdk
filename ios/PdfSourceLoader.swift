import Foundation

/**
 * Turns whatever the `source` prop holds into a file on disk.
 *
 * A url is fetched and kept, under a name made from the url itself, so opening
 * the same document twice reads it from disk the second time. Fetching happens
 * on the caller's thread, which is never the screen's.
 */
enum PdfSourceLoader {

  static func localPath(
    for uri: String,
    headers: [String: String] = [:],
    cache: Bool = true
  ) throws -> String {
    let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw PdfFailure.notFound("an empty source") }

    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
      return try existing(at: trimmed)
    }

    switch scheme {
    case "file":
      return try existing(at: url.path)
    case "http", "https":
      return try fetched(url, headers: headers, cache: cache)
    default:
      // A plain Windows-less path with a colon in it is not a url; anything
      // else with a scheme is something this platform cannot open.
      if trimmed.hasPrefix("/") { return try existing(at: trimmed) }
      throw PdfFailure.unsupported("\(scheme):// is not something this viewer can open")
    }
  }

  /// Where a fetched document lives, which is also how it is found again.
  static func cachedFile(for url: URL) -> URL {
    let directory = FileManager.default
      .urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("pdf-sdk", isDirectory: true)
    return directory.appendingPathComponent("\(name(for: url.absoluteString)).pdf")
  }

  private static func existing(at path: String) throws -> String {
    let clean = path.removingPercentEncoding ?? path
    guard FileManager.default.fileExists(atPath: clean) else {
      throw PdfFailure.notFound(clean)
    }
    return clean
  }

  private static func fetched(_ url: URL, headers: [String: String], cache: Bool) throws -> String {
    let file = cachedFile(for: url)
    if cache, FileManager.default.fileExists(atPath: file.path) {
      return file.path
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 60
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

    var downloaded: URL?
    var failure: Error?
    var status = 0

    let waiting = DispatchSemaphore(value: 0)
    let task = URLSession.shared.downloadTask(with: request) { location, response, error in
      failure = error
      status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if let location {
        // The temporary file is gone the moment this returns, so it is moved
        // here rather than after the wait.
        let held = URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: held)
        downloaded = held
      }
      waiting.signal()
    }
    task.resume()
    waiting.wait()

    if let failure {
      throw PdfFailure.network("\(url.absoluteString) could not be fetched: \(failure.localizedDescription)")
    }
    guard let downloaded else {
      throw PdfFailure.network("\(url.absoluteString) answered nothing")
    }
    guard status == 0 || (200..<300).contains(status) else {
      try? FileManager.default.removeItem(at: downloaded)
      if status == 404 { throw PdfFailure.notFound(url.absoluteString) }
      throw PdfFailure.network("\(url.absoluteString) answered \(status)")
    }

    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.removeItem(at: file)
      }
      try FileManager.default.moveItem(at: downloaded, to: file)
    } catch {
      throw PdfFailure.unknown("The document could not be kept: \(error.localizedDescription)")
    }
    return file.path
  }

  /// A name for a url that is the same every time and safe as a filename.
  static func name(for text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return String(hash, radix: 36) + "-" + String(text.utf8.count, radix: 36)
  }
}
