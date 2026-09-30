package com.margelo.nitro.pdfsdk

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfoProvider
import com.facebook.react.uimanager.ViewManager
import com.margelo.nitro.pdfsdk.views.HybridNativePdfViewManager

/**
 * Carries no modules of its own, and one view.
 *
 * The view manager has to be handed over here: the hybrid objects register
 * themselves when the native library loads, but a view also needs its manager
 * on the Java side. Without it react-native holds a description of the
 * component with nothing behind it, and the first layout pass reads a shadow
 * node that was never really ours.
 */
open class PdfSdkPackage : BaseReactPackage() {
  override fun getModule(
    name: String,
    reactContext: ReactApplicationContext,
  ): NativeModule? = null

  override fun getReactModuleInfoProvider(): ReactModuleInfoProvider = ReactModuleInfoProvider { HashMap() }

  override fun createViewManagers(reactContext: ReactApplicationContext): List<ViewManager<*, *>> =
    listOf(HybridNativePdfViewManager())

  companion object {
    init {
      PdfSdkOnLoad.initializeNative()
    }
  }
}
