package com.solis.clinical.solis_mobile.speech

import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest

/** File helpers for the speech models: hashing and unpacking .tar.bz2 releases. */
internal object ModelFiles {
    fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    data class Extracted(val path: String, val size: Long, val sha256: String)

    /**
     * Extracts the entries named in [wanted] (path inside the archive to the
     * destination file name) from a .tar.bz2 [archive] into [destDir]. Each
     * file is written to a temporary name, hashed while it is written, and
     * renamed into place only when complete. Nothing outside [destDir] is ever
     * written: destination names may not contain path separators.
     * [onProgress] receives compressed bytes read and the archive size.
     */
    fun extractTarBz2(
        archive: File,
        destDir: File,
        wanted: Map<String, String>,
        onProgress: (Long, Long) -> Unit,
    ): Map<String, Extracted> {
        for (name in wanted.values) {
            require(name.isNotBlank() && !name.contains('/') && !name.contains('\\') && name != "." && name != "..") { "Bad destination name: $name" }
        }
        if (!destDir.isDirectory && !destDir.mkdirs()) throw IOException("Cannot create $destDir")
        val total = archive.length()
        val results = HashMap<String, Extracted>()
        val counting = CountingInputStream(BufferedInputStream(FileInputStream(archive), 1 shl 16))
        var lastReport = 0L
        BZip2CompressorInputStream(counting, true).use { bz ->
            val tar = TarReader(bz)
            while (true) {
                val entry = tar.next() ?: break
                val name = entry.name.trimStart('.', '/')
                val dest = wanted[name] ?: wanted.entries.firstOrNull { name.endsWith("/" + it.key) || name == it.key }?.value
                if (dest == null || !entry.isFile) {
                    tar.skip(entry)
                } else {
                    val tmp = File(destDir, "$dest.extracting")
                    val md = MessageDigest.getInstance("SHA-256")
                    FileOutputStream(tmp).use { out ->
                        tar.copy(entry) { buf, n ->
                            out.write(buf, 0, n)
                            md.update(buf, 0, n)
                            if (counting.count - lastReport > (1 shl 20)) {
                                lastReport = counting.count
                                onProgress(counting.count, total)
                            }
                        }
                        out.fd.sync()
                    }
                    val target = File(destDir, dest)
                    if (target.exists()) target.delete()
                    if (!tmp.renameTo(target)) throw IOException("Cannot move $tmp to $target")
                    results[dest] = Extracted(target.absolutePath, target.length(), md.digest().joinToString("") { "%02x".format(it) })
                }
                if (results.size == wanted.size) break
            }
        }
        onProgress(total, total)
        val missing = wanted.values.filter { !results.containsKey(it) }
        if (missing.isNotEmpty()) throw IOException("Archive is missing: ${missing.joinToString()}")
        return results
    }

    private class CountingInputStream(input: InputStream) : FilterInputStream(input) {
        var count = 0L
        override fun read(): Int {
            val b = super.read()
            if (b >= 0) count++
            return b
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            val n = super.read(b, off, len)
            if (n > 0) count += n
            return n
        }

        override fun skip(n: Long): Long {
            val s = super.skip(n)
            if (s > 0) count += s
            return s
        }
    }

    /** Minimal reader for POSIX ustar / GNU tar streams (regular files only). */
    private class TarReader(private val input: InputStream) {
        class Entry(val name: String, val size: Long, val isFile: Boolean)

        private val header = ByteArray(512)
        private var longName: String? = null

        fun next(): Entry? {
            while (true) {
                if (!readFully(header)) return null
                if (header.all { it.toInt() == 0 }) return null
                val size = parseOctal(header, 124, 12)
                val type = header[156].toInt().toChar()
                var name = cString(header, 0, 100)
                val magic = cString(header, 257, 6)
                if (magic.startsWith("ustar")) {
                    val prefix = cString(header, 345, 155)
                    if (prefix.isNotEmpty()) name = "$prefix/$name"
                }
                longName?.let {
                    name = it
                    longName = null
                }
                when (type) {
                    'L' -> { // GNU long name: the data is the name of the next entry.
                        val data = ByteArray(size.toInt())
                        if (!readFully(data)) return null
                        skipPadding(size)
                        longName = String(data, Charsets.UTF_8).trimEnd('\u0000')
                        continue
                    }
                    'x', 'g' -> { // PAX headers: honour "path=" for the next entry.
                        val data = ByteArray(size.toInt())
                        if (!readFully(data)) return null
                        skipPadding(size)
                        if (type == 'x') {
                            String(data, Charsets.UTF_8).split('\n').forEach { line ->
                                val sp = line.indexOf(' ')
                                if (sp > 0 && line.substring(sp + 1).startsWith("path=")) longName = line.substring(sp + 6)
                            }
                        }
                        continue
                    }
                }
                return Entry(name, size, type == '0' || type == '\u0000')
            }
        }

        fun skip(e: Entry) {
            var left = e.size + padding(e.size)
            val buf = ByteArray(8192)
            while (left > 0) {
                val n = input.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
                if (n < 0) throw IOException("Truncated archive")
                left -= n
            }
        }

        fun copy(e: Entry, sink: (ByteArray, Int) -> Unit) {
            var left = e.size
            val buf = ByteArray(1 shl 16)
            while (left > 0) {
                val n = input.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
                if (n < 0) throw IOException("Truncated archive")
                sink(buf, n)
                left -= n
            }
            skipPadding(e.size)
        }

        private fun padding(size: Long) = (512 - size % 512) % 512

        private fun skipPadding(size: Long) {
            val p = padding(size).toInt()
            if (p > 0) readFully(ByteArray(p))
        }

        private fun readFully(b: ByteArray): Boolean {
            var off = 0
            while (off < b.size) {
                val n = input.read(b, off, b.size - off)
                if (n < 0) return false
                off += n
            }
            return true
        }

        private fun cString(b: ByteArray, off: Int, len: Int): String {
            var end = off
            while (end < off + len && b[end].toInt() != 0) end++
            return String(b, off, end - off, Charsets.UTF_8)
        }

        private fun parseOctal(b: ByteArray, off: Int, len: Int): Long {
            if (b[off].toInt() and 0x80 != 0) { // GNU base-256 for large files
                var v = 0L
                for (i in off + 1 until off + len) v = (v shl 8) or (b[i].toLong() and 0xff)
                return v
            }
            val s = cString(b, off, len).trim()
            return if (s.isEmpty()) 0 else s.toLong(8)
        }
    }
}
