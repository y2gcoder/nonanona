package app.nonanona.feature.receiptimport

import kotlin.math.abs

/** 품목 추출에서만 사진을 가로로 펴서 본다. iOS의 ItemRowGeometry와 같은 규칙이다. */
internal object ItemRowGeometry {
    data class Box(
        val line: OcrLine,
        val centerX: Double,
        val observedY: Double,
        val centerY: Double,
        val height: Double,
        val observedSlope: Double?,
    ) {
        fun distance(other: Box): Double = abs(centerY - other.centerY) / maxOf(height, other.height, 1.0)

        fun disagreesWithDirectionOf(name: Box): Boolean {
            val slope = name.observedSlope ?: return false
            val predictedY = name.observedY + slope * (centerX - name.centerX)
            return abs(observedY - predictedY) > 0.65 * maxOf(height, name.height, 1.0)
        }
    }

    private data class Direction(
        val y: Double,
        val slope: Double,
    )

    fun boxes(ocr: OcrResult): Pair<List<Box>, Boolean> {
        val width = maxOf(1, ocr.pixelWidth).toDouble()
        val height = maxOf(1, ocr.pixelHeight).toDouble()
        val original =
            ocr.lines.map { line ->
                val centerX = (line.x + line.width / 2 - 0.5) * width
                val y = (line.y + line.height / 2) * height
                Box(line, centerX, y, y, line.height * height, slope(line, width, height))
            }
        val directions =
            original
                .mapNotNull { box ->
                    val slope = box.observedSlope ?: return@mapNotNull null
                    Direction(box.observedY - slope * box.centerX, slope)
                }.sortedBy { it.y }
        if (directions.size < 2) return original to false
        val dominant = median(directions.map { it.slope })
        val top = directions.take(directions.size / 2)
        val bottom = directions.takeLast(directions.size / 2)
        val topY = median(top.map { it.y })
        val span = median(bottom.map { it.y }) - topY
        val topSlope = median(top.map { it.slope })
        val bottomSlope = median(bottom.map { it.slope })
        // 두 높이 구간의 대표 기울기로 원근에서의 행 방향을 보간한다.
        val rate = if (span >= height / 5) (bottomSlope - topSlope) / span else 0.0
        val boxes =
            original.map { box ->
                val y = box.observedY
                val offset = box.centerX
                val scale = 1 + rate * offset
                var slope = dominant
                if (rate != 0.0 && scale in 0.5..1.5) {
                    val projectedY = (y - (topSlope - rate * topY) * offset) / scale
                    slope = (topSlope + rate * (projectedY - topY)).coerceIn(minOf(topSlope, bottomSlope), maxOf(topSlope, bottomSlope))
                }
                box.copy(centerY = y - slope * offset, height = boxHeight(box.line, height))
            }
        return boxes to true
    }

    private fun slope(
        line: OcrLine,
        width: Double,
        height: Double,
    ): Double? {
        val corners = line.corners?.takeIf { it.size == 8 } ?: return null
        val dx = (corners[2] - corners[0] + corners[4] - corners[6]) * width / 2
        val dy = (corners[3] - corners[1] + corners[5] - corners[7]) * height / 2
        // 짧은 줄이나 축 정렬 상자는 방향 추정에 쓰지 않는다.
        if (dx < maxOf(12.0, 4 * boxHeight(line, height))) return null
        return (dy / dx).takeIf { abs(it) in 0.02..0.6 }
    }

    private fun boxHeight(
        line: OcrLine,
        height: Double,
    ): Double {
        val corners = line.corners?.takeIf { it.size == 8 } ?: return line.height * height
        return maxOf(1.0, (corners[5] + corners[7] - corners[1] - corners[3]) * height / 2)
    }

    private fun median(values: List<Double>): Double {
        val sorted = values.sorted()
        return (sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2
    }
}
