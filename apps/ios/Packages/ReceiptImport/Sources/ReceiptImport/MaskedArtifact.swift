import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 기기 밖으로 나갈 수 있는 값만 담은 영수증 필드. OCR 전문이나 원본 정보는 들어가지 않는다.
public struct AllowedReceiptFields: Codable, Equatable, Sendable {
  /// yyyy-MM-dd
  public var date: String
  /// 통화의 최소 단위(엔은 1엔).
  public var amountMinor: Int
  /// ISO 4217. 일본 영수증 기본값은 JPY다.
  public var currency: String
  public var merchant: String?

  public init(date: String, amountMinor: Int, currency: String, merchant: String?) {
    self.date = date
    self.amountMinor = amountMinor
    self.currency = currency
    self.merchant = merchant
  }
}

/// 사용자가 확인한 가림을 픽셀에 구운 새 PNG. `Masking.flatten`만 만들 수 있고,
/// 원본·OCR 결과와 다른 타입이라 실수로 원본을 내보낼 수 없다.
public struct MaskedArtifact: Equatable, Sendable {
  public let pngData: Data
  public let sha256: String

  fileprivate init(pngData: Data) {
    self.pngData = pngData
    self.sha256 = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
  }
}

/// 가림 도형(칠하는 순서, ADR-0013). 좌표는 왼쪽 위 기준 0~1.
/// 두 불변식을 지킨다.
/// 1. 가려야 할 민감 OCR 상자(번호가 든 고른 줄. 섞인 줄은 번호 부분)는 항상 완전히 덮는다(`cover`). 어떤 이유로도 줄이지 않는다.
///    숫자 없는 라벨 줄은 민감 값이 아니라 여백처럼 `black`이다.
/// 2. 민감 상자 밖에 더한 여백(`black`)은 보존 상자(가격·날짜·가게 정보·필드명과 그 값) 중 민감 상자 밖 픽셀을 덮지 않는다(`restore`).
/// 순서: `black`을 칠하고 → `restore`를 원본으로 되돌리고 → `cover`를 칠한다. 사용자가 켠 줄의 띠와 직접 더한 띠도 `cover`다.
public struct MaskPlan: Equatable, Sendable {
  public var black: [[CGPoint]]
  public var restore: [[CGPoint]]
  public var cover: [[CGPoint]]

  public init(black: [[CGPoint]], restore: [[CGPoint]] = [], cover: [[CGPoint]] = []) {
    self.black = black
    self.restore = restore
    self.cover = cover
  }

  /// 화면 표시·잔존 검사용 검정 도형(되돌림 전).
  public var drawn: [[CGPoint]] { black + cover }

  /// 그 점(0~1)이 굽힌 사본에서 검정인지. 칠하는 순서와 같다.
  public func covers(_ point: CGPoint) -> Bool {
    func inside(_ polygons: [[CGPoint]]) -> Bool {
      polygons.contains { points in
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path.contains(point)
      }
    }
    return inside(cover) || (inside(black) && !inside(restore))
  }
}

enum Masking {
  static func polygons(ocr: OCRResult, selected: Set<Int>, automatic: Set<Int>, regions: [MaskRegion]) -> [[CGPoint]] {
    plan(ocr: ocr, selected: selected, automatic: automatic, regions: regions).drawn
  }

  static func plan(ocr: OCRResult, selected: Set<Int>, automatic: Set<Int>, regions: [MaskRegion]) -> MaskPlan {
    let width = Double(ocr.pixelWidth)
    let height = Double(ocr.pixelHeight)
    var black: [[CGPoint]] = []
    var cover: [[CGPoint]] = []
    for line in ocr.lines where selected.contains(line.id) {
      guard automatic.contains(line.id), line.corners != nil else {
        // 제안을 보완하려고 켠 줄과 옛 초안은 기존 가로 띠를 유지한다(사용자가 고른 것이라 되돌리지 않는다).
        let pad = max(8, line.height * height * 0.3)
        cover.append(
          corners(
            CGRect(
              x: 0, y: floor(line.y * height - pad), width: width,
              height: ceil((line.y + line.height) * height + pad) - floor(line.y * height - pad))))
        continue
      }
      let partial = line.sensitiveCorners != nil
      let q = (line.sensitiveCorners ?? line.maskCorners).map { CGPoint(x: $0.x * width, y: $0.y * height) }
      let textHeight = (hypot(q[3].x - q[0].x, q[3].y - q[0].y) + hypot(q[2].x - q[1].x, q[2].y - q[1].y)) / 2
      let side = partial ? 2 : max(9, textHeight * 0.42)
      let vertical = partial ? 3 : max(8, textHeight * 0.30)
      black.append([
        expanded(q[0], awayFrom: q[1], by: side, and: q[3], by: vertical),
        expanded(q[1], awayFrom: q[0], by: side, and: q[2], by: vertical),
        expanded(q[2], awayFrom: q[3], by: side, and: q[1], by: vertical),
        expanded(q[3], awayFrom: q[2], by: side, and: q[0], by: vertical),
      ])
      // 반드시 덮을 상자: 번호(숫자·가림 기호)가 든 줄. 숫자 없는 라벨 줄(승인, 결제 카드)은 여백과 같이 되돌림 대상이다.
      if SensitiveText.normalize(line.text).contains(where: { $0.isNumber || "*●•#×".contains($0) }) {
        cover.append(q)
      } else {
        black.append(q)
      }
    }
    let restore = keptNeighbors(ocr: ocr, selected: selected).map { id in
      ocr.lines.first { $0.id == id }!.maskCorners.map { CGPoint(x: $0.x * width, y: $0.y * height) }
    }
    cover += rects(for: regions, width: ocr.pixelWidth, height: ocr.pixelHeight).map(corners)
    func normalized(_ polygons: [[CGPoint]]) -> [[CGPoint]] {
      polygons.map { points in points.map { CGPoint(x: $0.x / width, y: $0.y / height) } }
    }
    return MaskPlan(black: normalized(black), restore: normalized(restore), cover: normalized(cover))
  }

  /// 보존 상자: 고르지 않은 줄 중 가격·날짜·가게 정보(보호 상자), 필드명(수량·금액 등), 그리고 바로 왼쪽 상자가 필드명인 값 상자
  /// (수량 | 3). Android `Masking.keptBoxes`와 같은 규칙이다.
  static func keptNeighbors(ocr: OCRResult, selected: Set<Int>) -> [Int] {
    let width = Double(ocr.pixelWidth)
    let height = Double(ocr.pixelHeight)
    let boxes = ocr.lines.map { line -> (line: OCRLine, box: CGRect, text: SensitiveText) in
      let xs = line.maskCorners.map { $0.x * width }
      let ys = line.maskCorners.map { $0.y * height }
      let box = CGRect(
        x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
      return (line, box, SensitiveText(line.text))
    }
    func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
      min(a.maxY, b.maxY) - max(a.minY, b.minY) >= 0.5 * min(a.height, b.height)
    }
    return boxes.filter { candidate in
      guard !selected.contains(candidate.line.id) else { return false }
      if candidate.text.isProtected || candidate.text.isFieldName || candidate.text.isStoreInfo { return true }
      let left = boxes.filter {
        $0.line.id != candidate.line.id && sameRow($0.box, candidate.box)
          && $0.box.maxX <= candidate.box.minX + candidate.box.height * 0.5
      }.max { $0.box.maxX < $1.box.maxX }
      return left?.text.isFieldName == true
    }.map(\.line.id)
  }

  private static func expanded(
    _ point: CGPoint, awayFrom horizontal: CGPoint, by side: Double, and vertical: CGPoint, by pad: Double
  ) -> CGPoint {
    let x = point.x - horizontal.x
    let y = point.y - horizontal.y
    let dx = point.x - vertical.x
    let dy = point.y - vertical.y
    let along = side / max(1, hypot(x, y))
    let across = pad / max(1, hypot(dx, dy))
    return CGPoint(x: point.x + x * along + dx * across, y: point.y + y * along + dy * across)
  }

  private static func corners(_ rect: CGRect) -> [CGPoint] {
    [
      CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
    ]
  }

  /// 사용자가 더한 띠(정수 퍼센트)를 픽셀 사각형으로. 위는 내림, 아래는 올림이라 경계 픽셀까지 덮는다.
  static func rects(for regions: [MaskRegion], width: Int, height: Int) -> [CGRect] {
    regions.map { region in
      let y0 = (region.topPercent * height) / 100
      let y1 = min(height, (region.bottomPercent * height + 99) / 100)
      return CGRect(x: 0, y: y0, width: width, height: y1 - y0)
    }
  }

  /// 확인(사본)과 검토 화면 미리보기만 부른다. 새 비트맵에 검은 사각형을 굽고 원본 메타데이터 없이 PNG로 인코딩한다.
  static func flatten(original: URL, plan: MaskPlan) throws -> MaskedArtifact {
    let flattened = try render(ImageLoading.cgImage(original), plan: plan)
    let data = NSMutableData()
    guard
      let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { throw ProcessingFailure.invalidImage }
    CGImageDestinationAddImage(encoder, flattened, nil)
    guard CGImageDestinationFinalize(encoder) else { throw ProcessingFailure.invalidImage }
    return MaskedArtifact(pngData: try PNGChunks.stripAncillary(data as Data))
  }

  static func render(_ image: CGImage, polygons: [[CGPoint]]) throws -> CGImage {
    try render(image, plan: MaskPlan(black: polygons))
  }

  /// 칠하는 순서대로 굽는다: 검정 → 보존 상자를 원본으로 되돌림 → 민감 상자·사용자 띠 검정.
  static func render(_ image: CGImage, plan: MaskPlan) throws -> CGImage {
    let width = image.width
    let height = image.height
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw ProcessingFailure.invalidImage }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(bounds)
    ctx.draw(image, in: bounds)
    ctx.setShouldAntialias(false)
    // CGContext는 왼쪽 아래 기준이다.
    func add(_ polygon: [CGPoint]) {
      ctx.addLines(between: polygon.map { CGPoint(x: $0.x * Double(width), y: (1 - $0.y) * Double(height)) })
      ctx.closePath()
    }
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    for polygon in plan.black {
      add(polygon)
      ctx.fillPath()
    }
    for polygon in plan.restore {
      ctx.saveGState()
      add(polygon)
      ctx.clip()
      ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      ctx.fill(bounds)
      ctx.draw(image, in: bounds)
      ctx.restoreGState()
    }
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    for polygon in plan.cover {
      add(polygon)
      ctx.fillPath()
    }
    guard let flattened = ctx.makeImage() else { throw ProcessingFailure.invalidImage }
    return flattened
  }
}

/// 그리기에 필요한 PNG 청크만 남긴다(eXIf, tEXt, iTXt, iCCP, tIME 등 제거).
public enum PNGChunks {
  public static let allowed: Set<String> = ["IHDR", "PLTE", "tRNS", "sRGB", "IDAT", "IEND"]
  private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

  public static func names(_ png: Data) throws -> [String] {
    try chunks(png).map(\.0)
  }

  static func stripAncillary(_ png: Data) throws -> Data {
    var out = Data(signature)
    for (name, range) in try chunks(png) where allowed.contains(name) { out.append(png[range]) }
    return out
  }

  private static func chunks(_ png: Data) throws -> [(String, Range<Int>)] {
    let bytes = [UInt8](png)
    guard bytes.starts(with: signature) else { throw ProcessingFailure.invalidImage }
    var result: [(String, Range<Int>)] = []
    var offset = 8
    while bytes.count - offset >= 12 {
      let size = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
      let name = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
      guard size <= bytes.count - offset - 12 else { throw ProcessingFailure.invalidImage }
      result.append((name, png.startIndex + offset..<png.startIndex + offset + size + 12))
      offset += size + 12
      if name == "IEND" { return result }
    }
    throw ProcessingFailure.invalidImage
  }
}

func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
