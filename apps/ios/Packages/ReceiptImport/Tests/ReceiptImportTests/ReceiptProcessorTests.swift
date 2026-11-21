import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ReceiptImport

/// 가상 영수증 10장(apps/fixtures/receipts, 생성기 출력)과 정답. 앱 번들에는 들어가지 않는다.
private let fixtures = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "fixtures/receipts")

private struct Truth: Decodable {
  struct Line: Decodable {
    let text: String
    let rect: [Int]
  }
  let file: String
  let ref: String
  let date: String
  let total: Int
  let unreadable: Bool
  let width: Int
  let height: Int
  let lines: [Line]
  let sensitive: [Line]
}

private let truths: [Truth] = try! JSONDecoder().decode(
  [Truth].self, from: Data(contentsOf: fixtures.appending(path: "ground-truth.json")))

private func photo(_ t: Truth) throws -> IncomingPhoto {
  IncomingPhoto(fileExtension: "png", content: .data(try Data(contentsOf: fixtures.appending(path: t.file))))
}

private func tempRoot() -> URL {
  FileManager.default.temporaryDirectory.appending(path: "receipts-\(UUID().uuidString)")
}

/// 정답의 줄 위치로 만든 결정적 OCR 대역. 호출을 세고, 정한 호출부터 풀어 줄 때까지 붙잡아 둘 수 있다.
private final class TruthRecognizer: ReceiptRecognizer, @unchecked Sendable {
  private let lock = NSLock()
  private let holdFromCall: Int?
  private var released = false
  private(set) var calls: [String] = []

  init(holdFromCall: Int? = nil) { self.holdFromCall = holdFromCall }

  func release() { lock.withLock { released = true } }

  func recognize(_ url: URL) throws -> OCRResult {
    let count = lock.withLock {
      calls.append(url.lastPathComponent)
      return calls.count
    }
    if let holdFromCall, count >= holdFromCall {
      while !lock.withLock({ released }) { Thread.sleep(forTimeInterval: 0.01) }
      throw ProcessingFailure.recognitionError
    }
    let data = try Data(contentsOf: url)
    let t = truths.first { (try? Data(contentsOf: fixtures.appending(path: $0.file))) == data }!
    if t.unreadable { return OCRResult(pixelWidth: t.width, pixelHeight: t.height, lines: []) }
    return OCRResult(
      pixelWidth: t.width, pixelHeight: t.height,
      lines: t.lines.enumerated().map { i, line in
        let w = Double(t.width)
        let h = Double(t.height)
        return OCRLine(
          id: i, text: line.text, x: Double(line.rect[0]) / w, y: Double(line.rect[1]) / h,
          width: Double(line.rect[2] - line.rect[0]) / w, height: Double(line.rect[3] - line.rect[1]) / h)
      })
  }
}

private func waitUntil(_ timeout: Duration = .seconds(60), _ condition: () async -> Bool) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while clock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  Issue.record("timed out")
}

struct ReceiptProcessorTests {
  /// 실제 Apple Vision 일본어 OCR(macOS)로 10장 모두 읽는다. r10(초점 나감)은 읽지 못해야 한다.
  @Test func realJapaneseOCRProposalsMatchFixtures() throws {
    for t in truths {
      let ocr = try VisionReceiptRecognizer().recognize(fixtures.appending(path: t.file))
      if t.unreadable {
        #expect(throws: ProcessingFailure.self, "\(t.ref)") { try ProposalBuilder.make(ocr) }
        continue
      }
      let proposal = try ProposalBuilder.make(ocr)
      #expect(proposal.fields.date == t.date, "\(t.ref)")
      #expect(proposal.fields.amountMinor == t.total, "\(t.ref)")
      // 정답의 민감한 줄마다, 같은 높이에 걸친 가림 후보가 있어야 한다.
      let suggested = ocr.lines.filter { proposal.suggestedMaskLineIDs.contains($0.id) }
      for s in t.sensitive {
        let mid = Double(s.rect[1] + s.rect[3]) / 2 / Double(t.height)
        #expect(suggested.contains { $0.y <= mid && mid <= $0.y + $0.height }, "\(t.ref) \(s.text)")
      }
    }
  }

  @Test func tenPhotosAtMostTwoAtATimeAndBadPhotoIsIsolated() async throws {
    let store = ReceiptDraftStore(root: tempRoot())
    let draft = try store.create(source: .share, photos: truths.map(photo))
    let processor = try ReceiptProcessor(store: store, draft: draft, recognizer: VisionReceiptRecognizer())
    await processor.run()
    let manifest = await processor.snapshot()

    #expect(await processor.peakInFlight == 2)
    #expect(manifest.items.filter { $0.state == .ready }.count == 9)
    let bad = try #require(manifest.items.first { $0.state == .failed })
    #expect(truths[bad.position - 1].unreadable)
    #expect(bad.failure == .unreadable)

    // 실패한 한 장만 다시 읽는다. 다른 사진은 그대로다.
    try await processor.retry(bad.id)
    await processor.run()
    let after = await processor.snapshot()
    #expect(after.items.first { $0.id == bad.id }?.attempts == 2)
    #expect(after.items.first { $0.id == bad.id }?.state == .failed)
    #expect(after.items.filter { $0.id != bad.id } == manifest.items.filter { $0.id != bad.id })
  }

  /// 4장을 끝내고 2장을 읽는 중인 디스크 상태를 복사해 다시 연다(프로세스 종료와 같다).
  @Test func interruptedProcessingResumesOnlyUnfinishedPhotos() async throws {
    let root = tempRoot()
    let store = ReceiptDraftStore(root: root)
    let draft = try store.create(source: .share, photos: truths.map(photo))
    let first = TruthRecognizer(holdFromCall: 5)
    let processor = try ReceiptProcessor(store: store, draft: draft, recognizer: first)
    let run = Task { await processor.run() }
    try await waitUntil {
      let m = try? store.loadProcessing(draft.id)
      return m?.items.filter { $0.state == .ready }.count == 4 && m?.items.filter { $0.state == .processing }.count == 2
    }
    let copy = tempRoot()
    try FileManager.default.copyItem(at: root, to: copy)
    first.release()
    await run.value

    let reopenedStore = ReceiptDraftStore(root: copy)
    let atKill = try #require(try reopenedStore.loadProcessing(draft.id))
    #expect(
      atKill.items.map(\.state.rawValue).sorted()
        == (Array(repeating: "processing", count: 2) + Array(repeating: "queued", count: 4)
        + Array(repeating: "ready", count: 4)).sorted())

    let second = TruthRecognizer()
    let resumed = try ReceiptProcessor(store: reopenedStore, draft: draft, recognizer: second)
    #expect(await resumed.snapshot().recoveredCount == 2)
    await resumed.run()
    let done = await resumed.snapshot()
    #expect(second.calls.count == 6, "끝난 4장은 다시 읽지 않는다")
    #expect(done.items.filter { $0.state == .ready }.count == 9)
    #expect(done.items.filter { $0.state == .failed }.map(\.failure) == [.unreadable])
    #expect(done.items.map(\.attempts) == [1, 1, 1, 1, 2, 2, 1, 1, 1, 1])
  }

  /// 확인하면 민감한 줄의 픽셀이 검정으로 구워지고, 그 밖의 픽셀과 다르지 않으며, 원본 메타데이터가 없다.
  @Test func confirmFlattensMasksAndStripsMetadata() async throws {
    let t = truths[0]
    let store = ReceiptDraftStore(root: tempRoot())
    let draft = try store.create(source: .share, photos: [try photo(t)])
    let processor = try ReceiptProcessor(store: store, draft: draft, recognizer: VisionReceiptRecognizer())
    await processor.run()
    let id = try #require(await processor.snapshot().items.first?.id)
    let proposal = try await processor.proposal(id)
    let receipt = try await processor.confirm(
      id, fields: proposal.fields, maskLineIDs: Set(proposal.suggestedMaskLineIDs))

    let artifact = try Data(contentsOf: store.artifactURL(draft.id, receipt.artifactFileName))
    let original = try Data(contentsOf: fixtures.appending(path: t.file))
    #expect(artifact != original)
    #expect(Set(try PNGChunks.names(artifact)).isSubset(of: PNGChunks.allowed))
    #expect(try PNGChunks.names(original).contains { !PNGChunks.allowed.contains($0) }, "원본에는 메타데이터가 있다")
    for marker in ["SYNTHETIC-ORIGINAL-METADATA", "SyntheticCam", "NNA-r01"] {
      #expect(artifact.range(of: Data(marker.utf8)) == nil, "\(marker)")
    }
    let masked = try rgba(artifact)
    let source = try rgba(original)
    for s in t.sensitive {
      var ink = 0
      for y in s.rect[1]..<s.rect[3] {
        for x in s.rect[0]..<s.rect[2] where source.isInk(x, y) {
          ink += 1
          #expect(masked.isBlack(x, y), "\(s.text) (\(x),\(y))")
        }
      }
      #expect(ink > 0)
    }
    // 가림 띠 밖은 원본과 같다(여백 포함 띠는 OCR 상자 기준이라 정답 줄의 위아래 16px를 띄워 본다).
    let bands = t.sensitive.map { ($0.rect[1] - 40)...($0.rect[3] + 40) }
    for y in stride(from: 0, to: t.height, by: 3) where !bands.contains(where: { $0.contains(y) }) {
      for x in stride(from: 0, to: t.width, by: 3) {
        #expect(masked.pixel(x, y) == source.pixel(x, y))
      }
    }
  }

  @Test func boundaryReleasesOnlyVerifiedConfirmedReceipts() async throws {
    let store = ReceiptDraftStore(root: tempRoot())
    let draft = try store.create(source: .share, photos: [try photo(truths[0]), try photo(truths[1])])
    let processor = try ReceiptProcessor(store: store, draft: draft, recognizer: TruthRecognizer())
    await processor.run()
    #expect(try await processor.outboundReceipts().isEmpty, "확인 전에는 아무것도 없다")

    let id = try #require(await processor.snapshot().items.first?.id)
    let proposal = try await processor.proposal(id)
    let receipt = try await processor.confirm(id, fields: proposal.fields, maskLineIDs: [])
    #expect(try await processor.outboundReceipts() == [receipt], "확인한 한 장만")

    // 가림 사본이 원본으로 바뀌면 내보내지 않는다.
    let original = try Data(contentsOf: store.photoURL(draft.id, draft.photoFileNames[0]))
    try original.write(to: store.artifactURL(draft.id, receipt.artifactFileName))
    await #expect(throws: BoundaryViolation.artifactHashMismatch) { try await processor.outboundReceipts() }
  }

  @Test func confirmRejectsInvalidFieldsAndWrongState() async throws {
    let store = ReceiptDraftStore(root: tempRoot())
    let draft = try store.create(source: .share, photos: [try photo(truths[0]), try photo(truths[9])])
    let processor = try ReceiptProcessor(store: store, draft: draft, recognizer: TruthRecognizer())
    await processor.run()
    let items = await processor.snapshot().items
    let bad = AllowedReceiptFields(date: "2026-13-40", amountMinor: 100, currency: "JPY", merchant: nil)
    await #expect(throws: ProcessorError.invalidFields) {
      try await processor.confirm(items[0].id, fields: bad, maskLineIDs: [])
    }
    let ok = AllowedReceiptFields(date: "2026-11-03", amountMinor: 100, currency: "JPY", merchant: nil)
    await #expect(throws: ProcessorError.wrongState) {
      try await processor.confirm(items[1].id, fields: ok, maskLineIDs: [])
    }
  }
}

private struct RGBA {
  let width: Int
  let bytes: [UInt8]
  func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * width + x) * 4..<(y * width + x) * 4 + 3]) }
  func isBlack(_ x: Int, _ y: Int) -> Bool { pixel(x, y) == [0, 0, 0] }
  func isInk(_ x: Int, _ y: Int) -> Bool { pixel(x, y).allSatisfy { $0 < 128 } }
}

private func rgba(_ png: Data) throws -> RGBA {
  let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
  let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
  let ctx = try #require(
    CGContext(
      data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return RGBA(width: image.width, bytes: bytes)
}
