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

enum Masking {
  static func polygons(ocr: OCRResult, selected: Set<Int>, automatic: Set<Int>, regions: [MaskRegion]) -> [[CGPoint]] {
    let width = Double(ocr.pixelWidth)
    let height = Double(ocr.pixelHeight)
    let keeps = keptNeighbors(ocr: ocr, selected: selected)
    let lines = ocr.lines.filter { selected.contains($0.id) }.map { line -> [CGPoint] in
      guard automatic.contains(line.id), line.corners != nil else {
        // 제안을 보완하려고 켠 줄과 옛 초안은 기존 가로 띠를 유지한다.
        let pad = max(8, line.height * height * 0.3)
        return corners(
          CGRect(
            x: 0, y: floor(line.y * height - pad), width: width,
            height: ceil((line.y + line.height) * height + pad) - floor(line.y * height - pad)))
      }
      let partial = line.sensitiveCorners != nil
      let q = (line.sensitiveCorners ?? line.maskCorners).map { CGPoint(x: $0.x * width, y: $0.y * height) }
      let textHeight = (hypot(q[3].x - q[0].x, q[3].y - q[0].y) + hypot(q[2].x - q[1].x, q[2].y - q[1].y)) / 2
      let side = partial ? 2 : max(9, textHeight * 0.42)
      let vertical = partial ? 3 : max(8, textHeight * 0.30)
      // 이웃한 보존 상자(가격·날짜·가게 정보·필드명과 그 값) 쪽 여백은 두 상자 간격의 절반까지만 둔다(ADR-0013).
      // 가릴 상자 자체는 그대로 다 덮는다.
      // 기운 줄(원근·회전)은 외접 사각형이 실제 글자보다 커서 이웃 판단이 틀리므로 예전 여백을 그대로 쓴다.
      let room =
        isAxisAligned(q)
        ? margins(
          for: q, keeps: keeps.filter { $0.id != line.id }.map(\.box), width: width, height: height,
          labelOnly: !line.text.contains { $0.isNumber })
        : (left: Double.infinity, right: Double.infinity, top: Double.infinity, bottom: Double.infinity)
      let left = min(side, room.left)
      let right = min(side, room.right)
      let top = min(vertical, room.top)
      let bottom = min(vertical, room.bottom)
      return [
        expanded(q[0], awayFrom: q[1], by: left, and: q[3], by: top),
        expanded(q[1], awayFrom: q[0], by: right, and: q[2], by: top),
        expanded(q[2], awayFrom: q[3], by: right, and: q[1], by: bottom),
        expanded(q[3], awayFrom: q[2], by: left, and: q[0], by: bottom),
      ]
    }
    let manual = rects(for: regions, width: ocr.pixelWidth, height: ocr.pixelHeight).map(corners)
    return (lines + manual).map { points in points.map { CGPoint(x: $0.x / width, y: $0.y / height) } }
  }

  /// 가림 여백이 닿으면 안 되는 이웃: 고르지 않은 줄 중 가격·날짜·가게 정보(보호 상자), 필드명(수량·금액 등), 그리고 바로 왼쪽
  /// 상자가 필드명인 값 상자(수량 | 3). 상자는 픽셀 좌표의 축 정렬 사각형이다.
  /// 가릴 줄이 이웃 보존 상자와 겹쳐 그 경계까지 줄였다(겹친 부분의 번호 잉크가 남을 수 있어 가림 확인을 안내한다).
  static func overlapsKeptNeighbor(ocr: OCRResult, selected: Set<Int>) -> Bool {
    let keeps = keptNeighbors(ocr: ocr, selected: selected)
    let width = Double(ocr.pixelWidth)
    let height = Double(ocr.pixelHeight)
    return ocr.lines.contains { line in
      guard selected.contains(line.id), line.corners != nil, line.sensitiveCorners == nil else { return false }
      let q = line.maskCorners.map { CGPoint(x: $0.x * width, y: $0.y * height) }
      guard isAxisAligned(q) else { return false }
      let room = margins(
        for: q, keeps: keeps.filter { $0.id != line.id }.map(\.box), width: width, height: height,
        labelOnly: !line.text.contains { $0.isNumber })
      return room.left < 0 || room.right < 0 || room.top < 0 || room.bottom < 0
    }
  }

  static func keptNeighbors(ocr: OCRResult, selected: Set<Int>) -> [(id: Int, box: CGRect)] {
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
      guard !selected.contains(candidate.line.id),
        isAxisAligned(candidate.line.maskCorners.map { CGPoint(x: $0.x * width, y: $0.y * height) })
      else { return false }
      if candidate.text.isProtected || candidate.text.isFieldName || candidate.text.isStoreInfo { return true }
      let left = boxes.filter {
        $0.line.id != candidate.line.id && sameRow($0.box, candidate.box)
          && $0.box.maxX <= candidate.box.minX + candidate.box.height * 0.5
      }.max { $0.box.maxX < $1.box.maxX }
      return left?.text.isFieldName == true
    }.map { ($0.line.id, $0.box) }
  }

  /// 거의 기울지 않은 상자(위·아래 변의 높이 차와 좌·우 변의 가로 차가 1px 이하). 보존 이웃 여백 조정은 이런 상자끼리만 한다.
  static func isAxisAligned(_ q: [CGPoint]) -> Bool {
    q.count == 4 && abs(q[1].y - q[0].y) <= 1 && abs(q[2].y - q[3].y) <= 1 && abs(q[3].x - q[0].x) <= 1
      && abs(q[2].x - q[1].x) <= 1
  }

  /// 가릴 줄의 네 변마다 이웃 보존 상자까지 둘 수 있는 여백. 떨어져 있으면 간격의 절반이다. 겹치면 왼쪽(라벨 쪽)은 음수로 그
  /// 상자 경계까지 줄인다. 번호가 놓이는 오른쪽과 위아래는 0에서 멈춘다(겹친 번호 끝은 덮는다, 공통 표 overlapping-ocr-boxes).
  /// 숫자 없는 라벨 상자(`labelOnly`)는 네 변 모두 줄인다.
  /// 대각선으로 붙은 상자는 가로 여백을 간격의 절반으로 줄인다. 이웃이 없으면 무한대.
  private static func margins(for q: [CGPoint], keeps: [CGRect], width: Double, height: Double, labelOnly: Bool = false)
    -> (left: Double, right: Double, top: Double, bottom: Double)
  {
    let xs = q.map(\.x)
    let ys = q.map(\.y)
    let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    var room = (left: Double.infinity, right: Double.infinity, top: Double.infinity, bottom: Double.infinity)
    func gap(_ distance: Double, shrink: Bool = false) -> Double {
      distance >= 0 ? distance / 2 : (shrink ? distance : 0)
    }
    for keep in keeps {
      let vertical = min(box.maxY, keep.maxY) - max(box.minY, keep.minY)
      let horizontal = min(box.maxX, keep.maxX) - max(box.minX, keep.minX)
      if vertical > 0 {
        if keep.midX < box.midX {
          room.left = min(room.left, gap(box.minX - keep.maxX, shrink: true))
        } else {
          room.right = min(room.right, gap(keep.minX - box.maxX, shrink: labelOnly))
        }
      } else if horizontal > 0 {
        if keep.midY < box.midY {
          room.top = min(room.top, gap(box.minY - keep.maxY, shrink: labelOnly))
        } else {
          room.bottom = min(room.bottom, gap(keep.minY - box.maxY, shrink: labelOnly))
        }
      } else if -vertical < 12 {
        // 대각선: 세로로 가까우면(여백 안) 가로 여백을 간격의 절반으로.
        if keep.midX < box.midX {
          room.left = min(room.left, (box.minX - keep.maxX) / 2)
        } else {
          room.right = min(room.right, (keep.minX - box.maxX) / 2)
        }
      }
    }
    return room
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
  static func flatten(original: URL, polygons: [[CGPoint]]) throws -> MaskedArtifact {
    let flattened = try render(ImageLoading.cgImage(original), polygons: polygons)
    let data = NSMutableData()
    guard
      let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { throw ProcessingFailure.invalidImage }
    CGImageDestinationAddImage(encoder, flattened, nil)
    guard CGImageDestinationFinalize(encoder) else { throw ProcessingFailure.invalidImage }
    return MaskedArtifact(pngData: try PNGChunks.stripAncillary(data as Data))
  }

  static func render(_ image: CGImage, polygons: [[CGPoint]]) throws -> CGImage {
    let width = image.width
    let height = image.height
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw ProcessingFailure.invalidImage }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.setShouldAntialias(false)
    for polygon in polygons {
      // CGContext는 왼쪽 아래 기준이다.
      ctx.addLines(between: polygon.map { CGPoint(x: $0.x * Double(width), y: (1 - $0.y) * Double(height)) })
      ctx.closePath()
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
