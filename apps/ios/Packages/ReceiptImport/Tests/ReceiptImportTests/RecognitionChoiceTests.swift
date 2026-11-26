import CoreGraphics
import Foundation
import Testing

@testable import ReceiptImport

/// 두 읽기의 실패를 따로 처리하는지(ADR-0013). Android `RecognitionChoiceTest`와 같은 사례다.
struct RecognitionChoiceTests {
  private static func lines(_ texts: [String]) -> [OCRLine] {
    texts.enumerated().map { id, text in
      OCRLine(id: id, text: text, x: 0.1, y: Double(id) * 0.05, width: 0.5, height: 0.03, confidence: 1)
    }
  }

  private let japanese = lines(["合計 1,408円", "カード番号"])
  private let korean = lines(["합계 6,900원", "카드번호 4521", "승인번호 52906634"])

  @Test func japaneseFailureFallsBackToKorean() throws {
    let chosen = try OCRLanguageChoice.choose(
      japanese: { throw ProcessingFailure.recognitionError }, korean: { korean }, cancellation: .none)
    #expect(chosen == korean)
  }

  @Test func koreanFailureFallsBackToJapanese() throws {
    let chosen = try OCRLanguageChoice.choose(
      japanese: { japanese }, korean: { throw NSError(domain: "vision", code: 1) }, cancellation: .none)
    #expect(chosen == japanese)
  }

  @Test func tileFailureFailsOnlyThatReading() throws {
    // 긴 사진의 두 번째 타일에서 실패한 읽기: 그 읽기 전체가 실패하고 다른 읽기를 쓴다.
    var tiles = 0
    let chosen = try OCRLanguageChoice.choose(
      japanese: { japanese },
      korean: {
        for tile in 1...3 {
          tiles = tile
          if tile == 2 { throw ProcessingFailure.recognitionError }
        }
        return korean
      }, cancellation: .none)
    #expect(chosen == japanese)
    #expect(tiles == 2)
  }

  @Test func bothSucceedUsesScore() throws {
    let chosen = try OCRLanguageChoice.choose(japanese: { japanese }, korean: { korean }, cancellation: .none)
    #expect(chosen == korean)
  }

  @Test func bothFailThrowsJapaneseFailure() {
    #expect(throws: ProcessingFailure.invalidImage) {
      try OCRLanguageChoice.choose(
        japanese: { throw ProcessingFailure.invalidImage }, korean: { throw ProcessingFailure.recognitionError },
        cancellation: .none)
    }
    #expect(throws: ProcessingFailure.recognitionError) {
      try OCRLanguageChoice.choose(
        japanese: { throw NSError(domain: "vision", code: 1) }, korean: { throw NSError(domain: "vision", code: 2) },
        cancellation: .none)
    }
  }

  @Test func cancellationIsNotAFallback() {
    var koreanCalls = 0
    #expect(throws: CancellationError.self) {
      try OCRLanguageChoice.choose(
        japanese: { throw CancellationError() },
        korean: {
          koreanCalls += 1
          return korean
        }, cancellation: .none)
    }
    let cancellation = OCRCancellation()
    #expect(throws: CancellationError.self) {
      try OCRLanguageChoice.choose(
        japanese: {
          cancellation.cancel()
          return japanese
        },
        korean: {
          koreanCalls += 1
          return korean
        }, cancellation: cancellation)
    }
    #expect(koreanCalls == 0)
  }

  /// 실제 Vision: 취소된 신호로는 첫 타일도 읽지 않는다.
  @Test func cancelledVisionReadStopsBeforeTiles() throws {
    let cancellation = OCRCancellation()
    cancellation.cancel()
    let image = try #require(
      CGContext(
        data: nil, width: 100, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
    #expect(throws: CancellationError.self) {
      try VisionReceiptRecognizer().read(image, detectLanguage: false, cancellation: cancellation)
    }
  }
}
