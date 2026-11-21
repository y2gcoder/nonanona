package app.nonanona.feature.receiptimport

import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.ceil
import kotlin.math.floor

/** 가림 사각형을 새 비트맵에 굽고 PNG 바이트를 돌려준다(플랫폼 구현은 Android Canvas). */
fun interface ReceiptFlattener {
    fun flatten(
        original: File,
        rects: List<IntArray>,
    ): ByteArray
}

/**
 * 사용자가 확인한 가림을 픽셀에 구운 새 PNG. [flatten]으로만 만들 수 있고,
 * 원본·OCR 결과와 다른 타입이라 실수로 원본을 내보낼 수 없다.
 */
class MaskedArtifact private constructor(
    val pngBytes: ByteArray,
) {
    val sha256: String = ProposalBuilder.sha256Hex(pngBytes)

    companion object {
        /** 확인한 경우에만 부른다. 그리기에 필요한 PNG 청크만 남긴다. */
        fun flatten(
            flattener: ReceiptFlattener,
            original: File,
            rects: List<IntArray>,
        ): MaskedArtifact = MaskedArtifact(PngChunks.stripAncillary(flattener.flatten(original, rects)))
    }
}

object Masking {
    /** 고른 OCR 줄마다 가로 전체 띠. 글자 가장자리까지 덮도록 여백을 둔다. (l, t, r, b) 픽셀. */
    fun rects(
        lines: List<OcrLine>,
        selected: Set<Int>,
        width: Int,
        height: Int,
    ): List<IntArray> =
        lines.filter { it.id in selected }.map { line ->
            val top = line.y * height
            val bottom = (line.y + line.height) * height
            val pad = maxOf(8.0, (bottom - top) * 0.3)
            intArrayOf(0, floor(top - pad).toInt().coerceAtLeast(0), width, ceil(bottom + pad).toInt().coerceAtMost(height))
        }
}

/** 그리기에 필요한 PNG 청크만 남긴다(eXIf, tEXt, iTXt, iCCP, tIME 등 제거). */
object PngChunks {
    val allowed = setOf("IHDR", "PLTE", "tRNS", "sRGB", "IDAT", "IEND")
    private val signature = byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)

    fun names(png: ByteArray): List<String> = chunks(png).map { it.first }

    fun stripAncillary(png: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(signature)
        for ((name, range) in chunks(png)) if (name in allowed) out.write(png, range.first, range.last - range.first + 1)
        return out.toByteArray()
    }

    private fun chunks(png: ByteArray): List<Pair<String, IntRange>> {
        if (png.size <= 8 || !png.copyOfRange(0, 8).contentEquals(signature)) {
            throw ProcessingException(ProcessingFailure.InvalidImage)
        }
        val result = mutableListOf<Pair<String, IntRange>>()
        var offset = 8
        while (png.size - offset >= 12) {
            val size =
                ((png[offset].toInt() and 255) shl 24) or ((png[offset + 1].toInt() and 255) shl 16) or
                    ((png[offset + 2].toInt() and 255) shl 8) or (png[offset + 3].toInt() and 255)
            if (size < 0 || size > png.size - offset - 12) throw ProcessingException(ProcessingFailure.InvalidImage)
            val name = String(png, offset + 4, 4, Charsets.US_ASCII)
            result.add(name to (offset until offset + size + 12))
            offset += size + 12
            if (name == "IEND") return result
        }
        throw ProcessingException(ProcessingFailure.InvalidImage)
    }
}
