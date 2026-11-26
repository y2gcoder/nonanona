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
  /// Vision이 읽은 글자 영역의 네 모서리. 옛 초안에는 없다.
  let corners: [CGPoint]?
  /// 가격이나 날짜와 한 상자로 읽힌 번호의 글자 범위.
  let sensitiveCorners: [CGPoint]?

  public init(
    id: Int, text: String, x: Double, y: Double, width: Double, height: Double, corners: [CGPoint]? = nil,
    sensitiveCorners: [CGPoint]? = nil
  ) {
    self.id = id
    self.text = text
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.corners = corners
    self.sensitiveCorners = sensitiveCorners
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
  /// 옛 초안에는 재확인 결과가 없으므로 검토 화면에서 확인을 안내한다.
  public internal(set) var needsMaskReview: Bool? = nil

  /// 가림 표시와 PNG 굽기가 공유하는 왼쪽 위 기준 0~1 좌표.
  public func maskPolygons(lineIDs: Set<Int>, regions: [MaskRegion]) -> [[CGPoint]] {
    Masking.polygons(ocr: ocr, selected: lineIDs, automatic: Set(suggestedMaskLineIDs), regions: regions)
  }
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

/// Apple Vision 다국어 OCR. 기기 안에서만 동작한다(native-batch-import 실험에서 옮김).
public struct VisionReceiptRecognizer: ReceiptRecognizer {
  public init() {}

  public func recognize(_ url: URL) throws -> OCRResult {
    try recognize(ImageLoading.cgImage(url))
  }

  func recognize(_ image: CGImage) throws -> OCRResult {
    let width = image.width
    let height = image.height
    let tileHeight = height > width * 5 / 2 ? width * 2 : height
    let overlap = tileHeight < height ? max(1, width / 4) : 0
    var tiles: [OCRTile] = []
    var top = 0
    while top < height {
      let bottom = min(height, top + tileHeight)
      let tileBounds = CGRect(x: 0, y: top, width: width, height: bottom - top)
      guard let tile = top == 0 && bottom == height ? image : image.cropping(to: tileBounds)
      else { throw ProcessingFailure.recognitionError }
      var lines: [OCRLine] = []
      for observation in try observations(in: tile) {
        guard let candidate = observation.topCandidates(1).first else { continue }
        let b = observation.boundingBox
        func corners(_ rectangle: VNRectangleObservation) -> [CGPoint] {
          [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
            .map { CGPoint(x: $0.x, y: 1 - $0.y) }
        }
        let text = candidate.string
        let matches = SensitiveText(text)
        var sensitiveCorners: [CGPoint]?
        if matches.isMixed, let range = matches.maskRange.flatMap({ SensitiveText.originalRange($0, in: text) }),
          let box = try? candidate.boundingBox(for: range), box.boundingBox.width < b.width * 0.94
        {
          sensitiveCorners = corners(box)
        }
        lines.append(
          OCRLine(
            id: 0, text: text, x: b.minX, y: 1 - b.maxY, width: b.width,
            height: b.height, corners: corners(observation),
            sensitiveCorners: sensitiveCorners))
      }
      tiles.append(OCRTile(top: top, height: tile.height, lines: lines))
      if bottom == height { break }
      top = bottom - overlap
    }
    let sorted = OCRTile.merge(tiles, imageHeight: height).enumerated().map { id, line in
      OCRLine(
        id: id, text: line.text, x: line.x, y: line.y, width: line.width, height: line.height, corners: line.corners,
        sensitiveCorners: line.sensitiveCorners)
    }
    return OCRResult(pixelWidth: width, pixelHeight: height, lines: sorted)
  }

  private func observations(in image: CGImage) throws -> [VNRecognizedTextObservation] {
    func read(detectLanguage: Bool) throws -> [VNRecognizedTextObservation] {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.automaticallyDetectsLanguage = detectLanguage
      let supported = (try? request.supportedRecognitionLanguages()) ?? []
      let languages = detectLanguage ? ["ja-JP", "en-US", "ko-KR"] : ["ja-JP", "en-US"]
      request.recognitionLanguages = languages.filter { supported.contains($0) }
      do {
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
      } catch {
        throw ProcessingFailure.recognitionError
      }
      return request.results ?? []
    }

    func countLines(_ rows: [VNRecognizedTextObservation], containing script: ClosedRange<UInt32>) -> Int {
      rows.count {
        $0.topCandidates(1).first?.string.unicodeScalars.contains { script.contains($0.value) } == true
      }
    }

    let primary = try read(detectLanguage: false)
    // 일본어 품목 판독의 결과를 유지하면서 가나를 거의 읽지 못한 결제 화면은 한글도 확인한다.
    if countLines(primary, containing: 0x3040...0x30ff) < 2,
      let alternate = try? read(detectLanguage: true), countLines(alternate, containing: 0xac00...0xd7a3) >= 2
    {
      return alternate
    }
    return primary
  }
}

/// OCR 줄에서 날짜·합계·가게와 가림 후보를 고른다. 읽지 못하면 이유를 `ProcessingFailure`로 알린다.
enum ProposalBuilder {
  // 품목 추출에서 쓰던 제외 패턴은 그대로 유지한다.
  static let sensitivePattern =
    #"TEL|電話|カード|card|会員|承認|予約\s*(?:番号|ID|コード|No)|reservation|booking|PIN|\d{2,4}-\d{2,4}-\d{3,4}"#
  static let datePattern = #"(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})"#
  static let totalKeyword = #"合計|お会計|支払額|決済金額|total"#

  static func make(_ ocr: OCRResult) throws(ProcessingFailure) -> OCRProposal {
    guard !ocr.lines.isEmpty else { throw .unreadable }
    guard let amount = total(ocr.lines) else { throw .missingTotal }
    guard let date = ocr.lines.lazy.compactMap({ isoDate($0.text) }).first else { throw .missingDate }
    let merchant = ocr.lines.first?.text.trimmingCharacters(in: .whitespaces)
    let masks = SensitiveLines(ocr)
    return OCRProposal(
      ocr: ocr,
      fields: AllowedReceiptFields(date: date, amountMinor: amount, currency: "JPY", merchant: merchant),
      suggestedMaskLineIDs: masks.ids.sorted(), needsMaskReview: masks.unmatchedLabel || masks.isTilted)
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
