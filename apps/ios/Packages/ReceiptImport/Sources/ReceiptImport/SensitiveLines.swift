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
    // 다른 라벨의 칸이라 건너뛴 짧은 번호 조각. 끝까지 아무 라벨도 가리지 않으면 확인을 안내한다.
    var skipped: Set<Int> = []
    // 독립 약한 라벨(승인 | 4938, 승인 / 다음 행 4938)은 강한 라벨과 같이 값을 찾고, 못 찾으면 안내한다(ADR-0013).
    for label in rows where label.text.hasLabel || label.text.isWeakStandaloneLabel {
      selected.insert(label.line.id)
      let neighbors = rows.filter { $0.line.id != label.line.id }
      let row = neighbors.filter { label.sameRow(as: $0) }
      // 같은 행의 다른 라벨은 이 라벨의 값이 닿는 범위의 경계다. 값은 시작점이 그 값의 중심보다 앞서는 라벨 중 가장 가까운 라벨의
      // 것이다(상자가 겹쳐도 같다). 가격·날짜 상자는 경계가 아니다(값 뒤 조각을 계속 묶고, 가격 자체는 묶지 않는다).
      let walls = row.filter { $0.text.hasLabel || $0.text.isWeakStandaloneLabel }
      // 다른 필드명(수량·결제 금액 등)도 값의 소유자다. 그 필드의 값은 이 라벨이 묶지 않고 안내도 하지 않는다.
      let fields = row.filter { $0.text.isFieldName }
      // 값 중심보다 시작점이 앞서는 라벨·필드명 중 가장 가까운 것: 이 라벨이면 0, 다른 민감 라벨이면 1, 필드명이면 2, 없으면 nil.
      func owner(_ candidate: Row) -> Int? {
        let mid = (candidate.left.x + candidate.right.x) / 2
        let owners =
          [(label.left.x, 0)] + walls.filter { $0.line.id != candidate.line.id }.map { ($0.left.x, 1) }
          + fields.filter { $0.line.id != candidate.line.id }.map { ($0.left.x, 2) }
        return owners.filter { $0.0 < mid }.max { $0.0 < $1.0 }?.1
      }
      func owned(_ candidate: Row) -> Bool {
        let who = owner(candidate)
        return who == nil || who == 0
      }
      let same = row.filter(owned)
      for candidate in row
      where owner(candidate) == 1 && label.isNear(candidate) && !candidate.text.hasLabel
        && !candidate.text.hasStrongNumber && candidate.text.isFragment(minDigits: 2)
      {
        skipped.insert(candidate.line.id)
      }
      // 약한 라벨 뒤에 따로 읽힌 "번호 4938"은 이 라벨의 값이다.
      let numberWordValue = same.contains {
        $0.text.hasLabel && $0.text.startsWithNumberWord && !$0.text.valueRanges.isEmpty && label.isNear($0)
          && $0.left.x >= label.left.x
      }
      // 가장 가까운 다음 행이 다른 항목이면 그 너머의 숫자를 끌어오지 않는다.
      // 다음 행 값의 왼쪽에 그 행의 다른 필드명(결제 금액 | 1200, 수량 | 120)이 있으면 그 필드의 값이다.
      // 값 바로 왼쪽 상자가 숫자 없는 필드명이면 그 필드의 값이다(AB8972 같은 값 상자는 필드명이 아니다).
      func ownedByRowLabel(_ candidate: Row) -> Bool {
        let left = rows.filter { other in
          other.line.id != candidate.line.id && other.line.id != label.line.id && candidate.sameRow(as: other)
            && other.right.x <= candidate.left.x + candidate.height * 0.5
        }.max { $0.right.x < $1.right.x }
        return left?.text.hasFieldName == true
      }
      let below = neighbors.filter {
        !label.sameRow(as: $0) && label.verticalOffset(to: $0) > 0 && label.isAligned(with: $0)
          && !ownedByRowLabel($0)
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
      // 묶음의 끝은 보호 상자(가격·날짜)나 다른 라벨의 시작점이다(다열 행에서도 그 앞의 한 자리 묶음은 이 라벨의 값이다).
      let following = row.filter { $0.left.x >= label.right.x }.sorted { $0.left.x < $1.left.x }
      let beforeProtected = following.prefix { candidate in
        !candidate.text.isProtected && !candidate.text.isFieldName
          && !walls.contains { $0.line.id == candidate.line.id }
      }
      let digits = beforeProtected.filter {
        let value = SensitiveText.canonical($0.text.text)
        return value.count == 1 && value.first?.isNumber == true
      }
      let maxGap = label.height * 0.85
      var foundDigit = false
      var looseDigit = false
      for (index, digit) in digits.enumerated() {
        let gap = digit.left.x - right
        let startsChain =
          !label.text.valueRanges.isEmpty && beforeProtected.count < following.count
          && gap <= label.height * 12 && index + 2 < digits.count
          && digits[index + 1].left.x - digit.right.x <= maxGap
          && digits[index + 2].left.x - digits[index + 1].right.x <= maxGap
        guard gap <= maxGap || startsChain else {
          // 가까운 한 자리 숫자를 묶을 근거가 없으면 확인을 안내한다.
          if gap <= label.height * 12 && !selected.contains(digit.line.id) { looseDigit = true }
          continue
        }
        selected.insert(digit.line.id)
        right = max(right, digit.right.x)
        foundDigit = true
      }
      // 결제 화면의 "라벨 ……… 값" 행처럼 같은 행의 먼 칸이 이미 강한 번호로 가려지면 짝이 있는 라벨이다(ADR-0013).
      // 다른 라벨 줄 안의 번호(승인번호 334522)는 그 라벨의 값이라 이 라벨의 짝이 아니다(Android와 같다).
      let strongOnRow = same.contains { $0.text.hasStrongNumber && !$0.text.hasLabel && $0.left.x >= label.right.x }
      if label.text.valueRanges.isEmpty && fragments.isEmpty && !foundDigit && !strongOnRow && !numberWordValue {
        hasUnpairedLabel = true
      }
      // 보호 상자 뒤라도 라벨 오른쪽 가까이 남은 한 자리 숫자 조각은 확인을 안내한다(Android와 같다).
      let trailing = following.filter { candidate in
        owned(candidate) && candidate.left.x - label.right.x <= label.height * 12
          && SensitiveText.canonical(candidate.text.text).count == 1
          && SensitiveText.canonical(candidate.text.text).first?.isNumber == true
      }
      if looseDigit || trailing.contains(where: { !selected.contains($0.line.id) }) { hasUnpairedLabel = true }
    }
    if !skipped.subtracting(selected).isEmpty { hasUnpairedLabel = true }
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
