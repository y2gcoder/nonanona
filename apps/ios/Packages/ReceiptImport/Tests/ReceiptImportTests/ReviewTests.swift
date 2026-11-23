import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ReceiptImport

private let fixtures = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "fixtures/receipts")

private func fixture(_ name: String) throws -> IncomingPhoto {
  IncomingPhoto(fileExtension: "png", content: .data(try Data(contentsOf: fixtures.appending(path: name))))
}

private func tempRoot() -> URL {
  FileManager.default.temporaryDirectory.appending(path: "review-\(UUID().uuidString)")
}

/// 이 파일의 테스트는 실제 Vision OCR(macOS)로 r01(읽힘)과 r10(초점 나감, 읽지 못함)을 쓴다.
private func processed(_ names: [String]) async throws -> (ReceiptDraftStore, ReceiptDraft, ReceiptProcessor) {
  let store = ReceiptDraftStore(root: tempRoot())
  let draft = try store.create(source: .share, photos: names.map(fixture))
  let processor = try ReceiptProcessor(store: store, draft: draft, recognizer: VisionReceiptRecognizer())
  await processor.run()
  return (store, draft, processor)
}

private func item(_ manifest: ProcessingManifest, _ state: ProcessingItem.State, _ position: Int? = nil)
  -> ProcessingItem
{
  manifest.items.first { $0.state == state && (position == nil || $0.position == position) }!
}

struct ReviewFormTests {
  @Test func acceptsOnlyServerCompatibleFields() throws {
    #expect(
      try ReviewForm.validate(date: "2026-11-03", amount: "1,408", currency: "JPY", merchant: " さくら食堂 ").get()
        == AllowedReceiptFields(date: "2026-11-03", amountMinor: 1408, currency: "JPY", merchant: "さくら食堂"))
    #expect(
      try ReviewForm.validate(date: "2026-11-03", amount: "12.5", currency: "USD", merchant: "").get()
        == AllowedReceiptFields(date: "2026-11-03", amountMinor: 1250, currency: "USD", merchant: nil))
    func problems(_ d: String, _ a: String, _ c: String, _ m: String = "") -> Set<FieldProblem> {
      guard case .failure(let p) = ReviewForm.validate(date: d, amount: a, currency: c, merchant: m) else { return [] }
      return p.fields
    }
    #expect(problems("2026-02-30", "100", "JPY") == [.date])
    #expect(problems("2026/11/03", "100", "JPY") == [.date])
    #expect(problems("2026-11-03", "0", "JPY") == [.amount])
    #expect(problems("2026-11-03", "1.5", "JPY") == [.amount], "엔은 소수가 없다")
    #expect(problems("2026-11-03", "100000000", "JPY") == [.amount])
    #expect(problems("2026-11-03", "100", "XYZ") == [.currency])
    #expect(problems("2026-11-03", "100", "JPY", "a\tb") == [.merchant])
    #expect(problems("2026-11-03", "100", "JPY", String(repeating: "가", count: 81)) == [.merchant])
    #expect(ReviewForm.amountText(minor: 1250, currency: "USD") == "12.50")
    #expect(ReviewForm.amountText(minor: 1408, currency: "JPY") == "1408")
  }

  @Test func maskRegionStaysInsidePhoto() {
    let region = MaskRegion(id: "a")
    #expect(region.topPercent == 47 && region.heightPercent == 6)
    #expect(region.moved(by: -100).topPercent == 0)
    #expect(region.moved(by: 100).topPercent == 94)
    #expect(region.resized(by: -10).heightPercent == MaskRegion.minHeight)
    let low = MaskRegion(id: "b", topPercent: 94, heightPercent: 6).resized(by: 3)
    #expect(low.topPercent == 91 && low.bottomPercent == 100)
    // 정수 퍼센트 → 픽셀: 위는 내림, 아래는 올림. 746px 사진의 79–85%는 589–635px.
    let rect = Masking.rects(for: [MaskRegion(id: "c", topPercent: 79, heightPercent: 6)], width: 720, height: 746)[0]
    #expect(rect == CGRect(x: 0, y: 589, width: 720, height: 46))
  }

  /// 목록 순서대로 다음 ready, 없으면 앞쪽, 그래도 없으면 nil. 읽는 중·실패·확인한 사진은 건너뛰지 않고 고르지 않는다.
  @Test func nextToReviewFollowsStableOrder() {
    func m(_ states: [ProcessingItem.State]) -> ProcessingManifest {
      ProcessingManifest(
        draftID: "d",
        items: states.enumerated().map {
          ProcessingItem(
            id: "p\($0.offset + 1)", position: $0.offset + 1, photoFileName: "", state: $0.element, attempts: 1,
            failure: nil, confirmed: nil)
        }, recoveredCount: 0)
    }
    let manifest = m([.ready, .confirmed, .failed, .processing, .ready, .queued, .ready])
    #expect(manifest.nextToReview(after: "p1")?.id == "p5")
    #expect(manifest.nextToReview(after: "p5")?.id == "p7")
    #expect(manifest.nextToReview(after: "p7")?.id == "p1", "뒤에 없으면 앞쪽")
    #expect(manifest.nextToReview(after: nil)?.id == "p1")
    #expect(m([.confirmed, .ready]).nextToReview(after: "p2") == nil, "남은 ready가 없으면 목록으로")
  }
}

struct ReviewProcessorTests {
  /// 제안이 놓친 민감한 줄(전화·카드)을 사용자가 고친다: 전화 줄은 OCR 줄로, 카드 줄은 직접 더한 띠로 가린다.
  /// 미리보기와 확인한 사본이 같은 픽셀이고, 두 줄 모두 검정이다.
  @Test func correctedMissedMasksAreBakedLikeThePreview() async throws {
    let (store, draft, processor) = try await processed(["receipt-r01.png"])
    let id = item(await processor.snapshot(), .ready).id
    let proposal = try await processor.proposal(id)
    let tel = try #require(proposal.ocr.lines.first { $0.text.contains("TEL") })
    let region = MaskRegion(id: "card", topPercent: 79, heightPercent: 6)

    let preview = try await processor.preview(id, maskLineIDs: [tel.id], regions: [region])
    #expect(preview.maskCount == 2)
    #expect(try store.loadProcessing(draft.id)?.items.first?.state == .ready, "미리보기는 확인이 아니다")
    #expect(
      !FileManager.default.fileExists(atPath: store.artifactURL(draft.id, id + ".png").path), "미리보기는 디스크에 쓰지 않는다")

    let receipt = try await processor.confirm(id, fields: proposal.fields, maskLineIDs: [tel.id], regions: [region])
    let artifact = try Data(contentsOf: store.artifactURL(draft.id, try #require(receipt.artifactFileName)))
    #expect(artifact == preview.pngData, "보여 준 미리보기와 같은 사본")
    let pixels = try blackRows(artifact)
    for y in 166..<188 { #expect(pixels.contains(y), "TEL \(y)") }
    for y in 597..<621 { #expect(pixels.contains(y), "card \(y)") }
    #expect(!pixels.contains(400), "다른 줄은 그대로")
  }

  /// 읽지 못한 사진: 다시 읽어도 실패 → 직접 입력 값이 다시 읽기를 지나도 남고 → 사본 없이 확인 → 경계는 내보내지 않는다.
  @Test func manualEntrySurvivesRetryAndNeverLeavesDevice() async throws {
    let (store, draft, processor) = try await processed(["receipt-r01.png", "receipt-r10.png"])
    let failed = item(await processor.snapshot(), .failed).id
    try await processor.saveReview(failed, ReviewDraft(date: "2026-11-08", amount: "1760", merchant: "かもめ寿司"))
    try await processor.retry(failed)
    #expect(try await processor.review(failed)?.amount == "1760", "다시 읽는 중에도 직접 입력이 남는다")
    await processor.run()
    #expect(item(await processor.snapshot(), .failed).attempts == 2)
    let resolved = try #require(try await processor.review(failed)).resolved(with: nil)
    #expect(resolved.date == "2026-11-08" && resolved.currency == "JPY")

    let fields = try ReviewForm.validate(
      date: resolved.date, amount: resolved.amount, currency: resolved.currency, merchant: resolved.merchant
    ).get()
    let manual = try await processor.confirmManual(failed, fields: fields)
    #expect(manual.isManualEntry)
    #expect(try store.loadProcessing(draft.id)?.items.first { $0.id == failed }?.state == .confirmed)
    #expect(!FileManager.default.fileExists(atPath: store.reviewURL(draft.id, failed).path), "확인하면 검토 입력을 지운다")
    #expect(try await processor.outboundReceipts().isEmpty, "직접 입력(사본 없음)은 내보내지 않는다")

    let ready = item(await processor.snapshot(), .ready).id
    let proposal = try await processor.proposal(ready)
    try await processor.confirm(ready, fields: proposal.fields, maskLineIDs: Set(proposal.suggestedMaskLineIDs))
    let outbound = try await processor.outboundReceipts()
    #expect(outbound.map(\.receipt.itemID) == [ready], "가린 사본이 있는 한 장만")
  }

  @Test func reviewDraftIsDurableAndOverridesOnlyWhatUserChanged() async throws {
    let (store, draft, processor) = try await processed(["receipt-r01.png"])
    let id = item(await processor.snapshot(), .ready).id
    try await processor.saveReview(id, ReviewDraft(amount: "1500", regions: [MaskRegion(id: "r", topPercent: 10)]))
    // 처리기를 새로 만든다(앱 종료 뒤 다시 열기와 같다).
    let reopened = try ReceiptProcessor(store: store, draft: draft, recognizer: VisionReceiptRecognizer())
    let review = try #require(try await reopened.review(id))
    let resolved = review.resolved(with: try await reopened.proposal(id))
    #expect(resolved.amount == "1500")
    #expect(resolved.date == "2026-11-03", "고치지 않은 값은 제안 그대로")
    #expect(resolved.regions.map(\.topPercent) == [10])
    #expect(resolved.maskLineIDs == Set(try await reopened.proposal(id).suggestedMaskLineIDs))

    let fields = try ReviewForm.validate(
      date: resolved.date, amount: resolved.amount, currency: resolved.currency, merchant: resolved.merchant
    ).get()
    try await reopened.confirm(id, fields: fields, maskLineIDs: resolved.maskLineIDs, regions: resolved.regions)
    await #expect(throws: ProcessorError.wrongState) { try await reopened.saveReview(id, ReviewDraft()) }
    await #expect(throws: ProcessorError.wrongState) { try await reopened.confirmManual(id, fields: fields) }
  }
}

/// 한 줄 전체(가로 가운데 10px 표본)가 검정인 y 좌표.
private func blackRows(_ png: Data) throws -> Set<Int> {
  let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
  let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
  let ctx = try #require(
    CGContext(
      data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  var rows: Set<Int> = []
  for y in 0..<image.height {
    let black = stride(from: 0, to: image.width, by: max(1, image.width / 10)).allSatisfy { x in
      let o = (y * image.width + x) * 4
      return bytes[o] == 0 && bytes[o + 1] == 0 && bytes[o + 2] == 0
    }
    if black { rows.insert(y) }
  }
  return rows
}
