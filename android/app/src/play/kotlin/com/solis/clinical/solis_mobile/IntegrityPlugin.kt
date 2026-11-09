package com.solis.clinical.solis_mobile

import android.content.Context
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Play Integrity (Standard API) for the sign-in calls.
 *
 * Dart asks for a token bound to a request hash; the SOLIS server decodes it
 * with Google and checks the verdicts. Any failure (no Play Store, no Google
 * Play services, not configured, quota) is reported as an error code and the
 * app signs in without a token; the server decides what that means.
 */
class IntegrityPlugin(private val context: Context) {
    private var provider: StandardIntegrityTokenProvider? = null
    private var providerProject: Long = 0

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestToken" -> {
                    val project = (call.argument<Any>("cloudProjectNumber") as? Number)?.toLong()
                        ?: call.argument<String>("cloudProjectNumber")?.toLongOrNull()
                    val hash = call.argument<String>("requestHash")
                    if (project == null || project <= 0 || hash.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "cloudProjectNumber and requestHash are required", null)
                        return@setMethodCallHandler
                    }
                    requestToken(project, hash, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun requestToken(project: Long, hash: String, result: MethodChannel.Result) {
        try {
            val ready = provider
            if (ready != null && providerProject == project) {
                request(ready, hash, result, retry = project)
                return
            }
            IntegrityManagerFactory.createStandard(context.applicationContext)
                .prepareIntegrityToken(PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(project).build())
                .addOnSuccessListener { p ->
                    provider = p
                    providerProject = project
                    request(p, hash, result, retry = 0)
                }
                .addOnFailureListener { e -> result.error("PREPARE_FAILED", e.javaClass.simpleName, null) }
        } catch (e: Throwable) {
            result.error("UNAVAILABLE", e.javaClass.simpleName, null)
        }
    }

    /** A cached provider can go stale; on failure it is prepared once more. */
    private fun request(p: StandardIntegrityTokenProvider, hash: String, result: MethodChannel.Result, retry: Long) {
        p.request(StandardIntegrityTokenRequest.builder().setRequestHash(hash).build())
            .addOnSuccessListener { t -> result.success(t.token()) }
            .addOnFailureListener { e ->
                if (retry > 0) {
                    provider = null
                    requestToken(retry, hash, result)
                } else {
                    result.error("REQUEST_FAILED", e.javaClass.simpleName, null)
                }
            }
    }

    companion object {
        const val CHANNEL = "com.solis.clinical/integrity"
    }
}
