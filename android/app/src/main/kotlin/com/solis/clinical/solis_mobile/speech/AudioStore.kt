package com.solis.clinical.solis_mobile.speech

/**
 * Keeps the recording in memory as 16-bit PCM (2 bytes per sample, 1.9 MB
 * per minute) so the final diarization pass and re-decoding can read any
 * range. Stops storing once [capSamples] is reached; [total] keeps counting so
 * the timeline stays correct. Audio never touches disk.
 */
internal class AudioStore(private val capSamples: Long) {
    private val chunks = ArrayList<ShortArray>()
    private val chunkStarts = ArrayList<Long>()

    /** Samples kept in memory. */
    var stored: Long = 0
        private set

    /** Samples captured, including any beyond the cap. */
    var total: Long = 0
        private set

    val complete: Boolean get() = stored == total

    fun append(pcm: ShortArray) {
        total += pcm.size
        if (stored >= capSamples) return
        val room = (capSamples - stored).toInt().coerceAtMost(pcm.size)
        val piece = if (room == pcm.size) pcm else pcm.copyOf(room)
        chunkStarts.add(stored)
        chunks.add(piece)
        stored += piece.size
    }

    /** Float samples in [from, to) clipped to what is stored. */
    fun floats(from: Long, to: Long): FloatArray {
        val a = from.coerceIn(0, stored)
        val b = to.coerceIn(a, stored)
        val out = FloatArray((b - a).toInt())
        if (out.isEmpty()) return out
        var idx = chunkIndexFor(a)
        var written = 0
        var pos = a
        while (pos < b && idx < chunks.size) {
            val chunk = chunks[idx]
            val start = chunkStarts[idx]
            val off = (pos - start).toInt()
            val n = minOf(chunk.size - off, (b - pos).toInt())
            for (k in 0 until n) out[written + k] = chunk[off + k] / 32768f
            written += n
            pos += n
            idx++
        }
        return out
    }

    fun all(): FloatArray = floats(0, stored)

    fun clear() {
        chunks.clear()
        chunkStarts.clear()
        stored = 0
        total = 0
    }

    private fun chunkIndexFor(sample: Long): Int {
        var lo = 0
        var hi = chunkStarts.size - 1
        while (lo < hi) {
            val mid = (lo + hi + 1) ushr 1
            if (chunkStarts[mid] <= sample) lo = mid else hi = mid - 1
        }
        return lo
    }
}

/** Fixed-size ring of the most recent float samples, for live partial text. */
internal class RecentAudio(private val capacity: Int) {
    private val buf = FloatArray(capacity)
    private var end: Long = 0 // absolute index one past the newest sample

    fun append(samples: FloatArray) {
        for (s in samples) {
            buf[(end % capacity).toInt()] = s
            end++
        }
    }

    /** Samples in [from, end) limited to what the ring still holds. */
    fun since(from: Long): FloatArray {
        val a = maxOf(from, end - capacity, 0)
        if (a >= end) return FloatArray(0)
        val out = FloatArray((end - a).toInt())
        for (i in out.indices) out[i] = buf[((a + i) % capacity).toInt()]
        return out
    }

    fun reset() {
        end = 0
    }

    val position: Long get() = end
}
