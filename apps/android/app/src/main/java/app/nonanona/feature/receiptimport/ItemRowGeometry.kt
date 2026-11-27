package app.nonanona.feature.receiptimport

import kotlin.math.abs

/** 품목 추출에서만 사진을 가로로 펴서 본다. iOS의 ItemRowGeometry와 같은 규칙이다. */
internal object ItemRowGeometry {
    data class Box(
        val line: OcrLine,
        val centerX: Double,
        val observedY: Double,
        val observedHeight: Double,
        val centerY: Double,
        val height: Double,
        val observedSlope: Double?,
        /** 모서리로 잰 상자의 가로 길이(기울기를 잰 길이). 모서리가 없으면 0. */
        val span: Double,
    ) {
        fun distance(other: Box): Double = abs(centerY - other.centerY) / maxOf(height, other.height, 1.0)

        /** 보정 전에는 두 상자가 기존의 행 묶음 허용 범위 밖에 있었는지 본다. */
        fun needsCorrectionToJoin(other: Box): Boolean {
            val earlierHeight = if (observedY <= other.observedY) observedHeight else other.observedHeight
            return abs(observedY - other.observedY) >= maxOf(1.0, earlierHeight) / 2
        }

        /** 보정과 같은 방향으로 기운 이름 상자라면, 그 상자 자체의 기울기만 따라가도 금액이 같은 행에 들어오는지 본다. */
        fun joinsAlongSlopeOf(
            name: Box,
            direction: Double,
        ): Boolean {
            val slope = name.observedSlope ?: return false
            if (abs(slope) < 0.01 || slope * direction <= 0) return false
            val predictedY = name.observedY + slope * (centerX - name.centerX)
            return abs(observedY - predictedY) < maxOf(height, name.height, 1.0) / 2
        }

        /** 모서리가 보여 주는 기울어짐이 상자 높이의 절반 이상이다. 이보다 작으면 모서리 오차와 구분하기 어렵다. */
        val showsTilt: Boolean get() = observedSlope?.let { abs(it) * span >= height / 2 } ?: false

        /** 보정 전 좌표에서 기존 행 묶음 허용 범위(높이의 절반) 안에 있다. */
        fun sharesObservedRowWith(other: Box): Boolean = !needsCorrectionToJoin(other)

        fun disagreesWithDirectionOf(name: Box): Boolean {
            val slope = name.observedSlope ?: return false
            val predictedY = name.observedY + slope * (centerX - name.centerX)
            return abs(observedY - predictedY) > 0.65 * maxOf(height, name.height, 1.0)
        }
    }

    /** 사진 전체에 쓴 보정. `strong`이면 기울기를 잰 긴 상자의 3분의 2 이상이 같은 방향이다. */
    data class Correction(
        val slope: Double,
        val agreeing: Int,
        val measured: Int,
    ) {
        val strong: Boolean get() = agreeing * 3 >= measured * 2

        /** 같은 상자의 기울기를 합의와 연결 판단에 두 번 쓰지 않도록, `box`의 표를 빼고 3분의 2 이상인지 본다. */
        fun strongExcluding(box: Box): Boolean {
            val slope = box.observedSlope ?: return strong
            val agreed = abs(slope) >= 0.01 && slope * this.slope > 0
            return (agreeing - if (agreed) 1 else 0) * 3 >= (measured - 1) * 2
        }
    }

    private data class Direction(
        val y: Double,
        val slope: Double,
    )

    fun boxes(ocr: OcrResult): Pair<List<Box>, Correction?> {
        val width = maxOf(1, ocr.pixelWidth).toDouble()
        val height = maxOf(1, ocr.pixelHeight).toDouble()
        val original =
            ocr.lines.map { line ->
                val centerX = (line.x + line.width / 2 - 0.5) * width
                val y = (line.y + line.height / 2) * height
                val observedHeight = line.height * height
                Box(line, centerX, y, observedHeight, y, observedHeight, slope(line, width, height), span(line, width))
            }
        val directions =
            original
                .mapNotNull { box ->
                    val slope = box.observedSlope ?: return@mapNotNull null
                    Direction(box.observedY - slope * box.centerX, slope)
                }.sortedBy { it.y }
        // 수평에 가까운 긴 상자도 분모에 넣는다. 바닥이나 배경만 기울어진 사진에는 전체 보정을 쓰지 않는다.
        val positive = directions.filter { it.slope >= 0.01 }
        val negative = directions.filter { it.slope <= -0.01 }
        val agreeing = if (positive.size >= negative.size) positive else negative
        if (agreeing.size < 2 || agreeing.size <= directions.size / 2) return original to null
        val dominant = median(agreeing.map { it.slope })
        if (abs(dominant) < 0.015) return original to null
        val top = agreeing.take(agreeing.size / 2)
        val bottom = agreeing.takeLast(agreeing.size / 2)
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
        return boxes to Correction(dominant, agreeing.size, directions.size)
    }

    private fun span(
        line: OcrLine,
        width: Double,
    ): Double {
        val corners = line.corners?.takeIf { it.size == 8 } ?: return 0.0
        return (corners[2] - corners[0] + corners[4] - corners[6]) * width / 2
    }

    private fun slope(
        line: OcrLine,
        width: Double,
        height: Double,
    ): Double? {
        val corners = line.corners?.takeIf { it.size == 8 } ?: return null
        val dx = span(line, width)
        val dy = (corners[3] - corners[1] + corners[5] - corners[7]) * height / 2
        // 짧은 상자와 가로 글줄로 보기 어려운 상자는 방향 추정에 쓰지 않는다.
        if (dx < maxOf(12.0, 4 * boxHeight(line, height))) return null
        return (dy / dx).takeIf { abs(it) <= 0.6 }
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
