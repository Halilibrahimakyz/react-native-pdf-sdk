package com.margelo.nitro.pdfsdk

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * Turns whatever the `source` prop holds into something the renderer can read.
 *
 * A url is fetched and kept, under a name made from the url itself, so opening
 * the same document twice reads it from disk the second time. A `content://`
 * url is opened where it is, since the other app that owns it has already
 * handed over the right to read it. Fetching happens on the caller's thread,
 * which is never the screen's.
 */
object PdfSourceLoader {

  fun open(
    context: Context,
    uri: String,
    headers: Map<String, String> = emptyMap(),
    cache: Boolean = true,
  ): ParcelFileDescriptor {
    val trimmed = uri.trim()
    if (trimmed.isEmpty()) throw PdfFailure.notFound("an empty source")

    val parsed = runCatching { Uri.parse(trimmed) }.getOrNull()
    return when (parsed?.scheme?.lowercase()) {
      null, "file" -> descriptor(File(parsed?.path ?: trimmed))
      "content" -> {
        val opened = try {
          context.contentResolver.openFileDescriptor(parsed, "r")
        } catch (error: Throwable) {
          throw PdfFailure.notFound(trimmed)
        }
        opened ?: throw PdfFailure.notFound(trimmed)
      }
      "http", "https" -> descriptor(fetched(context, trimmed, headers, cache))
      else ->
        if (trimmed.startsWith("/")) descriptor(File(trimmed))
        else throw PdfFailure.unsupported("${parsed?.scheme}:// is not something this viewer can open")
    }
  }

  /** Where a fetched document lives, which is also how it is found again. */
  fun cachedFile(context: Context, uri: String): File =
    File(File(context.cacheDir, "pdf-sdk"), "${name(uri)}.pdf")

  private fun descriptor(file: File): ParcelFileDescriptor {
    if (!file.isFile) throw PdfFailure.notFound(file.path)
    return try {
      ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    } catch (error: Throwable) {
      throw PdfFailure.notFound(file.path)
    }
  }

  private fun fetched(
    context: Context,
    uri: String,
    headers: Map<String, String>,
    cache: Boolean,
  ): File {
    val file = cachedFile(context, uri)
    if (cache && file.isFile && file.length() > 0) return file

    val connection = try {
      (URL(uri).openConnection() as HttpURLConnection).apply {
        connectTimeout = 30_000
        readTimeout = 60_000
        instanceFollowRedirects = true
        for ((name, value) in headers) setRequestProperty(name, value)
      }
    } catch (error: Throwable) {
      throw PdfFailure.network("$uri could not be reached", error)
    }

    try {
      val status = connection.responseCode
      if (status == 404) throw PdfFailure.notFound(uri)
      if (status !in 200..299) throw PdfFailure.network("$uri answered $status")

      file.parentFile?.mkdirs()
      val partial = File(file.path + ".part")
      connection.inputStream.use { incoming ->
        FileOutputStream(partial).use { out -> incoming.copyTo(out, 64 * 1024) }
      }
      if (file.exists()) file.delete()
      if (!partial.renameTo(file)) {
        partial.delete()
        throw PdfFailure.unknown("The document could not be kept at ${file.path}")
      }
      return file
    } catch (failure: PdfFailure) {
      throw failure
    } catch (error: Throwable) {
      throw PdfFailure.network("$uri could not be fetched", error)
    } finally {
      connection.disconnect()
    }
  }

  /** A name for a url that is the same every time and safe as a filename. */
  fun name(text: String): String {
    var hash = -0x340d631b7bdddcdbL // FNV-1a's offset basis
    for (byte in text.toByteArray()) {
      hash = hash xor (byte.toLong() and 0xff)
      hash *= 0x100000001b3L
    }
    return java.lang.Long.toUnsignedString(hash, 36) + "-" +
      Integer.toString(text.length, 36)
  }
}
