package com.margelo.nitro.pdfsdk

import android.graphics.Bitmap
import android.os.Handler
import android.os.HandlerThread
import android.util.LruCache
import kotlin.math.min

/**
 * Draws tiles away from the screen's thread and keeps the ones drawn.
 *
 * One at a time, because the renderer takes a page at a time anyway; what
 * matters is choosing the right next one, which is the tile nearest the middle
 * of what the reader is looking at. A tile that has left the view before its
 * turn came is dropped rather than drawn.
 *
 * Thumbnails are the same work at a lower priority: a whole page drawn small,
 * kept so that a page coming into view is never a blank rectangle. They are
 * drawn only once nothing sharper is waiting.
 */
class PdfTileStore(
  private val source: PdfPageSource,
  private val onTileReady: () -> Unit,
  private val onError: (Throwable) -> Unit,
) {
  private class Thumbnail(val page: Int, val size: PageSize, val outWidth: Int, val outHeight: Int)

  private val thread = HandlerThread("pdf-sdk-tiles").apply { start() }
  private val handler = Handler(thread.looper)

  private val tiles = object : LruCache<String, Bitmap>(cacheBytes()) {
    override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
  }

  /** A page's whole content, drawn small. Far cheaper to keep than a tile. */
  private val thumbnails = object : LruCache<Int, Bitmap>(THUMBNAIL_CACHE) {
    override fun sizeOf(key: Int, value: Bitmap): Int = value.byteCount
  }

  private val queue = LinkedHashMap<String, TileSpec>()
  private val thumbnailQueue = LinkedHashMap<Int, Thumbnail>()
  private var focusX = 0f
  private var focusY = 0f
  private var era = 0
  private var working = false
  private var closed = false

  fun bitmap(key: String): Bitmap? = tiles.get(key)

  fun thumbnail(page: Int): Bitmap? = thumbnails.get(page)

  /**
   * Takes the tiles the view wants. Anything asked for before and no longer
   * wanted is forgotten, so a drag does not leave a trail of work behind it.
   */
  fun request(specs: List<TileSpec>, focusX: Float, focusY: Float) {
    synchronized(queue) {
      if (closed) return
      this.focusX = focusX
      this.focusY = focusY

      val wanted = HashSet<String>(specs.size)
      for (spec in specs) {
        wanted.add(spec.key)
        if (tiles.get(spec.key) != null) continue
        queue[spec.key] = spec
      }
      queue.keys.retainAll(wanted)
    }
    pump()
  }

  /** Asks for the small drawing of a page, if it is not already held. */
  fun requestThumbnail(page: Int, size: PageSize) {
    synchronized(queue) {
      if (closed || thumbnails.get(page) != null || thumbnailQueue.containsKey(page)) return

      val aspect = if (size.height > 0f) size.width / size.height else 1f
      val height = kotlin.math.sqrt(THUMBNAIL_PIXELS / aspect)
      val width = height * aspect
      thumbnailQueue[page] = Thumbnail(
        page = page,
        size = size,
        outWidth = Math.max(1, Math.round(width)),
        outHeight = Math.max(1, Math.round(height)),
      )
    }
    pump()
  }

  /** Everything drawn so far belongs to another document. */
  fun clear() {
    synchronized(queue) {
      era++
      queue.clear()
      thumbnailQueue.clear()
    }
    tiles.evictAll()
    thumbnails.evictAll()
  }

  fun close() {
    synchronized(queue) {
      closed = true
      queue.clear()
      thumbnailQueue.clear()
    }
    tiles.evictAll()
    thumbnails.evictAll()
    thread.quitSafely()
  }

  private fun pump() {
    val tile: TileSpec?
    val thumbnail: Thumbnail?
    val currentEra: Int

    synchronized(queue) {
      if (closed || working) return
      currentEra = era
      tile = nearest()
      if (tile != null) {
        queue.remove(tile.key)
        thumbnail = null
      } else {
        // Nothing sharp is waiting, so a page's small drawing can have the thread.
        val next = thumbnailQueue.keys.firstOrNull()
        thumbnail = next?.let { thumbnailQueue.remove(it) }
      }
      working = tile != null || thumbnail != null
      if (!working) return
    }

    handler.post {
      try {
        if (!isStale(currentEra)) {
          if (tile != null) drawTile(tile, currentEra) else drawThumbnail(thumbnail!!, currentEra)
        }
      } catch (error: Throwable) {
        onError(error)
      } finally {
        synchronized(queue) { working = false }
        pump()
      }
    }
  }

  private fun drawTile(spec: TileSpec, currentEra: Int) {
    val bitmap = Bitmap.createBitmap(spec.outWidth, spec.outHeight, Bitmap.Config.ARGB_8888)
    source.render(spec.page, spec.source, bitmap)
    if (isStale(currentEra)) return
    tiles.put(spec.key, bitmap)
    onTileReady()
  }

  private fun drawThumbnail(thumbnail: Thumbnail, currentEra: Int) {
    val bitmap = Bitmap.createBitmap(thumbnail.outWidth, thumbnail.outHeight, Bitmap.Config.ARGB_8888)
    source.render(
      thumbnail.page,
      PageRect(0f, 0f, thumbnail.size.width, thumbnail.size.height),
      bitmap,
    )
    if (isStale(currentEra)) return
    thumbnails.put(thumbnail.page, bitmap)
    onTileReady()
  }

  private fun isStale(currentEra: Int): Boolean = synchronized(queue) { closed || era != currentEra }

  /**
   * The tile nearest what is being looked at, so the middle fills in first.
   * Between two tiles at much the same distance, the one on the page the
   * renderer already has open wins: opening a page is where the platform parses
   * it, and on a drawing that costs more than the tile itself.
   */
  private fun nearest(): TileSpec? {
    var best: TileSpec? = null
    var bestCost = Float.MAX_VALUE
    val open = source.openPageIndex
    for (spec in queue.values) {
      val dx = spec.rect.x + spec.rect.width / 2f - focusX
      val dy = spec.rect.y + spec.rect.height / 2f - focusY
      var cost = dx * dx + dy * dy
      if (spec.page != open) cost *= PAGE_SWITCH_COST
      if (cost < bestCost) {
        bestCost = cost
        best = spec
      }
    }
    return best
  }

  private companion object {
    /** A quarter of what the app may hold, and never more than this. */
    const val CACHE_CEILING = 96L * 1024 * 1024

    /** Thumbnails are small and there are few of them. */
    const val THUMBNAIL_CACHE = 8 * 1024 * 1024
    const val THUMBNAIL_PIXELS = 400_000f

    /**
     * How much further a tile has to be before it is preferred over one on the
     * page already open. A page has to be parsed before any of it can be drawn.
     */
    const val PAGE_SWITCH_COST = 4f

    fun cacheBytes(): Int =
      min(Runtime.getRuntime().maxMemory() / 4, CACHE_CEILING).toInt()
  }
}
