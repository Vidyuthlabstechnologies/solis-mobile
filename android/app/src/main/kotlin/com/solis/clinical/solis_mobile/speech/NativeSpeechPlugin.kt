package com.solis.clinical.solis_mobile.speech

import android.app.Activity
import android.app.Application
import android.content.Context
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Flutter bridge for the on-device speech engine (sherpa-onnx).
 *
 * MethodChannel [METHOD_CHANNEL]:
 *   getCapabilities() -> {supported, abi, reason?, modelRoot, engineVersion, noiseSuppressor, autoGain,
 *       cores, sdk, freeBytes, maxMemoryBytes}
 *   getModelRoot() -> String (noBackupFilesDir/speech_models, created if needed)
 *   isReady({models}) -> bool (native library loads and every model file exists)
 *   sha256({path}) -> String (lowercase hex; runs off the main thread)
 *   extractArchive({archive, destDir, entries: {pathInArchive: fileName}})
 *       -> {fileName: {path, size, sha256}}; progress events while running
 *   start({models, numSpeakers?, finalPassMaxSeconds?, noiseSuppression?, autoGain?, asrThreads?, ...})
 *       -> {sessionId}
 *   pause() / resume() -> bool
 *   stop() -> {segments, method, numSpeakers, durationSec} after the final pass
 *   cancel() -> null (drops the session without a final pass)
 *
 * EventChannel [EVENT_CHANNEL] emits maps with a "type" key:
 *   status  {sessionId, status: loading|listening|paused|behind|finalizing|stopped|failed, progress?}
 *   start   {sessionId, sampleRate, loadMs}
 *   partial {sessionId, text, start?, end?, speakerIndex}  ("" clears it)
 *   segment {sessionId, segment: {id, speakerIndex, text, start, end, isFinal}}
 *   final   {sessionId, segments, method: pyannote|recluster|online|none, numSpeakers, durationSec}
 *   end     {sessionId}
 *   error   {sessionId?, code, message, fatal}
 *   modelProgress {stage: extract, file, done, total}
 */
class NativeSpeechPlugin private constructor(
    private val activity: Activity,
    engine: FlutterEngine,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val appContext: Context = activity.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
    private val events = EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
    private val io: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "solis-speech-io").apply { isDaemon = true } }
    private var sink: EventChannel.EventSink? = null
    private var session: SpeechSession? = null
    private var nextSessionId = 1
    private var disposed = false

    private val lifecycle = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityDestroyed(a: Activity) {
            if (a === activity) dispose()
        }

        override fun onActivityCreated(a: Activity, b: Bundle?) {}
        override fun onActivityStarted(a: Activity) {}
        override fun onActivityResumed(a: Activity) {}
        override fun onActivityPaused(a: Activity) {}
        override fun onActivityStopped(a: Activity) {}
        override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
    }

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        activity.application.registerActivityLifecycleCallbacks(lifecycle)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /** Thread-safe: posts to the main thread, where EventSink must be used. */
    private fun post(event: Map<String, Any?>) {
        main.post { if (!disposed) sink?.success(event) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        when (call.method) {
            "getCapabilities" -> result.success(capabilities())
            "getModelRoot" -> result.success(modelRoot().absolutePath)
            "isReady" -> {
                val models = ModelPaths.from(args?.get("models") as? Map<*, *>)
                result.success(nativeLibraryError() == null && models != null && models.missing().isEmpty())
            }
            "sha256" -> {
                val path = args?.get("path") as? String
                if (path == null) {
                    result.error("bad_args", "path is required", null)
                    return
                }
                runIo(result) {
                    val f = File(path)
                    if (!f.isFile) null else ModelFiles.sha256(f)
                }
            }
            "extractArchive" -> extract(args, result)
            "start" -> start(args, result)
            "pause" -> result.success(session?.pause() ?: false)
            "resume" -> result.success(session?.resume() ?: false)
            "stop" -> {
                val s = session
                if (s == null) {
                    result.success(mapOf("segments" to emptyList<Any>(), "method" to "none", "numSpeakers" to 0, "durationSec" to 0.0))
                    return
                }
                s.stop { payload ->
                    main.post {
                        if (session === s) session = null
                        result.success(payload)
                    }
                }
            }
            "cancel" -> {
                session?.cancel()
                session = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(args: Map<*, *>?, result: MethodChannel.Result) {
        val libError = nativeLibraryError()
        if (libError != null) {
            result.error("unsupported", libError, null)
            return
        }
        val config = SessionConfig.from(args)
        if (config == null) {
            result.error("bad_args", "models map is required", null)
            return
        }
        val missing = config.models.missing()
        if (missing.isNotEmpty()) {
            result.error("models_missing", "Speech models are not installed: ${missing.joinToString { File(it).name }}", null)
            return
        }
        val active = session
        if (active != null && active.state != SpeechSession.State.STOPPED && active.state != SpeechSession.State.FAILED) {
            result.error("busy", "A recording session is already running.", null)
            return
        }
        active?.cancel()
        val id = nextSessionId++
        val s = SpeechSession(id, appContext, config) { post(it) }
        session = s
        s.start()
        result.success(mapOf("sessionId" to id))
    }

    private fun extract(args: Map<*, *>?, result: MethodChannel.Result) {
        val archive = (args?.get("archive") as? String)?.let(::File)
        val dest = (args?.get("destDir") as? String)?.let(::File)
        val entries = (args?.get("entries") as? Map<*, *>)?.entries?.associate { it.key.toString() to it.value.toString() }
        if (archive == null || dest == null || entries.isNullOrEmpty()) {
            result.error("bad_args", "archive, destDir and entries are required", null)
            return
        }
        val root = modelRoot().canonicalFile
        if (!dest.canonicalPath.startsWith(root.path)) {
            result.error("bad_args", "destDir must be inside the model directory", null)
            return
        }
        runIo(result) {
            val out = ModelFiles.extractTarBz2(archive, dest, entries) { done, total ->
                post(mapOf("type" to "modelProgress", "stage" to "extract", "file" to archive.name, "done" to done, "total" to total))
            }
            out.mapValues { (_, v) -> mapOf("path" to v.path, "size" to v.size, "sha256" to v.sha256) }
        }
    }

    private fun runIo(result: MethodChannel.Result, block: () -> Any?) {
        try {
            io.execute {
                try {
                    val value = block()
                    main.post { result.success(value) }
                } catch (t: Throwable) {
                    main.post { result.error("io_error", t.message ?: t.javaClass.simpleName, null) }
                }
            }
        } catch (t: Throwable) {
            result.error("io_error", t.message, null)
        }
    }

    private fun capabilities(): Map<String, Any?> {
        val err = nativeLibraryError()
        return mapOf(
            "supported" to (err == null),
            "reason" to err,
            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
            "modelRoot" to modelRoot().absolutePath,
            "engineVersion" to ENGINE_VERSION,
            "noiseSuppressor" to safe { NoiseSuppressor.isAvailable() },
            "autoGain" to safe { AutomaticGainControl.isAvailable() },
            "cores" to Runtime.getRuntime().availableProcessors(),
            "freeBytes" to safeLong { StatFs(modelRoot().absolutePath).availableBytes },
            "maxMemoryBytes" to Runtime.getRuntime().maxMemory(),
            "sdk" to Build.VERSION.SDK_INT,
        )
    }

    private fun safe(f: () -> Boolean): Boolean = try {
        f()
    } catch (_: Throwable) {
        false
    }

    private fun safeLong(f: () -> Long): Long = try {
        f()
    } catch (_: Throwable) {
        -1L
    }

    /** App-private and excluded from Android backup, so models are not uploaded to Drive. */
    private fun modelRoot(): File = File(appContext.noBackupFilesDir, "speech_models").apply { mkdirs() }

    private fun dispose() {
        if (disposed) return
        disposed = true
        try {
            activity.application.unregisterActivityLifecycleCallbacks(lifecycle)
        } catch (_: Throwable) {
        }
        session?.cancel()
        session = null
        sink = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        io.shutdownNow()
    }

    companion object {
        const val METHOD_CHANNEL = "com.solis.clinical/native_speech"
        const val EVENT_CHANNEL = "com.solis.clinical/native_speech/events"
        const val ENGINE_VERSION = "sherpa-onnx 1.13.8"

        @Volatile
        private var libraryError: String? = null

        @Volatile
        private var libraryChecked = false

        /** Null when libsherpa-onnx-jni.so loads on this device, else the reason. */
        @Synchronized
        fun nativeLibraryError(): String? {
            if (!libraryChecked) {
                libraryChecked = true
                libraryError = try {
                    System.loadLibrary("sherpa-onnx-jni")
                    null
                } catch (t: Throwable) {
                    "On-device speech is not available on this device (${Build.SUPPORTED_ABIS.firstOrNull()}): ${t.message}"
                }
            }
            return libraryError
        }

        /** Registers the channels for [engine]; call once from configureFlutterEngine. */
        @JvmStatic
        fun register(activity: Activity, engine: FlutterEngine): NativeSpeechPlugin = NativeSpeechPlugin(activity, engine)
    }
}
