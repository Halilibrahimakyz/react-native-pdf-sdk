package com.margelo.nitro.pdfsdk

import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.NitroModules

/** Opens documents for whoever wants pictures of pages rather than a viewer. */
@DoNotStrip
@Keep
class HybridPdfSdk : HybridPdfSdkSpec() {
  override fun open(path: String, password: String?): HybridPdfDocumentSpec {
    val context = NitroModules.applicationContext
      ?: throw PdfFailure.unknown("There is no application to open a document in")
    val descriptor = PdfSourceLoader.open(context, path)
    return HybridPdfDocument(PdfPageSource(descriptor, password), context.cacheDir.path)
  }
}
