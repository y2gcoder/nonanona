import CoreGraphics
import Foundation

/// 원본의 회전과 원근을 유지한 채 Vision의 글자 모서리로 가림 행을 찾는다.
struct SensitiveLines {
  let ids: Set<Int>
  let unmatchedLabel: Bool
  let tilt: Double
  let isTilted: Bool

  init(_ ocr: OCRResult) {
    let rows = ocr.lines.map { Row(line: $0, width: Double(ocr.pixelWidth), height: Double(ocr.pixelHeight)) }
    let angles = rows.filter { $0.span >= 3 * $0.height }.map(\.angle).sorted()
    let absolute = angles.map(abs).sorted()
    tilt = absolute.isEmpty ? 0 : absolute[absolute.count * 3 / 4]
    // 일정하게 회전한 행은 가림 다각형도 함께 회전한다. 행 사이 각도가 벌어지는 경우만 불확실하다.
    isTilted = angles.count >= 5 && angles[angles.count * 4 / 5] - angles[angles.count / 5] > 4
    let commercialRows = rows.filter { $0.text.protectsCommercialRow }
    var selected = Set(
      rows.filter { row in
        row.text.hasLabel || row.text.hasStrongNumber
          || (row.text.hasBookingCode && !commercialRows.contains { row.sameRow(as: $0) })
      }.map(\.line.id))
    var hasUnpairedLabel = false
    // 약한 라벨 낱말만 있는 행(승인 | 4938처럼 값이 따로 읽힘)은 같은 행에서 번호 조각을 찾을 때만 라벨로 본다(ADR-0013).
    for label in rows where label.text.hasLabel || label.text.hasWeakLabelWord {
      let strong = label.text.hasLabel
      let neighbors = rows.filter { $0.line.id != label.line.id }
      let row = neighbors.filter { label.sameRow(as: $0) }
      // 같은 행의 다른 라벨과 가격·날짜 상자는 이 라벨의 값이 닿는 범위의 경계다(다열 행에서 다른 항목의 번호를 짝으로 잡지 않는다).
      let walls = row.filter { $0.text.hasLabel || $0.text.hasWeakLabelWord || $0.text.isProtected }
      let same = row.filter { candidate in
        !walls.contains { wall in
          wall.line.id != candidate.line.id
            && (candidate.left.x >= label.right.x
              ? wall.left.x >= label.right.x && wall.right.x <= candidate.left.x
              : wall.right.x <= label.left.x && wall.left.x >= candidate.right.x)
        }
      }
      if !strong {
        let fragments = same.filter { candidate in
          label.isNear(candidate) && !candidate.text.hasLabel
            && (candidate.text.hasNumber || candidate.text.isFragment(minDigits: 2))
        }
        if !fragments.isEmpty {
          selected.insert(label.line.id)
          selected.formUnion(fragments.map(\.line.id))
        }
        continue
      }
      // 가장 가까운 다음 행이 다른 항목이면 그 너머의 숫자를 끌어오지 않는다.
      let below = neighbors.filter {
        !label.sameRow(as: $0) && label.verticalOffset(to: $0) > 0 && label.isAligned(with: $0)
      }
      let next = below.map { label.verticalOffset(to: $0) }.min()
      let continuation = below.filter {
        let offset = label.verticalOffset(to: $0)
        return offset <= label.height * 2.1 && offset <= (next ?? 0) + label.height * 0.45
      }
      let nearby = same.filter { label.isNear($0) } + continuation
      let fragments = nearby.filter { candidate in
        !candidate.text.hasLabel && (candidate.text.hasNumber || candidate.text.isFragment(minDigits: 2))
      }
      selected.formUnion(fragments.map(\.line.id))
      // 떨어진 한 자리 묶음은 인라인 번호와 같은 행에서 보호 상자 앞에 이어질 때만 연결한다.
      var right = max(label.right.x, fragments.filter { label.sameRow(as: $0) }.map { $0.right.x }.max() ?? 0)
      let following = same.filter { $0.left.x >= label.right.x }.sorted { $0.left.x < $1.left.x }
      let beforeProtected = following.prefix { !$0.text.isProtected }
      let digits = beforeProtected.filter {
        let value = SensitiveText.canonical($0.text.text)
        return value.count == 1 && value.first?.isNumber == true
      }
      let maxGap = label.height * 0.85
      var foundDigit = false
      for (index, digit) in digits.enumerated() {
        let gap = digit.left.x - right
        let startsChain =
          !label.text.valueRanges.isEmpty && beforeProtected.count < following.count
          && gap <= label.height * 12 && index + 2 < digits.count
          && digits[index + 1].left.x - digit.right.x <= maxGap
          && digits[index + 2].left.x - digits[index + 1].right.x <= maxGap
        guard gap <= maxGap || startsChain else { continue }
        selected.insert(digit.line.id)
        right = max(right, digit.right.x)
        foundDigit = true
      }
      // 결제 화면의 "라벨 ……… 값" 행처럼 같은 행의 먼 칸이 이미 강한 번호로 가려지면 짝이 있는 라벨이다(ADR-0013).
      let strongOnRow = same.contains { $0.text.hasStrongNumber && $0.left.x >= label.right.x }
      if label.text.valueRanges.isEmpty && fragments.isEmpty && !foundDigit && !strongOnRow {
        hasUnpairedLabel = true
      }
    }
    ids = selected
    unmatchedLabel =
      hasUnpairedLabel
      || rows.contains { selected.contains($0.line.id) && $0.text.isMixed && $0.line.sensitiveCorners == nil }
  }

  private struct Row {
    let line: OCRLine
    let left: CGPoint
    let right: CGPoint
    let height: Double
    let text: SensitiveText

    init(line: OCRLine, width: Double, height imageHeight: Double) {
      self.line = line
      let quad = line.maskCorners.map { CGPoint(x: $0.x * width, y: $0.y * imageHeight) }
      left = Self.midpoint(quad[0], quad[3])
      right = Self.midpoint(quad[1], quad[2])
      height = max(
        1,
        (hypot(quad[0].x - quad[3].x, quad[0].y - quad[3].y)
          + hypot(quad[1].x - quad[2].x, quad[1].y - quad[2].y)) / 2)
      text = SensitiveText(line.text)
    }

    var span: Double { max(1, right.x - left.x) }
    var slope: Double { (right.y - left.y) / span }
    var angle: Double { atan(slope) * 180 / .pi }
    var mid: CGPoint { Self.midpoint(left, right) }
    func verticalOffset(to other: Self) -> Double {
      let dx = other.mid.x - mid.x
      return other.mid.y - mid.y - (slope + other.slope) / 2 * dx
    }

    func sameRow(as other: Self) -> Bool {
      abs(verticalOffset(to: other)) <= max(height, other.height) * 0.65
    }

    func isAligned(with other: Self) -> Bool {
      max(left.x, other.left.x) - min(right.x, other.right.x) <= height
    }

    func isNear(_ other: Self) -> Bool {
      max(left.x, other.left.x) - min(right.x, other.right.x) <= max(span, 8 * height)
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
      CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
  }
}

extension OCRLine {
  var maskCorners: [CGPoint] {
    if let corners, corners.count == 4 { return corners }
    return [
      CGPoint(x: x, y: y), CGPoint(x: x + width, y: y),
      CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height),
    ]
  }
}
