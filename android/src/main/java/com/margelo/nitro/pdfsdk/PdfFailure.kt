package com.margelo.nitro.pdfsdk

/** Why a document could not be shown, in terms a caller can branch on. */
enum class PdfFailureCode {
  NOT_FOUND,
  PASSWORD,
  UNSUPPORTED,
  NETWORK,
  UNKNOWN,
}

class PdfFailure(
  val code: PdfFailureCode,
  override val message: String,
  cause: Throwable? = null,
) : RuntimeException(message, cause) {

  companion object {
    fun notFound(what: String) = PdfFailure(PdfFailureCode.NOT_FOUND, "There is no PDF at $what")

    fun unsupported(what: String) = PdfFailure(PdfFailureCode.UNSUPPORTED, what)

    fun password(what: String) = PdfFailure(PdfFailureCode.PASSWORD, what)

    fun network(what: String, cause: Throwable? = null) =
      PdfFailure(PdfFailureCode.NETWORK, what, cause)

    fun unknown(what: String, cause: Throwable? = null) =
      PdfFailure(PdfFailureCode.UNKNOWN, what, cause)

    /** Whatever came back from somewhere else, as one of ours. */
    fun from(error: Throwable): PdfFailure =
      error as? PdfFailure
        ?: PdfFailure(PdfFailureCode.UNKNOWN, error.message ?: error.toString(), error)
  }
}
