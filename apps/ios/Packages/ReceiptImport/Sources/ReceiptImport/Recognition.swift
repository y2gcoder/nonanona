import CoreGraphics
import Foundation
import ImageIO
import Vision

/// OCR 한 줄. 좌표는 0~1로 정규화한 왼쪽 위 기준이다.
public struct OCRLine: Codable, Equatable, Sendable {
  public let id: Int
  public let text: String
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(id: Int, text: String, x: Double, y: Double, width: Double, height: Double) {
    self.id = id
    self.text = text
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct OCRResult: Codable, Equatable, Sendable {
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let lines: [OCRLine]

  public init(pixelWidth: Int, pixelHeight: Int, lines: [OCRLine]) {
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.lines = lines
  }
}

/// 기기 안에서만 쓰는 사진 분석 결과. OCR 전문을 담으므로 기기 밖으로 나가는 타입이 아니다.
public struct OCRProposal: Codable, Equatable, Sendable {
  public let ocr: OCRResult
  public let fields: AllowedReceiptFields
  public let suggestedMaskLineIDs: [Int]
}

/// 사진 한 장을 읽는다. 처리기의 작업 스레드에서 동기로 부른다.
public protocol ReceiptRecognizer: Sendable {
  func recognize(_ url: URL) throws -> OCRResult
}

enum ImageLoading {
  /// OCR과 가림 굽기가 같은 디코딩(방향 적용, 긴 변 3000px 이하)을 써서 OCR 좌표가 픽셀과 맞게 한다.
  static func cgImage(_ url: URL) throws -> CGImage {
    let options =
      [
        kCGImageSourceThumbnailMaxPixelSize: 3_000,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    else { throw ProcessingFailure.invalidImage }
    return image
  }
}

/// Apple Vision 일본어 OCR. 기기 안에서만 동작한다(native-batch-import 실험에서 옮김).
public struct VisionReceiptRecognizer: ReceiptRecognizer {
  public init() {}

  public func recognize(_ url: URL) throws -> OCRResult {
    let image = try ImageLoading.cgImage(url)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    let supported = (try? request.supportedRecognitionLanguages()) ?? []
    request.recognitionLanguages = ["ja-JP", "en-US"].filter { supported.contains($0) }
    do {
      try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
    } catch {
      throw ProcessingFailure.recognitionError
    }
    let raw = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
      guard let text = observation.topCandidates(1).first?.string else { return nil }
      let b = observation.boundingBox
      return (text, CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
    }.sorted { $0.1.minY < $1.1.minY }
    let lines = raw.enumerated().map { index, entry in
      OCRLine(
        id: index, text: entry.0, x: entry.1.minX, y: entry.1.minY, width: entry.1.width, height: entry.1.height)
    }
    return OCRResult(pixelWidth: image.width, pixelHeight: image.height, lines: lines)
  }
}

/// OCR 줄에서 날짜·합계·가게와 가림 후보를 고른다. 읽지 못하면 이유를 `ProcessingFailure`로 알린다.
enum ProposalBuilder {
  static let sensitivePattern =
    #"TEL|電話|カード|card|会員|承認|予約\s*(?:番号|ID|コード|No)|reservation|booking|PIN|\d{2,4}-\d{2,4}-\d{3,4}"#
  static let datePattern = #"(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})"#
  static let totalKeyword = #"合計|お会計|支払額|決済金額|total"#

  static func make(_ ocr: OCRResult) throws(ProcessingFailure) -> OCRProposal {
    guard !ocr.lines.isEmpty else { throw .unreadable }
    guard let amount = total(ocr.lines) else { throw .missingTotal }
    guard let date = ocr.lines.lazy.compactMap({ isoDate($0.text) }).first else { throw .missingDate }
    let merchant = ocr.lines.first?.text.trimmingCharacters(in: .whitespaces)
    let masks = ocr.lines.filter { matches(sensitivePattern, $0.text) }.map(\.id)
    return OCRProposal(
      ocr: ocr,
      fields: AllowedReceiptFields(date: date, amountMinor: amount, currency: "JPY", merchant: merchant),
      suggestedMaskLineIDs: masks)
  }

  static func isoDate(_ raw: String) -> String? {
    // 실제 OCR 잡음(ML Kit에서 관찰): "2026-1 1-07" → 숫자 사이 공백을 붙인다.
    let text = raw.replacingOccurrences(of: #"(?<=\d)\s+(?=\d)"#, with: "", options: .regularExpression)
    guard let regex = try? NSRegularExpression(pattern: datePattern),
      let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    let parts = (1...3).compactMap { Range(m.range(at: $0), in: text).flatMap { Int(text[$0]) } }
    guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
    return String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2])
  }

  static func total(_ lines: [OCRLine]) -> Int? {
    let candidates = lines.filter { matches(totalKeyword, $0.text) && !matches("小計", $0.text) }
    for line in candidates {
      if let value = number(after: totalKeyword, in: line.text) { return value }
      // OCR이 "合計"와 금액을 같은 행의 두 상자로 나눈 경우.
      let row = lines.filter {
        $0.id != line.id && abs(($0.y + $0.height / 2) - (line.y + line.height / 2)) < line.height / 2
          && $0.x > line.x
      }
      if let value = row.lazy.compactMap({ number(after: "", in: $0.text) }).first { return value }
    }
    return nil
  }

  static func number(after keyword: String, in text: String) -> Int? {
    let pattern = (keyword.isEmpty ? "" : "(?:\(keyword))") + #"\D*?([0-9][0-9,，.]*)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
      let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let r = Range(m.range(at: 1), in: text)
    else { return nil }
    return Int(String(text[r].filter { $0.isASCII && $0.isNumber }))
  }

  static func matches(_ pattern: String, _ text: String) -> Bool {
    text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }
}
