package com.margelo.nitro.pdfsdk

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream

/**
 * A PDF file, open, with one page open at a time.
 *
 * Opening a page is where the platform parses its content, and on a drawing
 * that is far more expensive than painting it, so the page most recently drawn
 * from is kept open. `PdfRenderer` allows one open page per instance and is not
 * safe across threads, hence the lock.
 */
class PdfPageSource(
  private val descriptor: ParcelFileDescriptor,
  password: String? = null,
) : Closeable {

  private val lock = Any()
  private val renderer: PdfRenderer

  private var openPage: PdfRenderer.Page? = null
  private var openIndex = -1
  private var closed = false

  init {
    renderer = try {
      open(descriptor, password)
    } catch (error: Throwable) {
      descriptor.close()
      throw error
    }
  }

  val pageCount: Int get() = renderer.pageCount

  /** Which page is open, so a caller can prefer work that needs no reopening. */
  val openPageIndex: Int get() = synchronized(lock) { openIndex }

  /** The page's size in points, a point being a 72nd of an inch. */
  fun pageSize(index: Int): Pair<Float, Float> = synchronized(lock) {
    val page = pageAt(index)
    page.width.toFloat() to page.height.toFloat()
  }

  /** Draws one part of a page into a bitmap that is already the right size. */
  fun render(index: Int, rect: PageRect, into: Bitmap) = synchronized(lock) {
    val page = pageAt(index)

    // Paper, not transparency: a PDF paints only what is on the page.
    into.eraseColor(Color.WHITE)

    val transform = Matrix()
    transform.setScale(into.width / rect.width, into.height / rect.height)
    transform.preTranslate(-rect.x, -rect.y)
    page.render(into, null, transform, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
  }

  override fun close() {
    synchronized(lock) {
      if (closed) return
      closed = true
      openPage?.close()
      openPage = null
      openIndex = -1
      renderer.close()
      descriptor.close()
    }
  }

  private fun pageAt(index: Int): PdfRenderer.Page {
    check(!closed) { "This document has been closed" }
    if (index < 0 || index >= renderer.pageCount) {
      throw PdfFailure.unknown("There is no page $index in a document of ${renderer.pageCount}")
    }

    openPage?.let { if (openIndex == index) return it }

    openPage?.close()
    val opened = renderer.openPage(index)
    openPage = opened
    openIndex = index
    return opened
  }

  private companion object {
    /**
     * Opens the renderer, with a password when the platform can take one.
     *
     * A password can only be handed over from Android 15; before that the
     * platform refuses an encrypted document outright, and says so here rather
     * than leaving the caller with a SecurityException to read.
     */
    fun open(descriptor: ParcelFileDescriptor, password: String?): PdfRenderer {
      try {
        if (password != null && Build.VERSION.SDK_INT >= 35) {
          val params = android.graphics.pdf.LoadParams.Builder().setPassword(password).build()
          return PdfRenderer(descriptor, params)
        }
        return PdfRenderer(descriptor)
      } catch (error: SecurityException) {
        throw PdfFailure.password(
          if (Build.VERSION.SDK_INT >= 35) "That password does not open this document"
          else "This document is encrypted, which Android cannot open before Android 15"
        )
      } catch (error: Throwable) {
        throw PdfFailure.unsupported("This file is not a PDF this device can read")
      }
    }

    /** Writes a bitmap out as a PNG, for the pictures the document object takes. */
    fun writePng(bitmap: Bitmap, path: String) {
      val file = File(path)
      file.parentFile?.mkdirs()
      FileOutputStream(file).use { out ->
        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) {
          throw PdfFailure.unknown("The image could not be written to $path")
        }
      }
    }
  }

  /** Draws a region of a page straight into a PNG file. */
  fun renderToFile(index: Int, rect: PageRect, outWidth: Int, outHeight: Int, path: String): String {
    val bitmap = Bitmap.createBitmap(outWidth, outHeight, Bitmap.Config.ARGB_8888)
    try {
      render(index, rect, bitmap)
      writePng(bitmap, path)
    } finally {
      bitmap.recycle()
    }
    return path
  }
}
