package app.nonanona.feature.settlement

import java.util.zip.CRC32
import java.util.zip.DataFormatException
import java.util.zip.Inflater

/**
 * 받은 가림 사본이 끝까지 온전한 PNG인지 본다. 플랫폼 디코더는 잘린 PNG도 일부 그림을 만들 수 있어 그 앞에서 따로 본다.
 * 서명, IHDR로 시작해 IEND로 끝나는 청크(길이가 범위 안이고 CRC가 맞음), IDAT를 이어 붙인 zlib 흐름이 끝까지 풀려
 * IHDR이 말하는 크기와 정확히 같은지(인터레이스가 아닐 때). iOS PNGCheck와 같은 규칙.
 */
object PngCheck {
    private val signature = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    fun isComplete(bytes: ByteArray): Boolean {
        if (bytes.size < 8 + 25 + 12 || !bytes.copyOfRange(0, 8).contentEquals(signature)) return false
        var offset = 8
        var first = true
        var ended = false
        var width = 0
        var height = 0
        var depth = 0
        var color = 0
        var interlace = 0
        val idat = java.io.ByteArrayOutputStream()
        while (offset < bytes.size) {
            if (ended || offset + 12 > bytes.size) return false
            val length = be32(bytes, offset)
            if (length < 0 || offset + 12L + length > bytes.size) return false
            val type = String(bytes, offset + 4, 4, Charsets.US_ASCII)
            val crc = CRC32().apply { update(bytes, offset + 4, 4 + length) }.value
            if (crc != be32(bytes, offset + 8 + length).toLong() and 0xFFFFFFFFL) return false
            val body = offset + 8
            if (first) {
                if (type != "IHDR" || length != 13) return false
                width = be32(bytes, body)
                height = be32(bytes, body + 4)
                depth = bytes[body + 8].toInt() and 0xFF
                color = bytes[body + 9].toInt() and 0xFF
                interlace = bytes[body + 12].toInt() and 0xFF
                first = false
            } else if (type == "IDAT") {
                idat.write(bytes, body, length)
            } else if (type == "IEND") {
                ended = true
            }
            offset += 12 + length
        }
        if (!ended || width <= 0 || height <= 0 || idat.size() == 0) return false
        val channels = mapOf(0 to 1, 2 to 3, 3 to 1, 4 to 2, 6 to 4)[color] ?: return false
        if (interlace != 0) return true // 인터레이스는 구조까지만 본다(앱이 만드는 사본은 아니다)
        val rowBytes = (width.toLong() * channels * depth + 7) / 8
        val expected = height * (rowBytes + 1)
        return inflatedSize(idat.toByteArray(), expected + 1) == expected
    }

    /** zlib 흐름을 끝까지 풀었을 때의 크기(limit에서 멈춘다). 풀리지 않거나 흐름이 끝나지 않으면 -1. */
    private fun inflatedSize(
        zlib: ByteArray,
        limit: Long,
    ): Long {
        val inflater = Inflater()
        return try {
            inflater.setInput(zlib)
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (!inflater.finished() && total < limit) {
                val n = inflater.inflate(buffer)
                if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) return -1
                total += n
            }
            if (inflater.finished()) total else -1
        } catch (e: DataFormatException) {
            -1
        } finally {
            inflater.end()
        }
    }

    private fun be32(
        b: ByteArray,
        i: Int,
    ): Int =
        (b[i].toInt() and 0xFF shl 24) or (b[i + 1].toInt() and 0xFF shl 16) or (b[i + 2].toInt() and 0xFF shl 8) or
            (b[i + 3].toInt() and 0xFF)
}
