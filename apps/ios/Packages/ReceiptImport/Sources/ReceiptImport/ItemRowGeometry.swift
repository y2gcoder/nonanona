import Foundation

/// 품목 추출에서만 사진을 가로로 펴서 본다. Android의 ItemRowGeometry와 같은 규칙이다.
enum ItemRowGeometry {
  struct Box {
    let line: OCRLine
    let centerX: Double
    let observedY: Double
    let observedHeight: Double
    var centerY: Double
    var height: Double
    let observedSlope: Double?

    func distance(to other: Box) -> Double {
      abs(centerY - other.centerY) / max(height, other.height, 1)
    }

    /// 보정 전에는 두 상자가 기존의 행 묶음 허용 범위 밖에 있었는지 본다.
    func needsCorrectionToJoin(_ other: Box) -> Bool {
      let earlierHeight = observedY <= other.observedY ? observedHeight : other.observedHeight
      return abs(observedY - other.observedY) >= max(1, earlierHeight) / 2
    }

    func disagreesWithDirection(of name: Box) -> Bool {
      guard let slope = name.observedSlope else { return false }
      let predictedY = name.observedY + slope * (centerX - name.centerX)
      return abs(observedY - predictedY) > 0.65 * max(height, name.height, 1)
    }
  }

  private struct Direction {
    let y: Double
    let slope: Double
  }

  static func boxes(_ ocr: OCRResult) -> (boxes: [Box], corrected: Bool) {
    let width = Double(max(1, ocr.pixelWidth))
    let height = Double(max(1, ocr.pixelHeight))
    let original = ocr.lines.map { line in
      let centerX = (line.x + line.width / 2 - 0.5) * width
      let y = (line.y + line.height / 2) * height
      let observedHeight = line.height * height
      return Box(
        line: line, centerX: centerX, observedY: y, observedHeight: observedHeight, centerY: y, height: observedHeight,
        observedSlope: slope(line, width: width, height: height))
    }
    let directions = original.compactMap { box -> Direction? in
      guard let slope = box.observedSlope else { return nil }
      return Direction(y: box.observedY - slope * box.centerX, slope: slope)
    }.sorted { $0.y < $1.y }

    // 수평에 가까운 긴 상자도 분모에 넣는다. 바닥이나 배경만 기울어진 사진에는 전체 보정을 쓰지 않는다.
    let positive = directions.filter { $0.slope >= 0.01 }
    let negative = directions.filter { $0.slope <= -0.01 }
    let agreeing = positive.count >= negative.count ? positive : negative
    guard agreeing.count >= 2, agreeing.count > directions.count / 2 else { return (original, false) }
    let dominant = median(agreeing.map(\.slope))
    guard abs(dominant) >= 0.015 else { return (original, false) }
    let midpoint = agreeing.count / 2
    let top = agreeing.prefix(midpoint)
    let bottom = agreeing.suffix(midpoint)
    let topY = median(top.map(\.y))
    let span = median(bottom.map(\.y)) - topY
    let topSlope = median(top.map(\.slope))
    let bottomSlope = median(bottom.map(\.slope))
    // 두 높이 구간의 대표 기울기로 원근에서의 행 방향을 보간한다.
    let rate = span >= height / 5 ? (bottomSlope - topSlope) / span : 0
    let boxes = original.map { box in
      let y = box.observedY
      let offset = box.centerX
      let scale = 1 + rate * offset
      var slope = dominant
      if rate != 0, scale >= 0.5, scale <= 1.5 {
        let projectedY = (y - (topSlope - rate * topY) * offset) / scale
        slope = min(max(topSlope + rate * (projectedY - topY), min(topSlope, bottomSlope)), max(topSlope, bottomSlope))
      }
      var corrected = box
      corrected.centerY = y - slope * offset
      corrected.height = boxHeight(box.line, height)
      return corrected
    }
    return (boxes, true)
  }

  private static func slope(_ line: OCRLine, width: Double, height: Double) -> Double? {
    guard let corners = line.corners, corners.count == 4 else { return nil }
    let dx = (corners[1].x - corners[0].x + corners[2].x - corners[3].x) * width / 2
    let dy = (corners[1].y - corners[0].y + corners[2].y - corners[3].y) * height / 2
    // 짧은 상자와 가로 글줄로 보기 어려운 상자는 방향 추정에 쓰지 않는다.
    guard dx >= max(12, 4 * boxHeight(line, height)) else { return nil }
    let slope = dy / dx
    return abs(slope) <= 0.6 ? slope : nil
  }

  private static func boxHeight(_ line: OCRLine, _ height: Double) -> Double {
    guard let corners = line.corners, corners.count == 4 else { return line.height * height }
    return max(1, (corners[2].y + corners[3].y - corners[0].y - corners[1].y) * height / 2)
  }

  private static func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
  }
}
