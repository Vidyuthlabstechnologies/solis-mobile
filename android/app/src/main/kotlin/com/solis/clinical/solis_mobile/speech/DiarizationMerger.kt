package com.solis.clinical.solis_mobile.speech

/** One recognized utterance (a VAD speech segment, at most [MAX_ASR_SECONDS] long). */
internal class Utterance(
    val id: Int,
    val startSample: Long,
    val endSample: Long,
    val text: String,
    var speaker: Int,
    val embedding: FloatArray?,
) {
    val seconds: Float get() = (endSample - startSample).toFloat() / SAMPLE_RATE
}

/** A diarization turn from the final pass, in seconds. */
internal data class Turn(val start: Float, val end: Float, val speaker: Int)

/** A final transcript segment. [onlineSpeaker] is the live label of its source utterance. */
internal data class FinalSegment(
    val speaker: Int,
    val text: String,
    val startSample: Long,
    val endSample: Long,
    val onlineSpeaker: Int,
) {
    val seconds: Float get() = (endSample - startSample).toFloat() / SAMPLE_RATE
}

/**
 * Lays the final diarization turns over the recognized utterances.
 *
 * Each utterance is divided into 10 ms frames labelled with the voice whose
 * turn covers them (the longer turn wins where turns overlap). If one voice
 * holds at least [dominantShare] of the frames, or the utterance is short, the
 * whole utterance goes to that voice. Otherwise the utterance is split at the
 * voice changes and each part is decoded again with [redecode], so a quick
 * exchange inside one breath group ("Any allergies? No, none.") is attributed
 * to both people.
 */
internal object DiarizationMerger {
    private const val FRAME = 160 // 10 ms at 16 kHz
    var dominantShare = 0.8f
    var minSplitSeconds = 2.0f
    var minRunSeconds = 0.6f

    fun merge(utts: List<Utterance>, turns: List<Turn>, redecode: (Long, Long) -> String): List<FinalSegment> {
        if (turns.isEmpty()) return utts.map { FinalSegment(it.speaker, it.text, it.startSample, it.endSample, it.speaker) }
        val sorted = turns.sortedBy { it.start }
        val out = ArrayList<FinalSegment>()
        for (u in utts) out.addAll(mergeOne(u, sorted, redecode))
        return out
    }

    private fun mergeOne(u: Utterance, turns: List<Turn>, redecode: (Long, Long) -> String): List<FinalSegment> {
        val frames = ((u.endSample - u.startSample) / FRAME).toInt().coerceAtLeast(1)
        val labels = IntArray(frames) { -1 }
        val uStart = u.startSample.toFloat() / SAMPLE_RATE
        val uEnd = u.endSample.toFloat() / SAMPLE_RATE
        val bestLen = FloatArray(frames)
        for (t in turns) {
            if (t.end <= uStart || t.start >= uEnd) continue
            val len = t.end - t.start
            val a = (((t.start - uStart) * SAMPLE_RATE) / FRAME).toInt().coerceIn(0, frames)
            val b = (((t.end - uStart) * SAMPLE_RATE) / FRAME).toInt().coerceIn(0, frames)
            for (f in a until b) {
                if (labels[f] < 0 || len > bestLen[f]) {
                    labels[f] = t.speaker
                    bestLen[f] = len
                }
            }
        }
        val covered = labels.count { it >= 0 }
        if (covered < frames * 0.3f) {
            // Diarization missed this speech: use the nearest turn in time.
            val mid = (uStart + uEnd) / 2
            val nearest = turns.minByOrNull { t -> if (mid < t.start) t.start - mid else if (mid > t.end) mid - t.end else 0f }
            return listOf(FinalSegment(nearest?.speaker ?: u.speaker, u.text, u.startSample, u.endSample, u.speaker))
        }
        // Fill gaps from the neighbours.
        var last = -1
        for (f in 0 until frames) if (labels[f] >= 0) last = labels[f] else if (last >= 0) labels[f] = last
        last = -1
        for (f in frames - 1 downTo 0) if (labels[f] >= 0) last = labels[f] else labels[f] = last

        val counts = HashMap<Int, Int>()
        for (l in labels) counts[l] = (counts[l] ?: 0) + 1
        val dominant = counts.maxByOrNull { it.value }!!.key
        val single = listOf(FinalSegment(dominant, u.text, u.startSample, u.endSample, u.speaker))
        if (counts.size == 1 || u.seconds < minSplitSeconds) return single
        if ((counts[dominant] ?: 0) >= frames * dominantShare) return single

        val runs = runsOf(labels)
        if (runs.size <= 1) return single
        val pieces = ArrayList<FinalSegment>()
        for (r in runs) {
            val s = u.startSample + r.first.toLong() * FRAME
            val e = if (r.second >= frames) u.endSample else u.startSample + r.second.toLong() * FRAME
            val text = redecode(s, e).trim()
            if (text.isNotEmpty()) pieces.add(FinalSegment(r.third, text, s, e, u.speaker))
        }
        return if (pieces.isEmpty()) single else pieces
    }

    /** Runs of (startFrame, endFrame, label) with short runs folded into a neighbour. */
    private fun runsOf(labels: IntArray): List<Triple<Int, Int, Int>> {
        val minFrames = (minRunSeconds * SAMPLE_RATE / FRAME).toInt()
        val runs = ArrayList<Triple<Int, Int, Int>>()
        var start = 0
        for (f in 1..labels.size) {
            if (f == labels.size || labels[f] != labels[start]) {
                runs.add(Triple(start, f, labels[start]))
                start = f
            }
        }
        // Fold short runs into the previous run (or the next one at the start).
        var changed = true
        while (changed && runs.size > 1) {
            changed = false
            val i = runs.indexOfFirst { it.second - it.first < minFrames }
            if (i >= 0) {
                if (i > 0) {
                    val p = runs[i - 1]
                    runs[i - 1] = Triple(p.first, runs[i].second, p.third)
                } else {
                    val n = runs[1]
                    runs[1] = Triple(runs[0].first, n.second, n.third)
                }
                runs.removeAt(i)
                changed = true
            }
            // Join neighbours that now share a label.
            var k = 1
            while (k < runs.size) {
                if (runs[k].third == runs[k - 1].third) {
                    runs[k - 1] = Triple(runs[k - 1].first, runs[k].second, runs[k].third)
                    runs.removeAt(k)
                    changed = true
                } else {
                    k++
                }
            }
        }
        return runs
    }
}
