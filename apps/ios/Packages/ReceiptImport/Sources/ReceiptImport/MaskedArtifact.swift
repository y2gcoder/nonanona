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
  /// 고른 OCR 줄마다 가로 전체 띠. 글자 가장자리까지 덮도록 여백을 둔다. 픽셀 좌표, 왼쪽 위 기준.
  static func rects(for lines: [OCRLine], selected: Set<Int>, width: Int, height: Int) -> [CGRect] {
    lines.filter { selected.contains($0.id) }.map { line in
      let top = line.y * Double(height)
      let bottom = (line.y + line.height) * Double(height)
      let pad = max(8, (bottom - top) * 0.3)
      let y0 = max(0, floor(top - pad))
      let y1 = min(Double(height), ceil(bottom + pad))
      return CGRect(x: 0, y: y0, width: Double(width), height: y1 - y0)
    }
  }

  /// 확인한 경우에만 부른다. 새 비트맵에 검은 사각형을 굽고 원본 메타데이터 없이 PNG로 인코딩한다.
  static func flatten(original: URL, rects: [CGRect]) throws -> MaskedArtifact {
    let image = try ImageLoading.cgImage(original)
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
    for rect in rects {
      // CGContext는 왼쪽 아래 기준이다.
      ctx.fill(CGRect(x: rect.minX, y: Double(height) - rect.maxY, width: rect.width, height: rect.height))
    }
    guard let flattened = ctx.makeImage() else { throw ProcessingFailure.invalidImage }
    let data = NSMutableData()
    guard
      let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { throw ProcessingFailure.invalidImage }
    CGImageDestinationAddImage(encoder, flattened, nil)
    guard CGImageDestinationFinalize(encoder) else { throw ProcessingFailure.invalidImage }
    return MaskedArtifact(pngData: try PNGChunks.stripAncillary(data as Data))
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
