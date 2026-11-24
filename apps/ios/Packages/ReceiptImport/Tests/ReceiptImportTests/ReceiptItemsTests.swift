import Foundation
import Testing

@testable import ReceiptImport

/// 품목 나누기 공통 예제(apps/fixtures/items). Android JVM 테스트가 같은 파일을 읽는다.
private let itemFixtures = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "fixtures/items")

private struct Examples: Decodable {
  struct Line: Decodable {
    let id: Int
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
  }
  struct ExpectedItem: Decodable {
    let id: String
    let name: String
    let amount: Int?
    let flags: [String]
  }
  struct ExpectedSummary: Decodable {
    let id: String
    let kind: String
    let amount: Int?
  }
  struct Extraction: Decodable {
    let name: String
    let receiptTotal: Int
    let lines: [Line]
    let items: [ExpectedItem]
    let summary: [ExpectedSummary]
    let ocrTotal: Int?
  }
  struct RealItem: Decodable {
    let id_text: String
    let amount: Int
    let flags: [String]
  }
  struct Real: Decodable {
    let file: String
    let date: String
    let total: Int
    let items: [RealItem]
    let summaryKinds: [String]
  }
  struct AllocLine: Decodable {
    let id: String
    let kind: String
    let amount: String
    let flags: [String]
    let checked: Bool
    let excluded: Bool
    let assignees: [String]
  }
  struct Expect: Decodable {
    let kind: String
    let shares: [String: Int]?
    let remaining: Int?
    let problem: String?
    let line: String?
    let difference: Int?
    let member: String?
  }
  struct Allocation: Decodable {
    let name: String
    let currency: String
    let total: Int
    let krw: Int?
    let payer: String?
    let members: [String]
    let lines: [AllocLine]
    let expect: Expect
  }
  let extractor: String
  let extraction: [Extraction]
  let real_ocr: [Real]
  let allocation: [Allocation]
}

private let examples = try! JSONDecoder().decode(
  Examples.self, from: Data(contentsOf: itemFixtures.appending(path: "examples.json")))

private func plan(_ a: Examples.Allocation) -> ItemPlan {
  ItemPlan(
    extractor: ItemExtractor.version, currency: a.currency, receiptTotalMinor: a.total, ocrTotalMinor: nil,
    summary: [],
    lines: a.lines.map {
      ItemPlanLine(
        id: $0.id, kind: ItemPlanLine.Kind(rawValue: $0.kind)!, sourceLineIDs: [], originalText: "", originalName: "",
        name: $0.id, nameSource: .user, amountText: $0.amount, flags: $0.flags.map { ItemFlag(rawValue: $0)! },
        checked: $0.checked, excluded: $0.excluded, assignees: $0.assignees)
    }, nextManualNumber: 10)
}

private func describe(_ r: Result<ItemAllocation, ItemAllocationProblem>) -> Examples.Expect {
  func map(_ s: [ItemMemberShare]) -> [String: Int] { Dictionary(uniqueKeysWithValues: s.map { ($0.member, $0.krw) }) }
  switch r {
  case .success(.exact(let s)):
    return .init(kind: "exact", shares: map(s), remaining: nil, problem: nil, line: nil, difference: nil, member: nil)
  case .success(.pairRule(let s)):
    return .init(
      kind: "pairRule", shares: map(s), remaining: nil, problem: nil, line: nil, difference: nil, member: nil)
  case .success(.remainder(let s, let rem)):
    return .init(
      kind: "remainder", shares: map(s), remaining: rem, problem: nil, line: nil, difference: nil, member: nil)
  case .failure(let p):
    var line: String?
    var difference: Int?
    var member: String?
    let name: String
    switch p {
    case .noLines: name = "noLines"
    case .unsupportedCurrency: name = "unsupportedCurrency"
    case .amountInvalid(let id):
      name = "amountInvalid"
      line = id
    case .needsCheck(let id):
      name = "needsCheck"
      line = id
    case .unassigned(let id):
      name = "unassigned"
      line = id
    case .totalMismatch(let d):
      name = "totalMismatch"
      difference = d
    case .krwMissing: name = "krwMissing"
    case .nonPositiveShare(let m):
      name = "nonPositiveShare"
      member = m
    case .tooLarge: name = "tooLarge"
    }
    return .init(
      kind: "problem", shares: nil, remaining: nil, problem: name, line: line, difference: difference, member: member)
  }
}

extension Examples.Expect: Equatable {
  fileprivate static func == (a: Self, b: Self) -> Bool {
    a.kind == b.kind && a.shares == b.shares && a.remaining == b.remaining && a.problem == b.problem && a.line == b.line
      && a.difference == b.difference && a.member == b.member
  }
}

private func tempRoot() -> URL {
  FileManager.default.temporaryDirectory.appending(path: "items-\(UUID().uuidString)")
}

/// 공통 예제 single_line_rows의 OCR 줄(r01과 같은 글자)을 돌려주는 대역. 실제 Vision은 위 테스트 하나만 쓴다
/// (Vision 요청을 여러 테스트가 동시에 막아 두면 Vision 안 작업 대기열이 협력 스레드를 모두 잡아 멈춘다).
private struct RowsRecognizer: ReceiptRecognizer {
  func recognize(_ url: URL) throws -> OCRResult {
    let e = examples.extraction[0]
    return OCRResult(
      pixelWidth: 1000, pixelHeight: 1000,
      lines: e.lines.map { OCRLine(id: $0.id, text: $0.text, x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
  }
}

/// 실제 Apple Vision 일본어 OCR(macOS)로 가상 품목 영수증을 읽어 품목·요약을 나눈다. Vision 요청이 동시에 늘지 않도록
/// 따로 테스트로 두지 않고 `ReceiptProcessorTests.realJapaneseOCRProposalsMatchFixtures`가 이어서 부른다
/// (Vision 요청을 여러 테스트가 동시에 막아 두면 Vision 안 작업 대기열이 협력 스레드를 모두 잡아 멈춘다).
func checkRealVisionItemReceipts() throws {
  for r in examples.real_ocr {
    let ocr = try VisionReceiptRecognizer().recognize(itemFixtures.appending(path: r.file))
    let proposal = try ProposalBuilder.make(ocr)
    #expect(proposal.fields.date == r.date, "\(r.file)")
    #expect(proposal.fields.amountMinor == r.total, "\(r.file)")
    let plan = try #require(ItemPlan.seed(fields: proposal.fields, ocr: ocr))
    #expect(plan.lines.map(\.originalName) == r.items.map(\.id_text), "\(r.file)")
    #expect(plan.lines.map(\.amountMinor) == r.items.map(\.amount), "\(r.file)")
    #expect(plan.lines.map { $0.flags.map(\.rawValue) } == r.items.map(\.flags), "\(r.file)")
    #expect(plan.summary.map(\.kind.rawValue) == r.summaryKinds, "\(r.file)")
    // 안정 ID: 같은 OCR에서 다시 만들어도 같은 ID다.
    #expect(ItemPlan.seed(fields: proposal.fields, ocr: ocr)?.lines.map(\.id) == plan.lines.map(\.id))
    #expect(Set(plan.lines.map(\.id)).count == plan.lines.count)
  }
}

struct ReceiptItemsTests {
  @Test func sharedExtractionExamples() {
    #expect(examples.extractor == ItemExtractor.version)
    for e in examples.extraction {
      let ocr = OCRResult(
        pixelWidth: 1000, pixelHeight: 1000,
        lines: e.lines.map { OCRLine(id: $0.id, text: $0.text, x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
      let result = ItemExtractor.extract(ocr, receiptTotal: e.receiptTotal)
      #expect(result.candidates.map(\.id) == e.items.map(\.id), "\(e.name)")
      for (got, want) in zip(result.candidates, e.items) {
        #expect(got.originalName == want.name, "\(e.name) \(want.id)")
        #expect(got.amountMinor == want.amount, "\(e.name) \(want.id)")
        #expect(got.flags.map(\.rawValue) == want.flags, "\(e.name) \(want.id)")
      }
      #expect(result.summary.map(\.id) == e.summary.map(\.id), "\(e.name)")
      #expect(result.summary.map(\.kind.rawValue) == e.summary.map(\.kind), "\(e.name)")
      #expect(result.summary.map(\.amountMinor) == e.summary.map(\.amount), "\(e.name)")
      #expect(result.ocrTotalMinor == e.ocrTotal, "\(e.name)")
    }
  }

  @Test func sharedAllocationExamples() {
    for a in examples.allocation {
      let got = describe(ItemAllocator.allocate(plan: plan(a), krw: a.krw, payer: a.payer, members: a.members))
      #expect(got == a.expect, "\(a.name)")
      if case "exact" = a.expect.kind, let shares = a.expect.shares {
        let krw = a.currency == "KRW" ? a.total : a.krw!
        #expect(shares.values.reduce(0, +) == krw, "\(a.name) 합 = 원화")
      }
    }
  }

  @Test func editsKeepStableIDsAndUserNames() throws {
    let a = examples.allocation.first { $0.name == "i02_tax_discount_mismatch" }!
    var p = plan(a)
    p.applyTranslations(["ocr-2": "주먹밥 연어", "ocr-4": "녹차 병"], source: .onDevice)
    #expect(p.line("ocr-2")?.nameSource == .user)  // 예제는 사용자가 적은 이름 → 덮지 않는다
    var seeded = p
    seeded.setName("ocr-4", "녹차")
    seeded.applyTranslations(["ocr-4": "다른 번역"], source: .preview)
    #expect(seeded.line("ocr-4")?.name == "녹차")

    let first = p.addLine(kind: .adjustment, name: "할인", amountText: "-50")
    let second = p.addLine(kind: .adjustment, name: "세금", amountText: "51")
    #expect(first == "manual-10" && second == "manual-11")
    p.removeManual(first)
    let third = p.addLine(kind: .item, name: "봉투", amountText: "3")
    #expect(third == "manual-12")  // 지운 번호를 다시 쓰지 않는다
    p.removeManual("ocr-2")  // OCR 후보는 지우지 않는다
    #expect(p.line("ocr-2") != nil)
    p.setExcluded("ocr-2", true)
    #expect(p.activeLines.map(\.id) == ["ocr-4", "ocr-6", "manual-11", "manual-12"])
    #expect(ItemPlan.parseAmount("-50", allowNegative: false) == nil)
    #expect(ItemPlan.parseAmount("▲５０", allowNegative: true) == -50)
    #expect(ItemPlan.parseAmount("1,320", allowNegative: false) == 1320)
    #expect(ItemPlan.parseAmount("0", allowNegative: true) == nil)
  }

  /// 확인한 영수증의 계획은 초안 폴더에만 쓰고, 다시 열어도(새 처리기) 같은 값이며, 늦게 온 옛 입력이 덮지 않는다.
  /// 기기 밖으로 보내는 값(`outboundReceipts`, 확인한 허용 필드)은 계획과 관계없이 그대로다.
  @Test func planIsDurableLocalAndOutsideTheBoundary() async throws {
    let root = tempRoot()
    let store = ReceiptDraftStore(root: root)
    let draft = try store.create(
      source: .share,
      photos: [
        IncomingPhoto(
          fileExtension: "png", content: .data(try Data(contentsOf: itemFixtures.appending(path: "receipt-i01.png"))))
      ])
    let processor = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    await processor.run()
    let item = try #require(await processor.snapshot().items.first)
    await #expect(throws: ProcessorError.wrongState) { _ = try await processor.itemPlan(item.id) }
    let proposal = try await processor.proposal(item.id)
    try await processor.confirm(item.id, fields: proposal.fields, maskLineIDs: Set(proposal.suggestedMaskLineIDs))
    let before = try await processor.outboundReceipts()

    var plan = try #require(try await processor.itemPlan(item.id))
    #expect(plan.lines.map(\.id) == ["ocr-3", "ocr-4"])
    #expect(plan.difference == 128)  // 외세: 품목 1,280엔, 합계 1,408엔
    plan.setAssignee("ocr-4", member: "host", on: true)
    plan.setName("ocr-4", "풋콩")
    plan.addLine(kind: .adjustment, name: "자릿세", amountText: "300")
    try await processor.saveItemPlan(item.id, plan, revision: 2)
    var stale = plan
    stale.setName("ocr-4", "옛 입력")
    try await processor.saveItemPlan(item.id, stale, revision: 1)

    let reopened = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    let loaded = try #require(try await reopened.itemPlan(item.id))
    #expect(loaded == plan)
    #expect(loaded.line("ocr-4")?.name == "풋콩")

    // 합계가 확인한 값과 다른 계획은 쓰지 않는다.
    let wrong = ItemPlan(
      extractor: plan.extractor, currency: plan.currency, receiptTotalMinor: 1, ocrTotalMinor: nil, summary: [],
      lines: [], nextManualNumber: 1)
    await #expect(throws: ProcessorError.invalidFields) { try await reopened.saveItemPlan(item.id, wrong) }

    let after = try await reopened.outboundReceipts()
    #expect(after == before)
    #expect(after.first?.receipt.fields == proposal.fields)
    // 계획 파일은 초안 폴더 안 items/에만 있다.
    let file = root.appending(path: "drafts/\(draft.id)/items/\(item.id).json")
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  /// 저장 실패를 숨기지 않는다. 디스크에는 마지막으로 쓴 계획이 남는다.
  @Test func failedPlanWriteThrowsAndKeepsLastSaved() async throws {
    let root = tempRoot()
    let failing = LockedFlag()
    let store = ReceiptDraftStore(root: root, writeFault: { url in url.path.contains("/items/") && failing.value })
    let draft = try store.create(
      source: .share,
      photos: [
        IncomingPhoto(
          fileExtension: "png", content: .data(try Data(contentsOf: itemFixtures.appending(path: "receipt-i02.png"))))
      ])
    let processor = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    await processor.run()
    let item = try #require(await processor.snapshot().items.first)
    let proposal = try await processor.proposal(item.id)
    try await processor.confirm(item.id, fields: proposal.fields, maskLineIDs: [])
    var plan = try #require(try await processor.itemPlan(item.id))
    plan.setName("ocr-3", "정식")
    try await processor.saveItemPlan(item.id, plan)
    failing.value = true
    var next = plan
    next.setName("ocr-3", "저장 안 됨")
    await #expect(throws: ReceiptStorageError.writeFailed) { try await processor.saveItemPlan(item.id, next) }
    #expect(try await processor.itemPlan(item.id)?.line("ocr-3")?.name == "정식")
  }

  /// 저장한 계획이 있는데 읽지 못하면(읽기 실패) OCR로 새로 만들지 않고 던진다. 디스크 파일은 그대로이고, 다시 읽으면 같은 계획이 온다.
  @Test func unreadablePlanIsNotReseededAndRetryLoadsIt() async throws {
    let root = tempRoot()
    let failing = LockedFlag()
    let store = ReceiptDraftStore(root: root, readFault: { url in url.path.contains("/items/") && failing.value })
    let (processor, item, draft) = try await confirmedItemReceipt(store)
    var plan = try #require(try await processor.itemPlan(item.id))
    plan.setName("ocr-3", "정식")
    plan.setAssignee("ocr-3", member: "host", on: true)
    try await processor.saveItemPlan(item.id, plan)
    let file = root.appending(path: "drafts/\(draft.id)/items/\(item.id).json")
    let saved = try Data(contentsOf: file)

    failing.value = true
    await #expect(throws: ReceiptStorageError.readFailed) { _ = try await processor.itemPlan(item.id) }
    // 새 처리기(앱 다시 열기)도 같다. OCR 후보로 돌아가지 않는다.
    let reopened = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    await #expect(throws: ReceiptStorageError.readFailed) { _ = try await reopened.itemPlan(item.id) }
    #expect(try Data(contentsOf: file) == saved)

    failing.value = false
    #expect(try await reopened.itemPlan(item.id) == plan)
  }

  /// 풀 수 없는 파일, 확인한 합계·통화와 다른 파일은 `itemPlanInvalid`로 던지고 지우거나 덮지 않는다. 파일이 없을 때만 새로 만든다.
  @Test func invalidPlanFileIsKeptAndOnlyAbsentSeeds() async throws {
    let root = tempRoot()
    let store = ReceiptDraftStore(root: root)
    let (processor, item, draft) = try await confirmedItemReceipt(store)
    let file = root.appending(path: "drafts/\(draft.id)/items/\(item.id).json")
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let seeded = try #require(try await processor.itemPlan(item.id))
    #expect(!FileManager.default.fileExists(atPath: file.path))  // 새로 만든 계획은 쓰지 않는다

    let garbage = Data("{\"extractor\":".utf8)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try garbage.write(to: file)
    await #expect(throws: ProcessorError.itemPlanInvalid) { _ = try await processor.itemPlan(item.id) }
    #expect(try Data(contentsOf: file) == garbage)

    let other = ItemPlan(
      extractor: seeded.extractor, currency: seeded.currency, receiptTotalMinor: seeded.receiptTotalMinor + 1,
      ocrTotalMinor: nil, summary: [], lines: [], nextManualNumber: 1)
    let mismatched = try JSONEncoder().encode(other)
    try mismatched.write(to: file)
    await #expect(throws: ProcessorError.itemPlanInvalid) { _ = try await processor.itemPlan(item.id) }
    #expect(try Data(contentsOf: file) == mismatched)

    try FileManager.default.removeItem(at: file)
    #expect(try await processor.itemPlan(item.id) == seeded)
  }

  /// 늦게 도착한 번역은 그사이 사용자가 적은 이름을 덮지 않고, 원문이 다른 줄(다른 계획)에는 들어가지 않는다.
  @Test func delayedTranslationKeepsManualEditsAndIdentity() async throws {
    let (processor, item, _) = try await confirmedItemReceipt(ReceiptDraftStore(root: tempRoot()))
    var plan = try #require(try await processor.itemPlan(item.id))
    // 번역을 요청할 때의 줄(원문 있음, 사용자 이름 아님).
    let requested = plan.lines.filter { !$0.originalName.isEmpty && $0.nameSource != .user }
    #expect(requested.count >= 2)
    let names = Dictionary(uniqueKeysWithValues: requested.map { ($0.id, "번역-\($0.id)") })
    var originals = Dictionary(uniqueKeysWithValues: requested.map { ($0.id, $0.originalName) })
    // 번역을 기다리는 동안 사용자가 첫 줄 이름을 적었다.
    plan.setName(requested[0].id, "직접 적음")
    // 둘째 줄은 원문이 다른 계획에서 온 결과라고 가정한다(늦게 온 다른 계획의 결과).
    originals[requested[1].id] = "다른 원문"
    plan.applyTranslations(names, source: .onDevice, originals: originals)
    #expect(plan.line(requested[0].id)?.name == "직접 적음")
    #expect(plan.line(requested[0].id)?.nameSource == .user)
    #expect(plan.line(requested[1].id)?.name == "")
    #expect(plan.line(requested[1].id)?.nameSource == ItemPlanLine.NameSource.none)
    for line in requested.dropFirst(2) {
      #expect(plan.line(line.id)?.name == "번역-\(line.id)")
      #expect(plan.line(line.id)?.nameSource == .onDevice)
    }
  }

  /// 직접 입력(사본 없음)은 OCR이 없어 품목 계획이 없다.
  @Test func manualEntryHasNoPlan() async throws {
    let store = ReceiptDraftStore(root: tempRoot())
    let draft = try store.create(
      source: .share, photos: [IncomingPhoto(fileExtension: "png", content: .data(Data([0, 1, 2])))])
    let processor = try ReceiptProcessor(store: store, draft: draft, recognizer: FailingRecognizer())
    await processor.run()
    let item = try #require(await processor.snapshot().items.first)
    try await processor.confirmManual(
      item.id, fields: AllowedReceiptFields(date: "2026-11-05", amountMinor: 3500, currency: "JPY", merchant: nil))
    #expect(try await processor.itemPlan(item.id) == nil)
  }
}

private func confirmedItemReceipt(_ store: ReceiptDraftStore) async throws -> (
  ReceiptProcessor, ProcessingItem, ReceiptDraft
) {
  let draft = try store.create(
    source: .share,
    photos: [
      IncomingPhoto(
        fileExtension: "png", content: .data(try Data(contentsOf: itemFixtures.appending(path: "receipt-i02.png"))))
    ])
  let processor = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
  await processor.run()
  let item = try #require(await processor.snapshot().items.first)
  let proposal = try await processor.proposal(item.id)
  try await processor.confirm(item.id, fields: proposal.fields, maskLineIDs: [])
  return (processor, item, draft)
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = false
  var value: Bool {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

private struct FailingRecognizer: ReceiptRecognizer {
  func recognize(_ url: URL) throws -> OCRResult { throw ProcessingFailure.unreadable }
}
