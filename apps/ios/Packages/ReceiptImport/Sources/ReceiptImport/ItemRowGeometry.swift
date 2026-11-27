import Foundation

/// 품목 추출에서만 사진을 가로로 펴서 본다. Android의 ItemRowGeometry와 같은 규칙이다.
enum ItemRowGeometry {
  struct Box {
    let line: OCRLine
    let centerX: Double
    let observedY: Double
    var centerY: Double
    var height: Double
    let observedSlope: Double?

    func distance(to other: Box) -> Double {
      abs(centerY - other.centerY) / max(height, other.height, 1)
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
      return Box(
        line: line, centerX: centerX, observedY: y, centerY: y, height: line.height * height,
        observedSlope: slope(line, width: width, height: height))
    }
    let directions = original.compactMap { box -> Direction? in
      guard let slope = box.observedSlope else { return nil }
      return Direction(y: box.observedY - slope * box.centerX, slope: slope)
    }.sorted { $0.y < $1.y }

    guard directions.count >= 2 else { return (original, false) }
    let dominant = median(directions.map(\.slope))
    let midpoint = directions.count / 2
    let top = directions.prefix(midpoint)
    let bottom = directions.suffix(midpoint)
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
    // 짧은 줄이나 Vision이 축 정렬해서 반환한 상자는 방향 추정에 쓰지 않는다.
    guard dx >= max(12, 4 * boxHeight(line, height)) else { return nil }
    let slope = dy / dx
    return (0.02...0.6).contains(abs(slope)) ? slope : nil
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
