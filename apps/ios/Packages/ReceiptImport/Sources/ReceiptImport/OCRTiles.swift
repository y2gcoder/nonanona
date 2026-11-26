import CoreGraphics

/// 각 타일의 왼쪽 위를 기준으로 읽은 상자를 원본 좌표로 옮긴다.
struct OCRTile {
  let top: Int
  let height: Int
  let lines: [OCRLine]

  static func merge(_ tiles: [Self], imageHeight: Int) -> [OCRLine] {
    if let tile = tiles.first, tiles.count == 1, tile.top == 0, tile.height == imageHeight {
      return tile.lines.sorted { $0.y < $1.y }
    }
    let observations = tiles.flatMap { tile in
      tile.lines.map { line in
        func fullY(_ y: Double) -> Double { (Double(tile.top) + y * Double(tile.height)) / Double(imageHeight) }
        func fullCorners(_ corners: [CGPoint]?) -> [CGPoint]? {
          corners?.map { CGPoint(x: $0.x, y: fullY($0.y)) }
        }
        let translated = OCRLine(
          id: 0, text: line.text, x: line.x, y: fullY(line.y), width: line.width,
          height: line.height * Double(tile.height) / Double(imageHeight), corners: fullCorners(line.corners),
          sensitiveCorners: fullCorners(line.sensitiveCorners), confidence: line.confidence)
        let top = tile.top == 0 ? Double.infinity : line.y
        let bottom = tile.top + tile.height == imageHeight ? Double.infinity : 1 - line.y - line.height
        return Observation(
          line: translated, tileTop: tile.top, edgeClearance: min(top, bottom) / max(line.height, 0.001))
      }
    }
    // 경계에서 잘린 상자는 완전한 상자를 우선한다. 다른 타일에 짝이 없으면 관측을 남긴다.
    let preferred = observations.sorted { first, second in
      if first.isClipped != second.isClipped { return !first.isClipped }
      if first.inkArea != second.inkArea { return first.inkArea > second.inkArea }
      if first.textLength != second.textLength { return first.textLength > second.textLength }
      return first.edgeClearance > second.edgeClearance
    }
    var kept: [Observation] = []
    for observation in preferred {
      if !kept.contains(where: { observation.isDuplicate(of: $0) }) {
        kept.append(observation)
      }
    }
    return kept.map(\.line).sorted { $0.y < $1.y }
  }

  private struct Observation {
    let line: OCRLine
    let tileTop: Int
    let edgeClearance: Double

    var isClipped: Bool { edgeClearance < 0.25 }
    var inkArea: Double { line.width * line.height }
    var textLength: Int { line.text.count }

    func isDuplicate(of other: Self) -> Bool {
      guard tileTop != other.tileTop else { return false }
      let a = line
      let b = other.line
      let horizontal = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
      let vertical = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
      return horizontal >= min(a.width, b.width) * 0.65 && vertical >= min(a.height, b.height) * 0.50
    }
  }
}
