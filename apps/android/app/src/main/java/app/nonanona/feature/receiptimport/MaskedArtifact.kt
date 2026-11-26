package app.nonanona.feature.receiptimport

import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.sin

/**
 * 검은 가림 하나(픽셀 좌표). 축 정렬 사각형이거나, 기울어진 줄을 따라가는 띠(네 점, 시계 방향)다.
 * 사각형은 예전과 같은 픽셀로 굽힌다(drawRect/fillRect).
 */
sealed interface MaskShape {
    /** (l, t, r, b). 위·왼쪽은 포함, 아래·오른쪽은 제외. */
    data class Rect(
        val left: Int,
        val top: Int,
        val right: Int,
        val bottom: Int,
    ) : MaskShape

    /** 네 점 (x0, y0) … (x3, y3). */
    data class Quad(
        val xs: List<Double>,
        val ys: List<Double>,
    ) : MaskShape
}

/**
 * 가림을 새 비트맵에 굽고 PNG 바이트를 돌려준다(플랫폼 구현은 Android Canvas).
 * [shapes]는 실제로 디코딩한 크기(픽셀)를 받아 가림을 만든다. OCR 좌표(0~1)를 굽는 그 크기로 투영하므로,
 * 디코딩 규칙이 바뀌기 전에 저장한 제안(다른 픽셀 크기)도 같은 자리를 덮는다.
 */
fun interface ReceiptFlattener {
    fun flatten(
        original: File,
        shapes: (width: Int, height: Int) -> List<MaskShape>,
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
        /** 확인(사본)과 검토 화면 미리보기만 부른다. 그리기에 필요한 PNG 청크만 남긴다. */
        fun flatten(
            flattener: ReceiptFlattener,
            original: File,
            shapes: (width: Int, height: Int) -> List<MaskShape>,
        ): MaskedArtifact = MaskedArtifact(PngChunks.stripAncillary(flattener.flatten(original, shapes)))
    }
}

object Masking {
    /**
     * 고른 OCR 줄마다 줄 방향의 전체 폭 띠. 글자 가장자리까지 덮도록 여백(글자 높이의 30%, 최소 8픽셀)을 둔다.
     * 줄이 [MaskThresholds.MIN_TILT_DEGREES]보다 덜 기울었거나 모서리 정보가 없으면 예전과 같은 가로 전체 사각형이다.
     * 기울었으면 줄 방향으로 되돌린 좌표(보정 좌표)에서 그 행 전체를 덮는 띠를 사진 좌표로 돌려 굽는다.
     * 그래서 같은 행에서 OCR이 따로 읽었거나 읽지 못한 번호 조각도 덮고, 위아래 행(품목·합계)은 덮지 않는다.
     */
    fun shapes(
        lines: List<OcrLine>,
        selected: Set<Int>,
        width: Int,
        height: Int,
    ): List<MaskShape> {
        val chosen = lines.filter { it.id in selected }
        if (chosen.isEmpty()) return emptyList()
        val geometry = lines.map { LineGeometry.of(it, width, height) }
        val skew = LineGeometry.skew(geometry)
        // 같은 행이어도 덮지 않는 상자: 고르지 않은, 그 자체가 가격·날짜인 상자(계약 4).
        val protected = geometry.filter { it.line.id !in selected && SensitiveText.isProtectedBox(it.line.text) }
        val unselected = geometry.filter { it.line.id !in selected && !SensitiveText.isProtectedBox(it.line.text) }
        return chosen.map { line ->
            val g = LineGeometry.of(line, width, height)
            val theta = MaskSelector.directionOf(g, skew)
            val tilted = line.corners != null && abs(MaskSelector.degrees(theta)) >= MaskThresholds.MIN_TILT_DEGREES
            val pad = maxOf(8.0, g.textHeight * 0.3)
            val numberBox = line.numberBox?.takeIf { it.size == 4 && SensitiveText.isMixed(line.text) }
            val (uFrom, uTo) =
                if (numberBox != null) {
                    // 섞인 줄: 낱말 상자로 나눈 번호 부분만(앞뒤 여백), 같은 줄의 가격·날짜는 남긴다.
                    numberRange(numberBox, if (tilted) theta else 0.0, width, height, pad)
                } else {
                    rowLimits(g, if (tilted) theta else 0.0, protected + otherColumns(g, if (tilted) theta else 0.0, unselected), pad)
                }
            if (!tilted) {
                val top = line.y * height
                val bottom = (line.y + line.height) * height
                val vPad = maxOf(8.0, (bottom - top) * 0.3)
                MaskShape.Rect(
                    floor(uFrom ?: 0.0).toInt().coerceIn(0, width),
                    floor(top - vPad).toInt().coerceAtLeast(0),
                    ceil(uTo ?: width.toDouble()).toInt().coerceIn(0, width),
                    ceil(bottom + vPad).toInt().coerceAtMost(height),
                )
            } else {
                band(g, theta, width, height, uFrom, uTo)
            }
        }
    }

    /**
     * 같은 행에서 고르지 않은, 이 줄에서 멀리(줄 길이와 글자 높이 16배 중 큰 쪽보다) 떨어진 상자: 다른 열의 항목(수량 등)이라
     * 띠가 덮지 않는다. 그 사이의 읽지 못한 번호 끝자리는 띠가 덮는다.
     */
    private fun otherColumns(
        g: LineGeometry,
        theta: Double,
        unselected: List<LineGeometry>,
    ): List<LineGeometry> {
        val (top, bottom) = g.vRange(theta)
        val (u0, u1) = g.uRange(theta)
        val h = maxOf(bottom - top, 1.0)
        return unselected.filter { o ->
            val (ot, ob) = o.vRange(theta)
            val (o0, o1) = o.uRange(theta)
            abs((ot + ob) / 2 - (top + bottom) / 2) <= 0.5 * maxOf(h, ob - ot) && maxOf(u0, o0) - minOf(u1, o1) > maxOf(u1 - u0, 16 * h)
        }
    }

    /** 번호 부분 상자(0~1)의 보정 좌표 u 범위에 여백을 더한 것. */
    private fun numberRange(
        box: List<Double>,
        theta: Double,
        width: Int,
        height: Int,
        pad: Double,
    ): Pair<Double, Double> {
        val s = sin(theta)
        val c = cos(theta)
        val us =
            listOf(box[0] to box[1], box[2] to box[1], box[2] to box[3], box[0] to box[3]).map { (x, y) ->
                x * width * c + y * height * s
            }
        return us.min() - pad to us.max() + pad
    }

    /**
     * 행 전체 띠를 같은 행의 가격·날짜 상자 앞(여백 [pad])에서 멈춘다. 그 사이의 OCR이 따로 읽거나 놓친 번호 끝자리까지 덮는다.
     * 두 상자가 겹치면 이 줄 끝까지만 덮는다. 그런 상자가 없으면 null(행 끝까지).
     * 같은 행 = 보정 좌표에서 중심 차이가 두 줄 높이 중 큰 쪽의 절반 이하.
     */
    private fun rowLimits(
        g: LineGeometry,
        theta: Double,
        protected: List<LineGeometry>,
        pad: Double,
    ): Pair<Double?, Double?> {
        val (top, bottom) = g.vRange(theta)
        val (u0, u1) = g.uRange(theta)
        var from: Double? = null
        var to: Double? = null
        for (p in protected) {
            val (pt, pb) = p.vRange(theta)
            if (abs((pt + pb) / 2 - (top + bottom) / 2) > 0.5 * maxOf(bottom - top, pb - pt)) continue
            val (p0, p1) = p.uRange(theta)
            if ((p0 + p1) / 2 >= (u0 + u1) / 2) {
                to = minOf(to ?: Double.POSITIVE_INFINITY, maxOf(u1, p0 - pad))
            } else {
                from = maxOf(from ?: Double.NEGATIVE_INFINITY, minOf(u0, p1 + pad))
            }
        }
        return from to to
    }

    private fun band(
        g: LineGeometry,
        theta: Double,
        width: Int,
        height: Int,
        uFrom: Double?,
        uTo: Double?,
    ): MaskShape.Quad {
        val (top, bottom) = g.vRange(theta)
        val pad = maxOf(8.0, g.textHeight * 0.3)
        val s = sin(theta)
        val c = cos(theta)
        // 사진 네 모서리의 u 범위(행 전체 폭). 같은 행 가격·날짜 상자가 있으면 그 앞까지.
        val us =
            listOf(0.0 to 0.0, width.toDouble() to 0.0, width.toDouble() to height.toDouble(), 0.0 to height.toDouble()).map { (x, y) ->
                x *
                    c +
                    y * s
            }
        val u0 = uFrom ?: (us.min() - 1)
        val u1 = uTo ?: (us.max() + 1)
        val v0 = top - pad
        val v1 = bottom + pad
        val points = listOf(u0 to v0, u1 to v0, u1 to v1, u0 to v1)
        return MaskShape.Quad(points.map { (u, v) -> u * c - v * s }, points.map { (u, v) -> u * s + v * c })
    }
}

/** 사용자가 더한 띠(정수 퍼센트)를 픽셀 사각형으로. 위는 내림, 아래는 올림이라 경계 픽셀까지 덮는다(iOS와 같음). */
fun Masking.regionRects(
    regions: List<MaskRegion>,
    width: Int,
    height: Int,
): List<MaskShape> =
    regions.map { region ->
        MaskShape.Rect(0, region.topPercent * height / 100, width, minOf(height, (region.bottomPercent * height + 99) / 100))
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
