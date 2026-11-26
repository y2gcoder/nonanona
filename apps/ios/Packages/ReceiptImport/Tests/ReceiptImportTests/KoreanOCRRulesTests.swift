import Foundation
import Testing

@testable import ReceiptImport

/// Android `KoreanOcrRulesTest`와 같은 표(apps/fixtures/korean)를 읽는다. ADR-0013.
struct KoreanOCRRulesTests {
  private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "fixtures/korean")

  private struct ScoredLine: Decodable {
    let text: String
    let confidence: Double
  }

  private struct ChoiceCase: Decodable {
    let id: String
    let japanese: [ScoredLine]
    let korean: [ScoredLine]
    let expect: String
  }

  private struct ChoiceTable: Decodable {
    let version: Int
    let cases: [ChoiceCase]
  }

  private struct FieldLine: Decodable {
    let text: String
    let box: [Double]
  }

  private struct FieldExpect: Decodable {
    let amount: Int?
    let currency: String?
    let date: String?
    let failure: String?
  }

  private struct FieldCase: Decodable {
    let id: String
    let lines: [FieldLine]
    let expect: FieldExpect
  }

  private struct FieldTable: Decodable {
    let version: Int
    let size: [Double]
    let cases: [FieldCase]
  }

  @Test func languageChoiceMatchesSharedTable() throws {
    let table = try JSONDecoder().decode(
      ChoiceTable.self, from: Data(contentsOf: Self.fixtures.appending(path: "language-choice.json")))
    #expect(table.version == 1)
    let wrong = table.cases.filter { entry in
      func lines(_ rows: [ScoredLine]) -> [OCRLanguageChoice.Line] {
        rows.map { .init(text: $0.text, confidence: $0.confidence) }
      }
      let korean = OCRLanguageChoice.prefersKorean(japanese: lines(entry.japanese), korean: lines(entry.korean))
      return (korean ? "korean" : "japanese") != entry.expect
    }.map(\.id)
    #expect(wrong.isEmpty, "\(wrong)")
  }

  @Test func proposalFieldsMatchSharedTable() throws {
    let table = try JSONDecoder().decode(
      FieldTable.self, from: Data(contentsOf: Self.fixtures.appending(path: "proposal-fields.json")))
    #expect(table.version == 1)
    let width = table.size[0]
    let height = table.size[1]
    var wrong: [String] = []
    for entry in table.cases {
      let lines = entry.lines.enumerated().map { id, line in
        OCRLine(
          id: id, text: line.text, x: line.box[0] / width, y: line.box[1] / height,
          width: (line.box[2] - line.box[0]) / width, height: (line.box[3] - line.box[1]) / height)
      }
      let ocr = OCRResult(pixelWidth: Int(width), pixelHeight: Int(height), lines: lines)
      let actual: String
      do {
        let fields = try ProposalBuilder.make(ocr).fields
        actual = "\(fields.amountMinor) \(fields.currency) \(fields.date)"
      } catch {
        actual = error.rawValue
      }
      let expected =
        entry.expect.failure
        ?? "\(entry.expect.amount ?? -1) \(entry.expect.currency ?? "") \(entry.expect.date ?? "")"
      if actual != expected { wrong.append("\(entry.id): expected \(expected), got \(actual)") }
    }
    #expect(wrong.isEmpty, "\(wrong)")
  }

  /// 실제 Vision: 한국어 결제 화면(일본어 줄 2줄 포함)은 한국어 포함 읽기를 고르고, 합계·날짜와 번호 가림 후보를 얻는다.
  @Test func visionReadsKoreanScreenWithJapaneseLines() throws {
    let input = Self.fixtures.appending(path: "input-k04.png")
    let ocr = try VisionReceiptRecognizer().recognize(input)
    #expect(OCRLanguageChoice.hangulLines(ocr.lines.map { .init(text: $0.text, confidence: 1) }) >= 2)
    let proposal = try ProposalBuilder.make(ocr)
    #expect(proposal.fields.amountMinor == 2_480)
    // 통화는 단언하지 않는다: 한국어 포함 읽기가 ¥를 ·로 읽어 KRW가 제안된다(ADR-0013 측정, 검토 화면에서 고친다).
    #expect(proposal.fields.date == "2026-11-06")
    let masked = Set(proposal.suggestedMaskLineIDs)
    let approval = try #require(ocr.lines.first { $0.text.contains("87120456") })
    #expect(masked.contains(approval.id))
  }

  /// 실제 Vision: 일본어 영수증은 예전처럼 일본어 우선 읽기 결과를 쓴다.
  @Test func visionKeepsJapaneseReceipt() throws {
    let input = Self.fixtures.deletingLastPathComponent().appending(path: "receipts/receipt-r01.png")
    let ocr = try VisionReceiptRecognizer().recognize(input)
    #expect(OCRLanguageChoice.hangulLines(ocr.lines.map { .init(text: $0.text, confidence: 1) }) == 0)
    let proposal = try ProposalBuilder.make(ocr)
    #expect(proposal.fields.amountMinor == 1_408)
    #expect(proposal.fields.currency == "JPY")
  }
}
