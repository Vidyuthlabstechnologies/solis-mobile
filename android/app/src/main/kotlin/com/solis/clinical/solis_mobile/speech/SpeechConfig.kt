package com.solis.clinical.solis_mobile.speech

import java.io.File

/** Audio format used end to end: 16 kHz, mono, 16-bit PCM. */
internal const val SAMPLE_RATE = 16000

/**
 * Moonshine v2 (sherpa-onnx 1.13.8) returns an empty result for inputs longer
 * than about 9 s, so every chunk sent to the recognizer is capped below that.
 */
internal const val MAX_ASR_SECONDS = 8.0f

/** Absolute paths of the model files a session needs. */
internal data class ModelPaths(
    val vad: String,
    val encoder: String,
    val decoder: String,
    val tokens: String,
    val segmentation: String,
    val embedding: String,
) {
    fun all(): List<String> = listOf(vad, encoder, decoder, tokens, segmentation, embedding)

    /** Paths that are missing or empty. */
    fun missing(): List<String> = all().filter { p -> p.isBlank() || !File(p).let { it.isFile && it.length() > 0 } }

    companion object {
        fun from(map: Map<*, *>?): ModelPaths? {
            if (map == null) return null
            fun s(k: String): String = map[k] as? String ?: ""
            return ModelPaths(
                vad = s("vad"),
                encoder = s("encoder"),
                decoder = s("decoder"),
                tokens = s("tokens"),
                segmentation = s("segmentation"),
                embedding = s("embedding"),
            )
        }
    }
}

/** Options for one recording session, parsed from the start() arguments. */
internal data class SessionConfig(
    val models: ModelPaths,
    /** Expected number of voices; 0 means detect automatically. */
    val numSpeakers: Int = 0,
    /** Longest recording (seconds) that gets the full pyannote pass on stop. */
    val finalPassMaxSeconds: Int = 600,
    val noiseSuppression: Boolean = true,
    val autoGain: Boolean = true,
    val asrThreads: Int = 2,
    /** Most voices online clustering will create when numSpeakers is 0. */
    val maxSpeakers: Int = 4,
    /** Cosine similarity under which a long utterance starts a new voice. */
    val newSpeakerThreshold: Float = 0.45f,
    /** pyannote clustering threshold when numSpeakers is 0 (higher, fewer voices). */
    val clusterThreshold: Float = 0.85f,
    val emitPartials: Boolean = true,
) {
    companion object {
        fun from(args: Map<*, *>?): SessionConfig? {
            val models = ModelPaths.from(args?.get("models") as? Map<*, *>) ?: return null
            fun i(k: String, d: Int) = (args?.get(k) as? Number)?.toInt() ?: d
            fun f(k: String, d: Float) = (args?.get(k) as? Number)?.toFloat() ?: d
            fun b(k: String, d: Boolean) = args?.get(k) as? Boolean ?: d
            return SessionConfig(
                models = models,
                numSpeakers = i("numSpeakers", 0).coerceIn(0, 8),
                finalPassMaxSeconds = i("finalPassMaxSeconds", 600).coerceIn(0, 3600),
                noiseSuppression = b("noiseSuppression", true),
                autoGain = b("autoGain", true),
                asrThreads = i("asrThreads", 2).coerceIn(1, 4),
                maxSpeakers = i("maxSpeakers", 4).coerceIn(1, 8),
                newSpeakerThreshold = f("newSpeakerThreshold", 0.45f),
                clusterThreshold = f("clusterThreshold", 0.85f),
                emitPartials = b("emitPartials", true),
            )
        }
    }
}
