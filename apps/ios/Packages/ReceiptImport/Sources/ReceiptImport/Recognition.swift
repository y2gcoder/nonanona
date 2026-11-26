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
  /// Vision이 준 줄 신뢰도(0~1). 언어 선택(`OCRLanguageChoice`)에 쓴다. 옛 초안에는 없다.
  let confidence: Double?

  public init(
    id: Int, text: String, x: Double, y: Double, width: Double, height: Double, corners: [CGPoint]? = nil,
    sensitiveCorners: [CGPoint]? = nil, confidence: Double? = nil
  ) {
    self.id = id
    self.text = text
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.corners = corners
    self.sensitiveCorners = sensitiveCorners
    self.confidence = confidence
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
  /// 취소 신호를 읽기 사이(모델·타일)에 확인한다. 취소되면 `CancellationError`를 던진다.
  func recognize(_ url: URL, cancellation: OCRCancellation) throws -> OCRResult
}

extension ReceiptRecognizer {
  public func recognize(_ url: URL, cancellation: OCRCancellation) throws -> OCRResult {
    try cancellation.check()
    return try recognize(url)
  }
}

/// Swift 작업의 취소를 GCD 큐에서 도는 동기 OCR에 전하는 신호. 처리기가 작업 취소 처리기에서 `cancel()`을 부른다.
public final class OCRCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  public init() {}

  public static var none: OCRCancellation { OCRCancellation() }

  public var isCancelled: Bool { lock.withLock { cancelled } }

  public func cancel() { lock.withLock { cancelled = true } }

  public func check() throws {
    if isCancelled { throw CancellationError() }
  }
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

/// Apple Vision 다국어 OCR. 기기 안에서만 동작한다(native-batch-import 실험에서 옮김). 사진마다 일본어·영어 우선 읽기와
/// 한국어를 포함한 자동 감지 읽기를 하고 `OCRLanguageChoice`로 고른다(ADR-0013).
public struct VisionReceiptRecognizer: ReceiptRecognizer {
  public init() {}

  public func recognize(_ url: URL) throws -> OCRResult {
    try recognize(url, cancellation: .none)
  }

  public func recognize(_ url: URL, cancellation: OCRCancellation) throws -> OCRResult {
    try cancellation.check()
    return try recognize(ImageLoading.cgImage(url), cancellation: cancellation)
  }

  func recognize(_ image: CGImage, cancellation: OCRCancellation = .none) throws -> OCRResult {
    // 일본어 우선 읽기와 한국어를 포함한 자동 감지 읽기를 모두 하고 같은 규칙으로 고른다(ADR-0013, Android와 같다).
    let lines = try OCRLanguageChoice.choose(
      japanese: { try read(image, detectLanguage: false, cancellation: cancellation) },
      korean: { try read(image, detectLanguage: true, cancellation: cancellation) },
      cancellation: cancellation)
    return OCRResult(pixelWidth: image.width, pixelHeight: image.height, lines: lines)
  }

  /// 한 언어 설정으로 사진 전체를 읽는다. 긴 사진은 겹치는 타일로 나눠 읽고 합친다. 타일마다 읽기 전에 취소를 확인한다.
  func read(_ image: CGImage, detectLanguage: Bool, cancellation: OCRCancellation = .none) throws -> [OCRLine] {
    let width = image.width
    let height = image.height
    let tileHeight = height > width * 5 / 2 ? width * 2 : height
    let overlap = tileHeight < height ? max(1, width / 4) : 0
    var tiles: [OCRTile] = []
    var top = 0
    while top < height {
      let bottom = min(height, top + tileHeight)
      let tileBounds = CGRect(x: 0, y: top, width: width, height: bottom - top)
      try cancellation.check()
      guard let tile = top == 0 && bottom == height ? image : image.cropping(to: tileBounds)
      else { throw ProcessingFailure.recognitionError }
      var lines: [OCRLine] = []
      for observation in try observations(in: tile, detectLanguage: detectLanguage) {
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
            sensitiveCorners: sensitiveCorners, confidence: Double(candidate.confidence)))
      }
      tiles.append(OCRTile(top: top, height: tile.height, lines: lines))
      if bottom == height { break }
      top = bottom - overlap
    }
    return OCRTile.merge(tiles, imageHeight: height).enumerated().map { id, line in
      OCRLine(
        id: id, text: line.text, x: line.x, y: line.y, width: line.width, height: line.height, corners: line.corners,
        sensitiveCorners: line.sensitiveCorners, confidence: line.confidence)
    }
  }

  private func observations(in image: CGImage, detectLanguage: Bool) throws -> [VNRecognizedTextObservation] {
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
}

extension OCRLine {
  fileprivate var scored: OCRLanguageChoice.Line { .init(text: text, confidence: confidence ?? 0) }
}

/// 사진마다 일본어 우선 읽기와 한국어 포함 읽기 중 무엇을 쓸지 정하는 규칙(ADR-0013). Android `OcrLanguageChoice`와 같은
/// 규칙이고, 두 앱의 시험이 같은 표(`apps/fixtures/korean/language-choice.json`)를 읽는다.
///
/// 결과마다 점수 = 줄마다 (공백을 뺀 유니코드 코드 포인트 수 × 엔진 신뢰도)의 합. 공백은 유니코드 White_Space 25자로 고정한다
/// (두 앱의 공백 판정 API 범위가 달라 직접 정한다). 한국어 결과의 한글 줄이 `minHangulLines` 이상이고
/// 점수가 일본어 결과보다 높을 때만 한국어 결과를 쓴다. 같으면 일본어(기존 동작)다.
enum OCRLanguageChoice {
  static let minHangulLines = 2

  /// 유니코드 White_Space 속성(Unicode 15) 25자. Android와 같은 목록이다.
  static let whitespace: Set<UInt32> = Set(
    Array(0x09...0x0D) + [0x20, 0x85, 0xA0, 0x1680] + Array(0x2000...0x200A) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000])

  struct Line: Equatable, Sendable {
    let text: String
    let confidence: Double
  }

  static func hangulLines(_ lines: [Line]) -> Int {
    lines.count { $0.text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
  }

  /// 공백을 뺀 코드 포인트(유니코드 스칼라) 수. 보충 평면 한자 `𠮷`는 1자.
  static func characters(_ text: String) -> Int {
    text.unicodeScalars.count { !whitespace.contains($0.value) }
  }

  static func score(_ lines: [Line]) -> Double {
    lines.reduce(0) { sum, line in
      sum + Double(characters(line.text)) * min(max(line.confidence, 0), 1)
    }
  }

  static func prefersKorean(japanese: [Line], korean: [Line]) -> Bool {
    hangulLines(korean) >= minHangulLines && score(korean) > score(japanese)
  }

  /// 두 읽기를 하고 하나를 고른다. 각 읽기의 실패는 따로 처리한다: 한쪽만 성공하면 그 결과, 둘 다 성공하면 `prefersKorean`,
  /// 둘 다 실패하면 일본어 쪽 실패(`ProcessingFailure`가 아니면 `recognitionError`)를 던진다. 취소는 다른 읽기로 넘어가지 않고
  /// 그대로 던진다. 한 읽기가 끝나면 다음 읽기 전에 취소를 확인한다.
  static func choose(
    japanese: () throws -> [OCRLine], korean: () throws -> [OCRLine], cancellation: OCRCancellation
  ) throws -> [OCRLine] {
    func attempt(_ read: () throws -> [OCRLine]) throws -> Result<[OCRLine], any Error> {
      do {
        return .success(try read())
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        return .failure(error)
      }
    }
    let first = try attempt(japanese)
    try cancellation.check()
    let second = try attempt(korean)
    switch (first, second) {
    case (.success(let j), .success(let k)):
      return prefersKorean(japanese: j.map(\.scored), korean: k.map(\.scored)) ? k : j
    case (.success(let j), .failure):
      return j
    case (.failure, .success(let k)):
      return k
    case (.failure(let error), .failure):
      throw (error as? ProcessingFailure) ?? ProcessingFailure.recognitionError
    }
  }
}

/// OCR 줄에서 날짜·합계·통화·가게와 가림 후보를 고른다. 읽지 못하면 이유를 `ProcessingFailure`로 알린다.
/// 합계 낱말·통화·날짜 규칙은 Android `ProposalBuilder`와 같고, 두 앱의 시험이 같은 표
/// (`apps/fixtures/korean/proposal-fields.json`)를 읽는다(ADR-0013).
enum ProposalBuilder {
  // 품목 추출에서 쓰던 제외 패턴은 그대로 유지한다.
  static let sensitivePattern =
    #"TEL|電話|カード|card|会員|承認|予約\s*(?:番号|ID|コード|No)|reservation|booking|PIN|\d{2,4}-\d{2,4}-\d{3,4}"#
  static let datePattern = #"(\d{4})\s*[-/.年년]\s*(\d{1,2})\s*[-/.月월]\s*(\d{1,2})"#
  /// 한국어 결제 화면의 "총 결제 금액"·"결제금액"과 영수증의 "합계"를 포함한다.
  static let totalKeyword = #"合計|お会計|支払額|決済金額|total|합계|결제\s*금액|총\s*금액"#
  static let subtotalKeyword = "小計|소계"

  static func make(_ ocr: OCRResult) throws(ProcessingFailure) -> OCRProposal {
    guard !ocr.lines.isEmpty else { throw .unreadable }
    guard let total = total(ocr.lines) else { throw .missingTotal }
    guard let date = date(ocr.lines) else { throw .missingDate }
    let merchant = ocr.lines.first?.text.trimmingCharacters(in: .whitespaces)
    let masks = SensitiveLines(ocr)
    let currency = currency(totalText: total.text, allTexts: ocr.lines.map(\.text))
    return OCRProposal(
      ocr: ocr,
      fields: AllowedReceiptFields(date: date, amountMinor: total.amount, currency: currency, merchant: merchant),
      suggestedMaskLineIDs: masks.ids.sorted(), needsMaskReview: masks.unmatchedLabel || masks.isTilted)
  }

  /// 결제일 라벨(결제일·결제일시·결제 일자, 라벨 끝을 확인해 `결제 일정`은 아니다). 숙소 화면의 체크인처럼 앞에 나오는 다른 날짜보다 우선한다.
  static let paymentDateLabel = #"결제\s*(?:일시|일자|일)(?![가-힣])"#

  /// 지출 날짜: 결제일 라벨 줄의 날짜, 없으면 그 줄과 같은 행 오른쪽 상자의 날짜(가까운 순), 결제일 라벨이 없거나 날짜를 못 찾으면
  /// 위에서부터 첫 날짜.
  static func date(_ lines: [OCRLine]) -> String? {
    for line in lines where matches(paymentDateLabel, line.text) {
      if let date = isoDate(line.text) { return date }
      let row = lines.filter {
        $0.id != line.id && abs(($0.y + $0.height / 2) - (line.y + line.height / 2)) < line.height / 2
          && $0.x > line.x
      }.sorted { $0.x < $1.x }
      if let date = row.lazy.compactMap({ isoDate($0.text) }).first { return date }
    }
    return lines.lazy.compactMap { isoDate($0.text) }.first
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

  /// 합계 금액과 그 금액을 읽은 글자(통화 판정용).
  struct Total: Equatable {
    let amount: Int
    let text: String
  }

  static func total(_ lines: [OCRLine]) -> Total? {
    let candidates = lines.filter { matches(totalKeyword, $0.text) && !matches(subtotalKeyword, $0.text) }
    for line in candidates {
      if let value = number(after: totalKeyword, in: line.text) { return Total(amount: value, text: line.text) }
      // OCR이 "合計"와 금액을 같은 행의 두 상자로 나눈 경우.
      let row = lines.filter {
        $0.id != line.id && abs(($0.y + $0.height / 2) - (line.y + line.height / 2)) < line.height / 2
          && $0.x > line.x
      }
      if let found = row.lazy.compactMap({ other in
        number(after: "", in: other.text).map { Total(amount: $0, text: other.text) }
      })
      .first {
        return found
      }
    }
    return nil
  }

  /// 원·円은 숫자 뒤 금액 접미사, ₩·¥는 숫자 앞, 통화 코드는 앞이 영숫자가 아니거나(뒤에 금액 가능) 독립된 금액 토큰 바로 뒤의 토큰, W는 숫자
  /// 바로 앞(₩ 오독)만 센다. 회원번호의 '원', 상품 코드 A1KRW2·A1KRW는 아니다.
  static let krwMark =
    #"(?<=\d)\s*원|₩\s*\d|(?<![A-Za-z0-9])KRW(?![A-Za-z])|(?<![A-Za-z0-9.,])\d[\d,.]*\s*KRW(?![A-Za-z0-9])|(?<![A-Za-z])W(?=\s*\d)"#
  static let jpyMark =
    #"(?<=\d)\s*円|[¥￥]\s*\d|(?<![A-Za-z0-9])JPY(?![A-Za-z])|(?<![A-Za-z0-9.,])\d[\d,.]*\s*JPY(?![A-Za-z0-9])"#

  /// 합계 통화. 합계를 읽은 글자의 표시(금액에 붙은 円·¥, JPY / 원·₩, KRW, OCR이 ₩를 W로 읽는 경우 포함)를 먼저 본다. 둘 다 있거나 없으면
  /// 사진 전체에서 표시가 붙은 줄이 더 많은 쪽, 그래도 같으면 한글 줄이 2줄 이상이면 KRW, 아니면 JPY(기존 동작)다.
  static func currency(totalText: String, allTexts: [String]) -> String {
    func has(_ pattern: String, _ text: String) -> Bool {
      text.range(of: pattern, options: .regularExpression) != nil
    }
    let krw = has(krwMark, totalText)
    let jpy = has(jpyMark, totalText)
    if krw != jpy { return krw ? "KRW" : "JPY" }
    let krwLines = allTexts.count { has(krwMark, $0) }
    let jpyLines = allTexts.count { has(jpyMark, $0) }
    if krwLines != jpyLines { return krwLines > jpyLines ? "KRW" : "JPY" }
    let hangulLines = allTexts.count { $0.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
    return hangulLines >= 2 ? "KRW" : "JPY"
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
