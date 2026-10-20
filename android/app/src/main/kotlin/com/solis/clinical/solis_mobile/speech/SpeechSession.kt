package com.solis.clinical.solis_mobile.speech

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Process
import android.os.SystemClock
import com.k2fsa.sherpa.onnx.FastClusteringConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineMoonshineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineSpeakerDiarization
import com.k2fsa.sherpa.onnx.OfflineSpeakerDiarizationConfig
import com.k2fsa.sherpa.onnx.OfflineSpeakerSegmentationModelConfig
import com.k2fsa.sherpa.onnx.OfflineSpeakerSegmentationPyannoteModelConfig
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.SpeakerEmbeddingExtractor
import com.k2fsa.sherpa.onnx.SpeakerEmbeddingExtractorConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicInteger

/**
 * One recording: microphone capture, live recognition with speaker labels,
 * and the final diarization pass on stop.
 *
 * Threads:
 * - "solis-speech-mic" reads AudioRecord in 100 ms blocks and hands each block
 *   to the worker. It never runs models.
 * - "solis-speech-N" (single-threaded executor) owns every native object
 *   (VAD, recognizer, embedding extractor, diarizer) and the audio buffer, so
 *   none of them needs locking. Blocks are processed in order.
 * - Control calls (start, pause, resume, stop) come from the main thread.
 *   Events are handed to [emit], which posts them to the main thread.
 *
 * Pipeline per block: Silero VAD cuts speech into utterances (at most 7 s,
 * split again to stay under [MAX_ASR_SECONDS]); each utterance is decoded by
 * Moonshine and embedded by CAM++; [OnlineSpeakerClusterer] gives it a voice
 * index right away. While someone is talking, the open utterance is decoded
 * every 0.5 to 3 s for partial text. On stop, pyannote segmentation plus CAM++
 * clustering runs over the whole recording and [DiarizationMerger] re-labels
 * (and where needed splits) the utterances.
 */
internal class SpeechSession(
    val id: Int,
    private val context: Context,
    private val config: SessionConfig,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    enum class State { LOADING, LISTENING, PAUSED, FINALIZING, STOPPED, FAILED }

    @Volatile
    var state: State = State.LOADING
        private set

    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            r.run()
        }, "solis-speech-$id").apply { isDaemon = true }
    }
    private val backlog = AtomicInteger(0)
    private val pauseLock = Object()

    @Volatile private var running = false
    @Volatile private var paused = false
    @Volatile private var modelsReady = false
    private var recorder: AudioRecord? = null
    private var recorderThread: Thread? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var gainControl: AutomaticGainControl? = null

    // Worker-thread state.
    private var recognizer: OfflineRecognizer? = null
    private var vad: Vad? = null
    private var extractor: SpeakerEmbeddingExtractor? = null
    private val store = AudioStore(config.finalPassMaxSeconds.toLong() * SAMPLE_RATE)
    private val recent = RecentAudio(SAMPLE_RATE * 10)
    private val clusterer = OnlineSpeakerClusterer(config.numSpeakers, config.maxSpeakers, config.newSpeakerThreshold)
    private val utterances = ArrayList<Utterance>()
    private var nextUtteranceId = 0
    private var lastSpeaker = 0
    private val window = FloatArray(VAD_WINDOW)
    private var windowFill = 0
    private var vadBase = 0L
    private var speechActive = false
    private var speechStart = 0L
    private var lastSegmentEnd = 0L
    private var lastPartialAt = 0L
    private var partialIntervalSamples = SAMPLE_RATE / 2
    private var partialShown = false
    private var behindReported = false
    private var released = false

    // ---------------------------------------------------------------- control

    /** Starts capture right away (audio queues while models load). Main thread. */
    fun start() {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            fail("permission_denied", "Microphone permission has not been granted.")
            return
        }
        emitStatus("loading")
        submit { loadModels() }
        if (!startRecorder()) return
    }

    fun pause(): Boolean {
        if (state != State.LISTENING && state != State.LOADING) return false
        paused = true
        try {
            recorder?.stop()
        } catch (_: Exception) {
        }
        state = State.PAUSED
        submit { closeOpenSpeech() }
        emitStatus("paused")
        return true
    }

    fun resume(): Boolean {
        if (state != State.PAUSED) return false
        try {
            recorder?.startRecording()
        } catch (e: Exception) {
            emitError("mic_resume_failed", "Could not resume the microphone: ${e.message}", fatal = false)
            return false
        }
        paused = false
        synchronized(pauseLock) { pauseLock.notifyAll() }
        state = if (modelsReady) State.LISTENING else State.LOADING
        emitStatus(if (modelsReady) "listening" else "loading")
        return true
    }

    /**
     * Stops capture, finishes the last utterance, runs the final pass and
     * calls [onDone] (on the worker thread) with the final payload.
     */
    fun stop(onDone: (Map<String, Any?>) -> Unit) {
        when (state) {
            State.FINALIZING -> {
                submit { onDone(finalPayload(onlineSegments(), "online")) }
                return
            }
            State.STOPPED -> {
                onDone(finalPayload(emptyList(), "none"))
                return
            }
            else -> Unit
        }
        val failed = state == State.FAILED
        state = State.FINALIZING
        stopRecorder()
        if (!failed) emitStatus("finalizing", 0.0)
        val ok = submit {
            var payload: Map<String, Any?>
            try {
                if (!failed) closeOpenSpeech()
                payload = if (failed) finalPayload(onlineSegments(), "online") else finalPass()
            } catch (t: Throwable) {
                emitError("final_pass_failed", "Final speaker pass failed: ${t.message}", fatal = false)
                payload = finalPayload(onlineSegments(), "online")
            }
            emit(payload + mapOf("type" to "final", "sessionId" to id))
            state = State.STOPPED
            emitStatus("stopped")
            emit(mapOf("type" to "end", "sessionId" to id))
            releaseNative()
            onDone(payload)
        }
        worker.shutdown()
        if (!ok) {
            state = State.STOPPED
            onDone(finalPayload(emptyList(), "none"))
        }
    }

    /** Stops everything without a final pass and frees memory. Safe from any thread. */
    fun cancel() {
        if (state == State.STOPPED) return
        state = State.STOPPED
        stopRecorder()
        submit { releaseNative() }
        worker.shutdown()
    }

    // --------------------------------------------------------------- capture

    @SuppressLint("MissingPermission")
    private fun startRecorder(): Boolean {
        val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuf <= 0) {
            fail("mic_unavailable", "This device cannot record 16 kHz mono audio.")
            return false
        }
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf * 2, SAMPLE_RATE), // at least 0.5 s of buffering
            )
        } catch (e: Exception) {
            fail("mic_unavailable", "Could not open the microphone: ${e.message}")
            return false
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            fail("mic_unavailable", "The microphone is in use or unavailable.")
            return false
        }
        try {
            if (config.noiseSuppression && NoiseSuppressor.isAvailable()) {
                noiseSuppressor = NoiseSuppressor.create(rec.audioSessionId)?.apply { enabled = true }
            }
            if (config.autoGain && AutomaticGainControl.isAvailable()) {
                gainControl = AutomaticGainControl.create(rec.audioSessionId)?.apply { enabled = true }
            }
        } catch (_: Exception) {
            // Effects are best effort.
        }
        try {
            rec.startRecording()
        } catch (e: Exception) {
            releaseRecorder(rec)
            fail("mic_unavailable", "Could not start the microphone: ${e.message}")
            return false
        }
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            releaseRecorder(rec)
            fail("mic_busy", "Another app is using the microphone.")
            return false
        }
        recorder = rec
        running = true
        recorderThread = Thread({ recordLoop(rec) }, "solis-speech-mic").also { it.start() }
        return true
    }

    private fun recordLoop(rec: AudioRecord) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val buf = ShortArray(SAMPLE_RATE / 10)
        var errors = 0
        while (running) {
            if (paused) {
                synchronized(pauseLock) {
                    while (paused && running) pauseLock.wait(250)
                }
                continue
            }
            val n = try {
                rec.read(buf, 0, buf.size)
            } catch (_: Exception) {
                -1
            }
            if (n > 0) {
                errors = 0
                emitLevel(buf, n)
                val chunk = buf.copyOf(n)
                val queued = backlog.incrementAndGet()
                if (queued > 50 && !behindReported) {
                    behindReported = true
                    emitStatus("behind")
                }
                if (!submit {
                        backlog.decrementAndGet()
                        onAudio(chunk)
                    }) break
            } else if (n < 0 && running && !paused) {
                if (++errors > 20) {
                    emitError("mic_read_failed", "The microphone stopped delivering audio (code $n).", fatal = true)
                    break
                }
                SystemClock.sleep(20)
            }
        }
    }

    /** RMS of the block in dBFS, for the recording screen's level meter. */
    private fun emitLevel(buf: ShortArray, n: Int) {
        var sum = 0.0
        for (i in 0 until n) {
            val s = buf[i].toDouble()
            sum += s * s
        }
        val rms = Math.sqrt(sum / n)
        val dbfs = if (rms <= 0.0) -120.0 else 20.0 * Math.log10(rms / 32768.0)
        emit(mapOf("type" to "level", "sessionId" to id, "dbfs" to dbfs))
    }

    private fun stopRecorder() {
        running = false
        paused = false
        synchronized(pauseLock) { pauseLock.notifyAll() }
        val rec = recorder
        recorder = null
        try {
            rec?.stop()
        } catch (_: Exception) {
        }
        try {
            recorderThread?.join(1500)
        } catch (_: InterruptedException) {
        }
        recorderThread = null
        if (rec != null) releaseRecorder(rec)
    }

    private fun releaseRecorder(rec: AudioRecord) {
        try {
            noiseSuppressor?.release()
        } catch (_: Exception) {
        }
        try {
            gainControl?.release()
        } catch (_: Exception) {
        }
        noiseSuppressor = null
        gainControl = null
        try {
            rec.release()
        } catch (_: Exception) {
        }
    }

    // ---------------------------------------------------------------- worker

    private fun loadModels() {
        val t0 = SystemClock.elapsedRealtime()
        try {
            val m = config.models
            recognizer = OfflineRecognizer(
                config = OfflineRecognizerConfig(
                    modelConfig = OfflineModelConfig(
                        moonshine = OfflineMoonshineModelConfig(encoder = m.encoder, mergedDecoder = m.decoder),
                        tokens = m.tokens,
                        numThreads = config.asrThreads,
                        debug = false,
                        provider = "cpu",
                    ),
                    decodingMethod = "greedy_search",
                ),
            )
            vad = Vad(
                config = VadModelConfig(
                    sileroVadModelConfig = SileroVadModelConfig(
                        model = m.vad,
                        threshold = 0.5f,
                        minSilenceDuration = 0.4f,
                        minSpeechDuration = 0.25f,
                        windowSize = VAD_WINDOW,
                        maxSpeechDuration = 7.0f,
                    ),
                    sampleRate = SAMPLE_RATE,
                    numThreads = 1,
                    provider = "cpu",
                ),
            )
            extractor = SpeakerEmbeddingExtractor(
                config = SpeakerEmbeddingExtractorConfig(model = m.embedding, numThreads = 1, debug = false, provider = "cpu"),
            )
            modelsReady = true
            if (state == State.LOADING) state = State.LISTENING
            emit(mapOf("type" to "start", "sessionId" to id, "sampleRate" to SAMPLE_RATE, "loadMs" to (SystemClock.elapsedRealtime() - t0).toInt()))
            if (state == State.LISTENING) emitStatus("listening")
        } catch (t: Throwable) {
            releaseNative()
            fail("model_load_failed", "Could not load the speech models: ${t.message ?: t.javaClass.simpleName}")
        }
    }

    private fun onAudio(pcm: ShortArray) {
        if (released || !modelsReady) return
        val v = vad ?: return
        store.append(pcm)
        val floats = FloatArray(pcm.size) { pcm[it] / 32768f }
        recent.append(floats)
        for (x in floats) {
            window[windowFill++] = x
            if (windowFill == VAD_WINDOW) {
                v.acceptWaveform(window.copyOf())
                windowFill = 0
                drainVad(v)
            }
        }
        if (config.emitPartials && state == State.LISTENING) updatePartial(v)
    }

    private fun drainVad(v: Vad) {
        while (!v.empty()) {
            val seg = v.front()
            v.pop()
            handleSpeech(vadBase + seg.start, seg.samples)
        }
    }

    /** Finalizes speech still open in the VAD (pause and stop). */
    private fun closeOpenSpeech() {
        val v = vad ?: return
        if (released) return
        v.flush()
        drainVad(v)
        v.reset()
        windowFill = 0
        vadBase = store.total
        speechActive = false
        clearPartial()
    }

    private fun handleSpeech(start: Long, samples: FloatArray) {
        speechActive = false
        lastSegmentEnd = start + samples.size
        clearPartial()
        for ((off, len) in splitForAsr(samples)) {
            val piece = samples.copyOfRange(off, off + len)
            val text = decode(piece).trim()
            if (text.isEmpty() || isNoise(text)) continue
            val seconds = len.toFloat() / SAMPLE_RATE
            val embedding = if (seconds >= 0.5f) embed(piece) else null
            val speaker = clusterer.assign(embedding, seconds, lastSpeaker)
            lastSpeaker = speaker
            val u = Utterance(nextUtteranceId++, start + off, start + off + len, text, speaker, embedding)
            utterances.add(u)
            emit(mapOf("type" to "segment", "sessionId" to id, "segment" to segmentMap(u.id, speaker, text, u.startSample, u.endSample)))
        }
    }

    private fun updatePartial(v: Vad) {
        val now = store.total
        if (!v.isSpeechDetected()) return
        if (!speechActive) {
            speechActive = true
            speechStart = maxOf(now - SAMPLE_RATE / 2, lastSegmentEnd)
            lastPartialAt = now
            return
        }
        if (now - lastPartialAt < partialIntervalSamples) return
        lastPartialAt = now
        val from = maxOf(speechStart, now - (MAX_ASR_SECONDS * SAMPLE_RATE).toLong())
        val audio = recent.since(from)
        if (audio.size < SAMPLE_RATE / 2) return
        val t0 = SystemClock.elapsedRealtime()
        val text = decode(audio).trim()
        val ms = SystemClock.elapsedRealtime() - t0
        // Keep partial decoding under about a third of real time.
        partialIntervalSamples = (ms * 3 * SAMPLE_RATE / 1000).toInt().coerceIn(SAMPLE_RATE / 2, SAMPLE_RATE * 3)
        if (text.isEmpty() || isNoise(text)) return
        partialShown = true
        emit(
            mapOf(
                "type" to "partial",
                "sessionId" to id,
                "text" to text,
                "start" to from.toDouble() / SAMPLE_RATE,
                "end" to now.toDouble() / SAMPLE_RATE,
                "speakerIndex" to lastSpeaker,
            ),
        )
    }

    private fun clearPartial() {
        if (!partialShown) return
        partialShown = false
        emit(mapOf("type" to "partial", "sessionId" to id, "text" to "", "speakerIndex" to lastSpeaker))
    }

    /** Splits audio longer than [MAX_ASR_SECONDS] at the quietest 20 ms frame. */
    private fun splitForAsr(samples: FloatArray): List<Pair<Int, Int>> {
        val max = (MAX_ASR_SECONDS * SAMPLE_RATE).toInt()
        val out = ArrayList<Pair<Int, Int>>()
        var pos = 0
        while (samples.size - pos > max) {
            val frame = SAMPLE_RATE / 50
            var bestAt = pos + max
            var bestEnergy = Double.MAX_VALUE
            var f = pos + SAMPLE_RATE * 4
            while (f + frame <= pos + max) {
                var e = 0.0
                for (k in f until f + frame) e += samples[k] * samples[k]
                if (e < bestEnergy) {
                    bestEnergy = e
                    bestAt = f + frame / 2
                }
                f += frame
            }
            out.add(pos to (bestAt - pos))
            pos = bestAt
        }
        if (samples.size - pos > SAMPLE_RATE / 10) out.add(pos to (samples.size - pos))
        return out
    }

    private fun decode(samples: FloatArray): String {
        val r = recognizer ?: return ""
        if (samples.size < SAMPLE_RATE / 10) return ""
        val s = r.createStream()
        return try {
            s.acceptWaveform(samples, SAMPLE_RATE)
            r.decode(s)
            r.getResult(s).text
        } finally {
            s.release()
        }
    }

    private fun embed(samples: FloatArray): FloatArray? {
        val x = extractor ?: return null
        val s = x.createStream()
        return try {
            s.acceptWaveform(samples, SAMPLE_RATE)
            s.inputFinished()
            if (x.isReady(s)) x.compute(s) else null
        } catch (_: Exception) {
            null
        } finally {
            s.release()
        }
    }

    // ------------------------------------------------------------ final pass

    private fun finalPass(): Map<String, Any?> {
        if (utterances.isEmpty()) return finalPayload(emptyList(), "none")
        val seconds = store.total.toFloat() / SAMPLE_RATE
        val full = config.finalPassMaxSeconds > 0 && store.complete && seconds >= 3f && seconds <= config.finalPassMaxSeconds &&
            utterances.size >= 2 && config.models.segmentation.isNotBlank()
        if (full) {
            try {
                val segments = pyannotePass()
                if (segments != null) return finalPayload(segments, "pyannote")
            } catch (t: Throwable) {
                emitError("diarization_failed", "Full speaker pass failed, using live labels: ${t.message}", fatal = false)
            }
        }
        return finalPayload(reclusterPass(), "recluster")
    }

    private fun pyannotePass(): List<FinalSegment>? {
        val m = config.models
        val sd = OfflineSpeakerDiarization(
            config = OfflineSpeakerDiarizationConfig(
                segmentation = OfflineSpeakerSegmentationModelConfig(
                    pyannote = OfflineSpeakerSegmentationPyannoteModelConfig(model = m.segmentation, windowShiftRatio = 0.3f),
                    numThreads = 2,
                    debug = false,
                    provider = "cpu",
                ),
                embedding = SpeakerEmbeddingExtractorConfig(model = m.embedding, numThreads = 2, debug = false, provider = "cpu"),
                clustering = FastClusteringConfig(
                    numClusters = if (config.numSpeakers > 0) config.numSpeakers else -1,
                    threshold = config.clusterThreshold,
                ),
                minDurationOn = 0.3f,
                minDurationOff = 0.5f,
            ),
        )
        try {
            val audio = store.all()
            var lastReported = -1
            val progress = DiarizationProgress { done, total ->
                val pct = if (total > 0) done * 100 / total else 0
                if (pct >= lastReported + 5) {
                    lastReported = pct
                    emitStatus("finalizing", pct / 100.0 * 0.9)
                }
            }
            val raw = sd.processWithCallback(audio, progress, 0L)
            val turns = raw.map { Turn(it.start, it.end, it.speaker) }
            if (turns.isEmpty()) return null
            val merged = DiarizationMerger.merge(utterances, turns) { s, e -> decode(store.floats(s, e)) }
            val aligned = alignLabels(
                IntArray(merged.size) { merged[it].onlineSpeaker },
                IntArray(merged.size) { merged[it].speaker },
                FloatArray(merged.size) { merged[it].seconds },
            )
            emitStatus("finalizing", 1.0)
            return merged.mapIndexed { i, s -> s.copy(speaker = aligned[i]) }
        } finally {
            sd.release()
        }
    }

    private fun reclusterPass(): List<FinalSegment> {
        val embeddings = utterances.map { it.embedding }
        val online = IntArray(utterances.size) { utterances[it].speaker }
        val weights = FloatArray(utterances.size) { utterances[it].seconds }
        var labels = if (utterances.size <= 400) {
            agglomerativeCluster(embeddings, config.numSpeakers)
        } else {
            refineByCentroids(embeddings, online, weights, config.numSpeakers)
        }
        if (labels.all { it < 0 }) labels = online
        // Utterances without an embedding follow the previous one.
        var prev = labels.firstOrNull { it >= 0 } ?: 0
        for (i in labels.indices) if (labels[i] < 0) labels[i] = prev else prev = labels[i]
        val aligned = alignLabels(online, labels, weights)
        return utterances.mapIndexed { i, u -> FinalSegment(aligned[i], u.text, u.startSample, u.endSample, u.speaker) }
    }

    private fun onlineSegments(): List<FinalSegment> = utterances.map { FinalSegment(it.speaker, it.text, it.startSample, it.endSample, it.speaker) }

    private fun finalPayload(segments: List<FinalSegment>, method: String): Map<String, Any?> = mapOf(
        "segments" to segments.mapIndexed { i, s -> segmentMap(i, s.speaker, s.text, s.startSample, s.endSample) },
        "method" to method,
        "numSpeakers" to segments.map { it.speaker }.distinct().size,
        "durationSec" to store.total.toDouble() / SAMPLE_RATE,
    )

    private fun segmentMap(id: Int, speaker: Int, text: String, start: Long, end: Long): Map<String, Any?> = mapOf(
        "id" to id,
        "speakerIndex" to speaker,
        "text" to text,
        "start" to start.toDouble() / SAMPLE_RATE,
        "end" to end.toDouble() / SAMPLE_RATE,
        "isFinal" to true,
    )

    // --------------------------------------------------------------- helpers

    private fun releaseNative() {
        if (released) return
        released = true
        modelsReady = false
        try {
            recognizer?.release()
        } catch (_: Throwable) {
        }
        try {
            vad?.release()
        } catch (_: Throwable) {
        }
        try {
            extractor?.release()
        } catch (_: Throwable) {
        }
        recognizer = null
        vad = null
        extractor = null
        store.clear()
    }

    private fun submit(task: () -> Unit): Boolean = try {
        worker.execute(task)
        true
    } catch (_: RejectedExecutionException) {
        false
    }

    private fun fail(code: String, message: String) {
        state = State.FAILED
        running = false
        emitError(code, message, fatal = true)
        emitStatus("failed")
    }

    private fun emitStatus(status: String, progress: Double? = null) {
        emit(mapOf("type" to "status", "sessionId" to id, "status" to status, "progress" to progress))
    }

    private fun emitError(code: String, message: String, fatal: Boolean) {
        if (fatal && state != State.FAILED && state != State.STOPPED && state != State.FINALIZING) {
            state = State.FAILED
            running = false
        }
        emit(mapOf("type" to "error", "sessionId" to id, "code" to code, "message" to message, "fatal" to fatal))
    }

    companion object {
        private const val VAD_WINDOW = 512

        /** Moonshine sometimes emits filler for noise; drop pure punctuation or bracket tags. */
        private val noise = Regex("^[\\p{Punct}\\s]*$|^\\[.*]$|^\\(.*\\)$")
        fun isNoise(text: String) = noise.matches(text)
    }
}

/**
 * Progress callback for OfflineSpeakerDiarization.processWithCallback. The JNI
 * code looks up `invoke(IIJ)Ljava/lang/Integer;` by name on the object's class,
 * so this is a named class with an R8 keep rule (proguard-rules.pro) rather
 * than a lambda, whose typed invoke R8 would inline away. Returning 0 lets the
 * pass continue.
 */
internal class DiarizationProgress(private val onProgress: (Int, Int) -> Unit) : (Int, Int, Long) -> Int {
    override fun invoke(numProcessedChunks: Int, numTotalChunks: Int, arg: Long): Int {
        try {
            onProgress(numProcessedChunks, numTotalChunks)
        } catch (_: Throwable) {
        }
        return 0
    }
}
