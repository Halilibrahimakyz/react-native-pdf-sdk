package com.margelo.nitro.pdfsdk

import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.core.Promise
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/**
 * An open document, for taking pictures of pages.
 *
 * Drawing happens on a thread of its own: opening a page of a structural
 * drawing is a third of a second, and that is not something to do on the thread
 * JavaScript runs on.
 */
@DoNotStrip
@Keep
class HybridPdfDocument(
  private val source: PdfPageSource,
  private val cacheDirectory: String,
) : HybridPdfDocumentSpec() {

  private val worker = Executors.newSingleThreadExecutor { runnable ->
    Thread(runnable, "pdf-sdk-document")
  }

  override val pageCount: Double get() = source.pageCount.toDouble()

  override fun getPageSize(page: Double): PdfPageSize {
    require(page.isFinite() && page >= 0) { "There is no page $page" }
    val (width, height) = source.pageSize(page.toInt())
    return PdfPageSize(width.toDouble(), height.toDouble())
  }

  override fun renderToFile(request: PdfRenderRequest): Promise<String> {
    require(request.page.isFinite() && request.page >= 0) { "There is no page ${request.page}" }
    require(request.outWidth >= 1 && request.outHeight >= 1) {
      "An image cannot be smaller than a pixel"
    }

    val page = request.page.toInt()
    val (width, height) = source.pageSize(page)
    val rect = PageRect(
      x = (request.x ?: 0.0).toFloat(),
      y = (request.y ?: 0.0).toFloat(),
      width = (request.width ?: width.toDouble()).toFloat(),
      height = (request.height ?: height.toDouble()).toFloat(),
    )
    val path = request.path ?: File(
      File(cacheDirectory, "pdf-sdk"),
      "${UUID.randomUUID()}.png",
    ).path

    val promise = Promise<String>()
    worker.execute {
      try {
        promise.resolve(
          source.renderToFile(page, rect, request.outWidth.toInt(), request.outHeight.toInt(), path)
        )
      } catch (error: Throwable) {
        promise.reject(error)
      }
    }
    return promise
  }

  override fun close() {
    source.close()
    worker.shutdown()
  }
}
