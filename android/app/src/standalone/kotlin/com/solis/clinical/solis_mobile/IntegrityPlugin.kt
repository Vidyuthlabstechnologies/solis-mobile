package com.solis.clinical.solis_mobile

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Standalone build (installed from the website, not Google Play): there is no
 * Play Integrity library in this build. Every request reports UNAVAILABLE and
 * the app signs in without a token, as it does on phones without Play.
 */
class IntegrityPlugin(@Suppress("UNUSED_PARAMETER") context: Context) {
    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { _, result ->
            result.error("UNAVAILABLE", "standalone build", null)
        }
    }

    companion object {
        const val CHANNEL = "com.solis.clinical/integrity"
    }
}
