import CoreGraphics
import Foundation

/// 1차 후보 선택과 달리 가격·날짜 보호를 적용하지 않고 사본에 남은 번호를 확인한다.
enum ResidualMaskCheck {
  static func hasResidue(original: OCRResult, reread: OCRResult, lineIDs: Set<Int>, polygons: [[CGPoint]]) -> Bool {
    let originalIdentifiers = original.lines.filter { lineIDs.contains($0.id) }.map { line in
      let text = SensitiveText(line.text)
      var values = text.identifierValues
      if values.isEmpty, !text.hasLabel, text.isFragment(minDigits: 1) {
        let linked = SensitiveText.canonical(line.text)
        if linked.count >= 4 { values.append(linked) }
      }
      return (line: line, values: values, local: values + text.identifierLabels)
    }
    let wholeValues = Set(originalIdentifiers.flatMap(\.values))
    return reread.lines.contains { line in
      let text = SensitiveText(line.text)
      // 다시 읽어 새로 나타난 라벨과 값은 원본 후보와 무관하게 확인한다.
      if SensitiveText.hasMaskedCard(line.text) || (text.hasLabel && !text.valueRanges.isEmpty) { return true }
      let residue = SensitiveText.canonical(line.text)
      if wholeValues.contains(residue) || text.tokens.contains(where: wholeValues.contains) { return true }
      for entry in originalIdentifiers where !entry.local.isEmpty && near(line, entry.line.maskCorners) {
        if entry.local.contains(where: { containsFragment(of: $0, in: residue) }) { return true }
      }
      return ProposalBuilder.matches(#"(?:\d[\s-]*){3}"#, residue)
        && polygons.contains { near(line, $0) }
    }
  }

  private static func containsFragment(of value: String, in text: String) -> Bool {
    let characters = Array(value)
    return (0...(characters.count - 4)).contains { start in
      text.contains(String(characters[start..<(start + 4)]))
    }
  }

  private static func near(_ line: OCRLine, _ polygon: [CGPoint]) -> Bool {
    guard polygon.count == 4 else { return false }
    let left = (polygon[0] + polygon[3]) * 0.5
    let right = (polygon[1] + polygon[2]) * 0.5
    let height = (abs(polygon[3].y - polygon[0].y) + abs(polygon[2].y - polygon[1].y)) / 2
    let x = line.x + line.width / 2
    let y = line.y + line.height / 2
    let pad = min(0.035, max(0.008, (right.x - left.x) * 0.12))
    guard line.x + line.width >= left.x - pad, line.x <= right.x + pad else { return false }
    let fraction = (x - left.x) / max(0.001, right.x - left.x)
    let expected = left.y + (right.y - left.y) * fraction
    let textQuad = line.maskCorners
    let textHeight = (abs(textQuad[3].y - textQuad[0].y) + abs(textQuad[2].y - textQuad[1].y)) / 2
    return abs(y - expected) <= height / 2 + textHeight * 0.30
  }
}

private func + (left: CGPoint, right: CGPoint) -> CGPoint {
  CGPoint(x: left.x + right.x, y: left.y + right.y)
}

private func * (point: CGPoint, factor: Double) -> CGPoint {
  CGPoint(x: point.x * factor, y: point.y * factor)
}
