package com.solis.clinical.solis_mobile.speech

import kotlin.math.sqrt

internal fun l2normalize(v: FloatArray): FloatArray {
    var s = 0.0
    for (x in v) s += x * x
    val n = sqrt(s).toFloat()
    if (n <= 1e-9f) return v.copyOf()
    return FloatArray(v.size) { v[it] / n }
}

internal fun dot(a: FloatArray, b: FloatArray): Float {
    var s = 0f
    for (i in 0 until minOf(a.size, b.size)) s += a[i] * b[i]
    return s
}

/**
 * Live speaker assignment: each utterance's voice embedding is compared with
 * the running centroid of every voice heard so far (cosine similarity). A
 * long utterance that matches nobody starts a new voice; short ones join the
 * nearest voice because their embeddings are unreliable.
 *
 * Similarities measured with 3D-Speaker CAM++ (English VoxCeleb) on two-person
 * recordings were 0.55 to 0.95 for the same voice and 0.1 to 0.47 for
 * different voices, hence the 0.45 default for [newThreshold].
 */
internal class OnlineSpeakerClusterer(
    private val fixedCount: Int,
    private val maxSpeakers: Int,
    private val newThreshold: Float,
    private val createMinSeconds: Float = 1.5f,
    private val updateMinSeconds: Float = 1.0f,
) {
    private val sums = ArrayList<FloatArray>()
    private val weights = ArrayList<Float>()

    val count: Int get() = sums.size

    private val limit: Int get() = if (fixedCount > 0) fixedCount else maxSpeakers

    /** Returns the voice index for an utterance; [fallback] is used without an embedding. */
    fun assign(embedding: FloatArray?, seconds: Float, fallback: Int): Int {
        if (embedding == null) return if (sums.isEmpty()) 0 else fallback.coerceIn(0, sums.size - 1)
        val e = l2normalize(embedding)
        if (sums.isEmpty()) return create(e, seconds)
        var best = 0
        var bestSim = -2f
        for (i in sums.indices) {
            val sim = dot(e, l2normalize(sums[i]))
            if (sim > bestSim) {
                bestSim = sim
                best = i
            }
        }
        if (bestSim < newThreshold && sums.size < limit && seconds >= createMinSeconds) return create(e, seconds)
        if (seconds >= updateMinSeconds) {
            val w = seconds.coerceAtMost(8f)
            val s = sums[best]
            for (k in s.indices) s[k] += e[k] * w
            weights[best] = weights[best] + w
        }
        return best
    }

    private fun create(e: FloatArray, seconds: Float): Int {
        val w = seconds.coerceIn(0.5f, 8f)
        sums.add(FloatArray(e.size) { e[it] * w })
        weights.add(w)
        return sums.size - 1
    }
}

/**
 * Average-linkage agglomerative clustering of utterance embeddings. Used for
 * the final pass when the recording is too long for the full pyannote pass.
 * Returns a cluster index for each input (or -1 where the embedding is null).
 */
internal fun agglomerativeCluster(embeddings: List<FloatArray?>, numClusters: Int, stopSimilarity: Float = 0.5f): IntArray {
    val norm = embeddings.map { it?.let(::l2normalize) }
    val clusters = ArrayList<MutableList<Int>>()
    for (i in norm.indices) if (norm[i] != null) clusters.add(mutableListOf(i))
    val result = IntArray(norm.size) { -1 }
    if (clusters.isEmpty()) return result
    // Pairwise similarity cache.
    val n = norm.size
    val sim = Array(n) { FloatArray(n) }
    for (i in 0 until n) for (j in i + 1 until n) {
        val a = norm[i]
        val b = norm[j]
        if (a != null && b != null) {
            val s = dot(a, b)
            sim[i][j] = s
            sim[j][i] = s
        }
    }
    fun link(a: List<Int>, b: List<Int>): Float {
        var s = 0f
        for (x in a) for (y in b) s += sim[x][y]
        return s / (a.size * b.size)
    }
    while (clusters.size > 1) {
        if (numClusters > 0 && clusters.size <= numClusters) break
        var bi = -1
        var bj = -1
        var best = -2f
        for (i in clusters.indices) for (j in i + 1 until clusters.size) {
            val s = link(clusters[i], clusters[j])
            if (s > best) {
                best = s
                bi = i
                bj = j
            }
        }
        if (numClusters <= 0 && best < stopSimilarity) break
        clusters[bi].addAll(clusters[bj])
        clusters.removeAt(bj)
    }
    clusters.sortBy { c -> c.minOrNull() ?: Int.MAX_VALUE }
    clusters.forEachIndexed { k, c -> for (i in c) result[i] = k }
    return result
}

/**
 * Linear-time alternative to [agglomerativeCluster] for long recordings:
 * starts from the live labels and repeatedly moves each utterance to the
 * nearest duration-weighted voice centroid (k-means on the unit sphere).
 * When [numClusters] is set and more voices exist, the two closest centroids
 * are merged until the count matches.
 */
internal fun refineByCentroids(
    embeddings: List<FloatArray?>,
    initial: IntArray,
    weights: FloatArray,
    numClusters: Int,
    iterations: Int = 6,
): IntArray {
    val norm = embeddings.map { it?.let(::l2normalize) }
    val labels = initial.copyOf()
    val dim = norm.firstOrNull { it != null }?.size ?: return labels
    fun centroids(): Map<Int, FloatArray> {
        val sums = HashMap<Int, FloatArray>()
        for (i in norm.indices) {
            val e = norm[i] ?: continue
            if (labels[i] < 0) continue
            val s = sums.getOrPut(labels[i]) { FloatArray(dim) }
            val w = weights[i].coerceIn(0.3f, 8f)
            for (k in 0 until dim) s[k] += e[k] * w
        }
        return sums.mapValues { l2normalize(it.value) }
    }
    fun reassign(): Boolean {
        val c = centroids()
        if (c.isEmpty()) return false
        var changed = false
        for (i in norm.indices) {
            val e = norm[i] ?: continue
            var bestLabel = labels[i]
            var bestSim = -2f
            for ((label, centroid) in c) {
                val s = dot(e, centroid)
                if (s > bestSim) {
                    bestSim = s
                    bestLabel = label
                }
            }
            if (bestLabel != labels[i]) {
                labels[i] = bestLabel
                changed = true
            }
        }
        return changed
    }
    // Settle the live labels first, then merge down to the requested count
    // (closest centroids first), then settle again.
    for (k in 0 until iterations) if (!reassign()) break
    if (numClusters > 0) {
        while (true) {
            val c = centroids()
            if (c.size <= numClusters) break
            var pair: Pair<Int, Int>? = null
            var best = -2f
            val keys = c.keys.sorted()
            for (a in keys.indices) for (b in a + 1 until keys.size) {
                val s = dot(c.getValue(keys[a]), c.getValue(keys[b]))
                if (s > best) {
                    best = s
                    pair = keys[a] to keys[b]
                }
            }
            val (keep, drop) = pair ?: break
            for (i in labels.indices) if (labels[i] == drop) labels[i] = keep
        }
        for (k in 0 until iterations) if (!reassign()) break
    }
    return labels
}

/**
 * Renumbers [newLabels] so they agree with [oldLabels] where the two
 * clusterings overlap most (weighted by [weights], usually seconds). Keeps
 * the speaker numbers the screen already shows stable after the final pass.
 * Labels below 0 are left as they are.
 */
internal fun alignLabels(oldLabels: IntArray, newLabels: IntArray, weights: FloatArray): IntArray {
    val overlap = HashMap<Pair<Int, Int>, Float>()
    for (i in newLabels.indices) {
        if (newLabels[i] < 0 || oldLabels[i] < 0) continue
        val key = newLabels[i] to oldLabels[i]
        overlap[key] = (overlap[key] ?: 0f) + weights[i]
    }
    val mapping = HashMap<Int, Int>()
    val usedOld = HashSet<Int>()
    for ((key, _) in overlap.entries.sortedByDescending { it.value }) {
        if (mapping.containsKey(key.first) || usedOld.contains(key.second)) continue
        mapping[key.first] = key.second
        usedOld.add(key.second)
    }
    var next = (oldLabels.maxOrNull() ?: -1).coerceAtLeast(-1) + 1
    for (l in newLabels.distinct().sorted()) {
        if (l < 0 || mapping.containsKey(l)) continue
        while (usedOld.contains(next)) next++
        mapping[l] = next
        usedOld.add(next)
        next++
    }
    return IntArray(newLabels.size) { i -> if (newLabels[i] < 0) newLabels[i] else mapping[newLabels[i]] ?: newLabels[i] }
}
