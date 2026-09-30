import Foundation

/// Why a document could not be shown, in terms a caller can branch on.
enum PdfFailureCode {
  case notFound
  case password
  case unsupported
  case network
  case unknown
}

struct PdfFailure: LocalizedError {
  let code: PdfFailureCode
  let message: String

  var errorDescription: String? { message }

  static func notFound(_ what: String) -> PdfFailure {
    PdfFailure(code: .notFound, message: "There is no PDF at \(what)")
  }

  static func unsupported(_ what: String) -> PdfFailure {
    PdfFailure(code: .unsupported, message: what)
  }

  static func password(_ what: String) -> PdfFailure {
    PdfFailure(code: .password, message: what)
  }

  static func network(_ what: String) -> PdfFailure {
    PdfFailure(code: .network, message: what)
  }

  static func unknown(_ what: String) -> PdfFailure {
    PdfFailure(code: .unknown, message: what)
  }

  /// Whatever came back from somewhere else, as one of ours.
  static func from(_ error: Error) -> PdfFailure {
    if let failure = error as? PdfFailure { return failure }
    return PdfFailure(
      code: .unknown,
      message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    )
  }
}
