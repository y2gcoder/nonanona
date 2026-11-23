import Compression
import Foundation

/// 받은 가림 사본이 끝까지 온전한 PNG인지 본다. ImageIO는 잘린 PNG도 그림을 만들어 주므로(로그만 남긴다) 그 앞에서 따로 본다.
/// 서명, IHDR로 시작해 IEND로 끝나는 청크(길이가 범위 안이고 CRC가 맞음), IDAT를 이어 붙인 zlib 흐름이 끝까지 풀려
/// IHDR이 말하는 크기와 정확히 같은지(인터레이스가 아닐 때). Android `PngCheck`와 같은 규칙.
enum PNGCheck {
  static func isComplete(_ data: Data) -> Bool {
    let bytes = [UInt8](data)
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard bytes.count >= 8 + 25 + 12, Array(bytes[0..<8]) == signature else { return false }
    var offset = 8
    var first = true
    var ended = false
    var header: (width: Int, height: Int, depth: Int, color: Int, interlace: Int)?
    var idat: [UInt8] = []
    while offset < bytes.count {
      guard !ended, offset + 12 <= bytes.count else { return false }
      let length = Int(be32(bytes, offset))
      guard length <= 0x7FFF_FFFF, offset + 12 + length <= bytes.count else { return false }
      let type = Array(bytes[(offset + 4)..<(offset + 8)])
      let body = Array(bytes[(offset + 8)..<(offset + 8 + length)])
      guard crc32(type + body) == be32(bytes, offset + 8 + length) else { return false }
      let name = String(decoding: type, as: UTF8.self)
      if first {
        guard name == "IHDR", length == 13 else { return false }
        header = (
          Int(be32(body, 0)), Int(be32(body, 4)), Int(body[8]), Int(body[9]), Int(body[12])
        )
        first = false
      } else if name == "IDAT" {
        idat += body
      } else if name == "IEND" {
        ended = true
      }
      offset += 12 + length
    }
    guard ended, let header, header.width > 0, header.height > 0, !idat.isEmpty else { return false }
    let channels: [Int: Int] = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4]
    guard let perPixel = channels[header.color] else { return false }
    guard header.interlace == 0 else { return true }  // 인터레이스는 구조까지만 본다(앱이 만드는 사본은 아니다)
    let rowBytes = (header.width * perPixel * header.depth + 7) / 8
    let expected = header.height * (rowBytes + 1)
    return inflatedSize(idat, limit: expected + 1) == expected
  }

  /// zlib 흐름(2바이트 머리 + deflate + 4바이트 Adler)을 풀었을 때의 크기. 풀리지 않으면 nil.
  private static func inflatedSize(_ zlib: [UInt8], limit: Int) -> Int? {
    guard zlib.count > 6 else { return nil }
    let deflate = Array(zlib[2..<(zlib.count - 4)])
    var out = [UInt8](repeating: 0, count: limit)
    let written = out.withUnsafeMutableBufferPointer { dst in
      deflate.withUnsafeBufferPointer { src in
        compression_decode_buffer(dst.baseAddress!, limit, src.baseAddress!, deflate.count, nil, COMPRESSION_ZLIB)
      }
    }
    return written == 0 ? nil : written
  }

  private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
  }

  private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
  }

  static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFF_FFFF
  }
}
