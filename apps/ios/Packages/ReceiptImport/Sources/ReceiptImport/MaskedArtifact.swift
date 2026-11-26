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
      return [
        expanded(q[0], awayFrom: q[1], by: side, and: q[3], by: vertical),
        expanded(q[1], awayFrom: q[0], by: side, and: q[2], by: vertical),
        expanded(q[2], awayFrom: q[3], by: side, and: q[1], by: vertical),
        expanded(q[3], awayFrom: q[2], by: side, and: q[0], by: vertical),
      ]
    }
    let manual = rects(for: regions, width: ocr.pixelWidth, height: ocr.pixelHeight).map(corners)
    return (lines + manual).map { points in points.map { CGPoint(x: $0.x / width, y: $0.y / height) } }
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
