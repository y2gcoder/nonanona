import Foundation
import ReceiptImport
import SwiftUI
import Testing
import UIKit

@testable import Nonanona

/// 품목 재번역 결과 보존(두 앱 공통 동작 계약 1~4). 가짜 번역기로 응답을 붙잡아 둔 채 시트를 떼었다 붙이고, 처리기를 새로
/// 만들어(같은 초안 폴더를 다시 읽는다) 프로세스 종료를 흉내 낸다. 네트워크·실제 번역 제공자는 쓰지 않는다.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ItemRetranslationTests {
  /// 응답을 놓아 줄 때까지 붙잡아 두는 가짜 번역기. 받은 요청(원문 목록)을 센다.
  final class HeldTranslator: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [[String]] = []
    private var answer: [String: String]?
    private var throwsCancellation = false
    /// 번역기에 들어온 요청(들어온 순간 더한다). 테스트는 이 값으로 진입을 기다린다.
    var calls: [[String]] { lock.withLock { requests } }
    func release(_ names: [String: String]) { lock.withLock { answer = names } }
    /// 다음 요청부터 다시 붙잡는다.
    func hold() { lock.withLock { answer = nil } }
    /// 붙잡아 둔 요청을 취소 예외로 끝낸다.
    func cancel() { lock.withLock { throwsCancellation = true } }
    var translate: ItemRetranslationModel.Translate {
      { names in
        self.lock.withLock { self.requests.append(names) }
        while true {
          if self.lock.withLock({ self.throwsCancellation }) { throw CancellationError() }
          if let answer = self.lock.withLock({ self.answer }) { return names.map { answer[$0] } }
          try await Task.sleep(for: .milliseconds(5))
        }
      }
    }
  }

  /// 저장소 쓰기·읽기를 경로 조각으로 실패시키거나 놓아 줄 때까지 붙잡는다(처리기 actor 안에서 부른다).
  final class StorageGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failing: Set<String> = []
    private var holding: Set<String> = []
    private var held: Set<String> = []
    func fail(_ parts: Set<String>) { lock.withLock { failing = parts } }
    func hold(_ parts: Set<String>) { lock.withLock { holding = parts } }
    /// 지금 붙잡힌 경로 조각.
    var waiting: Set<String> { lock.withLock { held } }
    func check(_ url: URL) -> Bool {
      while let part = lock.withLock({ holding.first { url.path.contains($0) } }) {
        lock.withLock { _ = held.insert(part) }
        Thread.sleep(forTimeInterval: 0.002)
      }
      lock.withLock { held = [] }
      return lock.withLock { failing.contains { url.path.contains($0) } }
    }
  }

  /// 공통 예제(apps/fixtures/items/examples.json)의 첫 영수증과 같은 OCR 줄(日替わり定食·緑茶).
  struct RowsRecognizer: ReceiptRecognizer {
    func recognize(_ url: URL) throws -> OCRResult {
      let rows: [(Int, String, Double)] = [
        (0, "さくら食堂", 0.05), (1, "TEL 03-5550-0101", 0.12), (2, "2026年11月3日 12:41", 0.17),
        (3, "日替わり定食  980円", 0.3), (4, "緑茶  300円", 0.35), (5, "小計 1,280円", 0.4),
        (6, "消費税等 128円", 0.45), (7, "合計 1,408円", 0.5), (8, "カード番号 **** 4821", 0.55),
      ]
      return OCRResult(
        pixelWidth: 1000, pixelHeight: 1000,
        lines: rows.map { OCRLine(id: $0.0, text: $0.1, x: 0.05, y: $0.2, width: 0.3, height: 0.03) })
    }
  }

  /// 앱 한 번 실행: 같은 초안 폴더를 새로 읽은 처리기, 그 화면의 품목 계획, 새 재번역 모델.
  @MainActor final class Launch {
    let processor: ReceiptProcessor
    let target: ReviewTarget
    var plan: ItemPlan
    let model: ItemRetranslationModel

    /// 품목 화면에 들어온 것처럼 계획을 읽고 남긴 재번역을 복원한다(`restore: false`면 복원 전 상태).
    init(
      store: ReceiptDraftStore, draft: ReceiptDraft, translator: HeldTranslator, timeout: Duration = .seconds(40),
      restore: Bool = true
    ) async throws {
      processor = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
      let item = try #require(await processor.snapshot().items.first)
      target = ReviewTarget(draftID: draft.id, itemID: item.id)
      plan = try #require(try await processor.itemPlan(item.id))
      model = ItemRetranslationModel(translate: translator.translate, timeout: timeout)
      model.plan = { [weak self] _ in self?.plan }
      model.processor = { [weak self] _ in self?.processor }
      // 앱 모델과 같은 약속: 계획을 바꾸고 기기에 쓴 뒤에 적용함을 알린다.
      model.applyName = { [weak self] _, line, name in
        guard let self else { return .saveFailed }
        if plan.line(line.id) != line.applyingRetranslation(name) {
          guard plan.acceptRetranslation(name, matching: line) else { return .rejected }
        }
        do {
          try await processor.saveItemPlan(target.itemID, plan)
          return .applied
        } catch {
          return .saveFailed
        }
      }
      if restore { await model.restore(target) }
    }

    var session: ItemRetranslationSession? { model.sessions[target] }
    var lines: [ItemPlanLine] { plan.retranslatableLines }
    func stored() async throws -> ItemRetranslationRecord? { try await processor.itemRetranslation(target.itemID) }
  }

  private let root = FileManager.default.temporaryDirectory.appending(path: "retranslation-\(UUID().uuidString)")
  private static let itemPhoto = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "fixtures/items/receipt-i02.png")

  /// 확인한 품목 영수증 한 장이 있는 초안.
  private func confirmedDraft(faults: WriteFaults? = nil) async throws -> (ReceiptDraftStore, ReceiptDraft) {
    var fault: (@Sendable (URL) -> Bool)?
    if let faults { fault = { faults.shouldFail($0) } }
    let store = ReceiptDraftStore(root: root.appending(path: "receipt-import"), writeFault: fault)
    let draft = try store.create(
      source: .share,
      photos: [IncomingPhoto(fileExtension: "png", content: .data(try Data(contentsOf: Self.itemPhoto)))])
    let processor = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    await processor.run()
    let item = try #require(await processor.snapshot().items.first)
    let proposal = try await processor.proposal(item.id)
    try await processor.confirm(item.id, fields: proposal.fields, maskLineIDs: [])
    return (store, draft)
  }

  private func until(_ what: String, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !condition() {
      guard ContinuousClock.now < deadline else {
        Issue.record("시간 안에 \(what) 되지 않았다")
        throw CancellationError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// 시트를 띄우는 품목 화면 대신, 모델 값으로 같은 시트 수식어를 붙인 화면.
  private struct Host: View {
    let model: ItemRetranslationModel
    let target: ReviewTarget
    var body: some View {
      Color.clear.itemRetranslationSheet(
        model.sessions[target], ItemRetranslationActions(model: model, target: target))
    }
  }

  /// 품목 화면을 창에 붙인다. 시트가 뜨면 그 화면 컨트롤러를 돌려준다.
  private func attach(_ launch: Launch) async throws -> (UIWindow, UIViewController) {
    try await attach(launch.model, launch.target)
  }

  private func attach(_ model: ItemRetranslationModel, _ target: ReviewTarget) async throws
    -> (UIWindow, UIViewController)
  {
    _ = Self.accessibilityTree
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    window.rootViewController = UIHostingController(rootView: Host(model: model, target: target))
    window.makeKeyAndVisible()
    return (window, try await presentedSheet(in: window))
  }

  private func presentedSheet(in window: UIWindow) async throws -> UIViewController {
    try await until("시트가 떠야") { window.rootViewController?.presentedViewController != nil }
    return try #require(window.rootViewController?.presentedViewController)
  }

  private func detach(_ window: UIWindow) {
    window.rootViewController?.dismiss(animated: false)
    window.rootViewController = nil
    window.isHidden = true
  }

  /// 띄운 시트의 툴바 ‘닫기’ 단추가 눌릴 수 있는지. SwiftUI 툴바 단추는 내비게이션 막대의 뒤쪽 단추 묶음에 들어간다.
  /// 단추의 `isEnabled`와, 그 안에 그린 SwiftUI 단추의 접근성 비활성 표시를 함께 본다.
  private func closeEnabled(_ sheet: UIViewController) -> Bool? {
    sheet.view.layoutIfNeeded()
    var views: [UIView] = [sheet.view]
    while let view = views.popLast() {
      if let bar = view as? UINavigationBar {
        for item in bar.items ?? [] {
          let buttons =
            (item.trailingItemGroups + item.leadingItemGroups).flatMap(\.barButtonItems)
            + (item.rightBarButtonItems ?? []) + (item.leftBarButtonItems ?? [])
          for button in buttons where button.title == "닫기" || button.accessibilityIdentifier == "retranslation-close" {
            let drawn = button.customView.map { !Self.marksNotEnabled($0) } ?? true
            return button.isEnabled && drawn
          }
        }
      }
      views.append(contentsOf: view.subviews)
    }
    return nil
  }

  /// SwiftUI는 보조 기술이 켜져 있을 때만 접근성 트리를 만든다. 테스트 프로세스에서 자동화 접근성을 켠다(UI 테스트 도구가
  /// 켜는 것과 같은 설정). 시트 본문의 글과 단추를 접근성 트리로 읽기 위해서다.
  private static let accessibilityTree: Void = {
    guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
      let symbol = dlsym(library, "_AXSSetAutomationEnabled")
    else { return }
    typealias SetEnabled = @convention(c) (Int32) -> Void
    unsafeBitCast(symbol, to: SetEnabled.self)(1)
  }()

  /// 띄운 시트 본문에 그린 접근성 요소(글과 단추). SwiftUI가 그린 요소를 접근성 트리로 훑는다.
  private static func elements(_ sheet: UIViewController) -> [NSObject] {
    sheet.view.layoutIfNeeded()
    var found: [NSObject] = []
    var pending: [NSObject] = [sheet.view]
    // 같은 요소가 하위 뷰와 접근성 자식 두 길로 나올 수 있어 한 번만 센다.
    var seen: Set<ObjectIdentifier> = []
    while let element = pending.popLast(), seen.count < 5000 {
      guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
      // 재사용을 기다리는 칸처럼 숨긴 뷰 아래에는 앞 상태의 요소가 남아 있다. 보이는 것만 센다.
      if let view = element as? UIView, view.isHidden || view.alpha < 0.01 || view.window == nil { continue }
      if element.isAccessibilityElement, !element.accessibilityElementsHidden {
        let frame = element.accessibilityFrame
        if !frame.isEmpty, frame.intersects(sheet.view.window?.bounds ?? .zero) { found.append(element) }
      }
      if let children = element.accessibilityElements as? [NSObject] {
        pending.append(contentsOf: children)
      } else {
        let count = element.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
          pending.append(contentsOf: (0..<count).compactMap { element.accessibilityElement(at: $0) as? NSObject })
        }
      }
      if let view = element as? UIView { pending.append(contentsOf: view.subviews) }
    }
    return found
  }

  /// 시트 본문에 보이는 글(접근성 이름).
  private static func labels(_ sheet: UIViewController) -> [String] {
    elements(sheet).compactMap(\.accessibilityLabel)
  }

  /// 이름이 `label`인 단추를 누른다(접근성 활성화). 그런 단추가 하나뿐일 때만 누르고 참을 돌려준다.
  private static func press(_ label: String, in sheet: UIViewController) -> Bool {
    let buttons = elements(sheet).filter { $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button) }
    guard buttons.count == 1 else { return false }
    return buttons[0].accessibilityActivate()
  }

  /// 뷰나 그 안의 접근성 요소가 비활성으로 표시됐는지.
  private static func marksNotEnabled(_ root: UIView) -> Bool {
    var elements: [NSObject] = [root]
    var seen = 0
    while let element = elements.popLast(), seen < 500 {
      seen += 1
      if element.accessibilityTraits.contains(.notEnabled) { return true }
      if let control = element as? UIControl, !control.isEnabled { return true }
      if let children = element.accessibilityElements as? [NSObject] { elements.append(contentsOf: children) }
      if let view = element as? UIView { elements.append(contentsOf: view.subviews) }
    }
    return false
  }

  /// 기기에 기록을 직접 둔다(앱이 그 상태에서 끝난 것을 흉내).
  private func storeRecord(_ record: ItemRetranslationRecord, _ store: ReceiptDraftStore, _ draft: ReceiptDraft)
    async throws
  {
    let processor = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    let item = try #require(await processor.snapshot().items.first)
    try await processor.saveItemRetranslation(item.id, record)
  }

  // MARK: - 1. 실수로 닫히지 않는다

  /// 요청 중과 결과 단계의 시트는 아래로 쓸기·바깥 터치로 닫히지 않는다(`isModalInPresentation`, ‘닫기’로만).
  /// 동의 단계와 실패 안내는 쉽게 닫힌다.
  @Test func requestAndResultSheetCannotBeSwipedAwayButConsentCan() async throws {
    let (store, draft) = try await confirmedDraft()
    let translator = HeldTranslator()
    let launch = try await Launch(store: store, draft: draft, translator: translator)
    let line = try #require(launch.lines.first)
    launch.model.begin(launch.target, lines: [line])
    let (window, sheet) = try await attach(launch)
    defer { detach(window) }
    #expect(launch.session?.phase == .consent)
    #expect(!sheet.isModalInPresentation, "동의 단계는 쉽게 닫힌다")
    try await until("동의 단계의 ‘닫기’는 눌려야") { closeEnabled(sheet) == true }

    launch.model.confirm(launch.target)
    #expect(launch.session?.blocksDismissal == true)
    try await until("요청 중 시트가 쓸기를 막아야") { sheet.isModalInPresentation }
    try await until("요청 중 ‘닫기’는 비활성이어야") { closeEnabled(sheet) == false }
    translator.release([line.originalName: "오늘의 정식"])
    try await until("결과가 와야") { launch.session?.phase == .results && launch.session?.saving == false }
    #expect(launch.session?.blocksDismissal == true)
    try await until("결과 시트가 쓸기를 막아야") { sheet.isModalInPresentation }
    try await until("결과 단계의 ‘닫기’는 눌려야") { closeEnabled(sheet) == true }

    launch.model.close(launch.target)
    try await until("결과 단계는 ‘닫기’로 닫아야") { launch.session == nil }
  }

  /// 단추가 아닌 길로 시트가 닫히면(아래로 쓸기, 화면이 빠지며 시스템이 닫음) 쉽게 닫히는 단계만 끝나고, 요청 중·결과는 남는다.
  @Test func nonButtonDismissalEndsOnlyEasyPhases() async throws {
    let (store, draft) = try await confirmedDraft()
    let translator = HeldTranslator()
    let launch = try await Launch(store: store, draft: draft, translator: translator)
    let line = try #require(launch.lines.first)
    launch.model.begin(launch.target, lines: [line])
    let consent = try #require(launch.session?.id)
    launch.model.dismissed(launch.target, consent)
    #expect(launch.session == nil, "동의 단계는 쓸어 닫으면 끝난다")

    launch.model.begin(launch.target, lines: [line])
    let session = try #require(launch.session?.id)
    launch.model.dismissed(launch.target, consent)
    #expect(launch.session?.id == session, "이전 시트의 늦은 닫힘 알림은 새 세션을 건드리지 않는다")
    launch.model.confirm(launch.target)
    launch.model.dismissed(launch.target, session)
    #expect(launch.session?.phase == .requesting)
    translator.release([line.originalName: "오늘의 정식"])
    try await until("결과가 와야") { launch.session?.phase == .results }
    launch.model.dismissed(launch.target, session)
    #expect(launch.session?.phase == .results)
    try await until("결과를 남겨야") { try await launch.stored()?.state == .received }
    #expect(translator.calls.count == 1)
  }

  // MARK: - 2. 요청과 결과는 시트보다 오래 산다

  /// 응답을 기다리는 동안 시트를 뷰 계층에서 떼었다가 다시 붙여도 요청은 한 번이고, 받은 결과가 다시 붙인 시트에 그대로 있다.
  @Test func detachingTheSheetWhileWaitingKeepsOneRequestAndItsResult() async throws {
    let (store, draft) = try await confirmedDraft()
    let translator = HeldTranslator()
    let launch = try await Launch(store: store, draft: draft, translator: translator)
    let batch = launch.lines
    #expect(batch.count == 2)
    launch.model.begin(launch.target, lines: batch)
    for line in batch { launch.model.toggle(launch.target, line.id) }
    var (window, _) = try await attach(launch)
    launch.model.confirm(launch.target)
    try await until("요청이 가야") { translator.calls.count == 1 }

    detach(window)
    (window, _) = try await attach(launch)
    detach(window)
    translator.release([batch[0].originalName: "오늘의 정식"])
    try await until("결과가 와야") { launch.session?.phase == .results }
    let sheet: UIViewController
    (window, sheet) = try await attach(launch)
    defer { detach(window) }
    #expect(sheet.isModalInPresentation)
    #expect(translator.calls == [batch.map(\.originalName)], "같은 요청을 다시 보내지 않는다")
    #expect(launch.session?.suggestions == [batch[0].id: "오늘의 정식"])
    #expect(launch.session?.shownLines == batch)
  }

  // MARK: - 3. 프로세스가 종료돼도 받은 결과는 남는다

  /// 받은 결과는 초안 폴더에 남아, 다시 실행해 품목 화면에 들어오면 다시 보인다(다시 보내지 않는다). ‘닫기’로 끝내면 지운다.
  @Test func receivedResultSurvivesRelaunchUntilClosed() async throws {
    let (store, draft) = try await confirmedDraft()
    let first = HeldTranslator()
    let before = try await Launch(store: store, draft: draft, translator: first)
    let batch = before.lines
    before.model.begin(before.target, lines: batch)
    for line in batch { before.model.toggle(before.target, line.id) }
    before.model.confirm(before.target)
    first.release([batch[0].originalName: "오늘의 정식"])
    try await until("결과를 기기에 남겨야") {
      try await before.stored()?.state == .received && before.session?.saving == false
    }
    before.model.accept(before.target, batch[0], "오늘의 정식")
    try await until("적용 표시를 남겨야") { try await before.stored()?.accepted == [batch[0].id: true] }

    let second = HeldTranslator()
    let after = try await Launch(store: store, draft: draft, translator: second)
    #expect(after.plan.line(batch[0].id)?.name == "오늘의 정식", "계획이 먼저 기기에 남았다")
    let restored = try #require(after.session)
    #expect(restored.phase == .results)
    #expect(restored.isBatch)
    #expect(restored.shownLines == batch)
    #expect(restored.suggestions == [batch[0].id: "오늘의 정식"])
    #expect(restored.accepted == [batch[0].id: true])
    #expect(restored.blocksDismissal)
    #expect(second.calls.isEmpty, "다시 보내지 않는다")

    after.model.close(after.target)
    try await until("닫으면 지워야") { try await after.stored() == nil }
    let third = try await Launch(store: store, draft: draft, translator: HeldTranslator())
    #expect(third.session == nil)
  }

  /// 한 줄 결과를 ‘이 이름 사용’으로 적용하면 끝난 것이라 저장분을 지운다.
  @Test func applyingASingleLineResultEndsAndClearsIt() async throws {
    let (store, draft) = try await confirmedDraft()
    let translator = HeldTranslator()
    let launch = try await Launch(store: store, draft: draft, translator: translator)
    let line = try #require(launch.lines.first)
    launch.model.begin(launch.target, lines: [line])
    launch.model.confirm(launch.target)
    translator.release([line.originalName: "오늘의 정식"])
    try await until("결과를 남겨야") { launch.session?.phase == .results && launch.session?.saving == false }
    launch.model.accept(launch.target, line, "오늘의 정식")
    try await until("적용하면 지운 뒤 닫아야") { launch.session == nil }
    #expect(launch.plan.line(line.id)?.name == "오늘의 정식")
    #expect(try await launch.stored() == nil)
  }

  /// 그사이 품목 원문이 바뀌었으면(같은 줄 ID에 다른 원문) 결과를 보이지 않고 지운다.
  @Test func resultIsDiscardedWhenTheOriginalChanged() async throws {
    let (store, draft) = try await confirmedDraft()
    let translator = HeldTranslator()
    let before = try await Launch(store: store, draft: draft, translator: translator)
    let line = try #require(before.lines.first)
    before.model.begin(before.target, lines: [line])
    before.model.confirm(before.target)
    translator.release([line.originalName: "오늘의 정식"])
    try await until("결과를 남겨야") { try await before.stored()?.state == .received }

    let after = try await Launch(store: store, draft: draft, translator: HeldTranslator(), restore: false)
    let encoded = String(decoding: try JSONEncoder().encode(after.plan), as: UTF8.self)
    after.plan = try JSONDecoder().decode(
      ItemPlan.self, from: Data(encoded.replacingOccurrences(of: line.originalName, with: "唐揚げ定食").utf8))
    await after.model.restore(after.target)
    #expect(after.session == nil)
    try await until("버린 결과를 지워야") { try await after.stored() == nil }
  }

  // MARK: - 4. 기다리다 종료되면 다시 보내지 않는다

  /// 응답을 기다리다 앱이 끝나면, 다시 실행했을 때 그 영수증에서 기존 실패 안내(다시 시도)를 보이고 저절로 보내지 않는다.
  /// 다시 보내는 것은 사용자가 ‘다시 시도’ 뒤 다시 확인할 때만이다.
  @Test func waitingRequestCutByRelaunchIsNotResentAndOffersRetry() async throws {
    let (store, draft) = try await confirmedDraft()
    let seed = try await Launch(store: store, draft: draft, translator: HeldTranslator(), restore: false)
    let line = try #require(seed.lines.first)
    try await storeRecord(ItemRetranslationRecord(state: .requested, batch: false, requested: [line]), store, draft)

    let translator = HeldTranslator()
    let launch = try await Launch(store: store, draft: draft, translator: translator)
    #expect(launch.session?.phase == .unavailable)
    #expect(launch.session?.shownLines == [line])
    #expect(launch.session?.blocksDismissal == false)
    #expect(translator.calls.isEmpty, "복원은 보내지 않는다")
    #expect(try await launch.stored()?.state == .requested)

    launch.model.retry(launch.target)
    #expect(launch.session?.phase == .consent)
    #expect(translator.calls.isEmpty, "‘다시 시도’도 보내지 않는다(다시 확인해야 보낸다)")
    launch.model.confirm(launch.target)
    try await until("사용자가 고르면 보내야") { translator.calls.count == 1 }
    translator.release([line.originalName: "오늘의 정식"])
    try await until("결과를 남겨야") { try await launch.stored()?.state == .received }
    #expect(launch.session?.phase == .results)
    #expect(translator.calls.count == 1)
  }

  // MARK: - 정렬 후속(Android와 같게)

  /// 요청 중에는 ‘닫기’를 쓸 수 없고(시트 단추 비활성), 모델의 닫기도 요청과 기록을 지우지 않는다. 응답 뒤에만 ‘닫기’로 마친다.
  @Test func closeIsUnavailableWhileRequesting() async throws {
    let (store, draft) = try await confirmedDraft()
    let translator = HeldTranslator()
    let launch = try await Launch(store: store, draft: draft, translator: translator)
    let line = try #require(launch.lines.first)
    launch.model.begin(launch.target, lines: [line])
    #expect(launch.session?.canClose == true)
    launch.model.confirm(launch.target)
    try await until("요청이 가야") { translator.calls.count == 1 }
    #expect(launch.session?.canClose == false)
    launch.model.close(launch.target)
    #expect(launch.session?.phase == .requesting, "요청 중 닫기는 아무것도 하지 않는다")
    #expect(try await launch.stored()?.state == .requested)
    translator.release([line.originalName: "오늘의 정식"])
    try await until("결과가 와야") { launch.session?.phase == .results }
    #expect(launch.session?.canClose == true)
    launch.model.close(launch.target)
    try await until("닫혀야") { launch.session == nil }
    #expect(try await launch.stored() == nil)
  }

  /// 보내기 전 기록을 쓰지 못하면 보내지 않고 동의 단계에 저장 실패 안내를 둔다. 다시 확인하면 그때 보낸다.
  @Test func requestWaitsForLocalMarkerAndFailureKeepsConsent() async throws {
    let faults = WriteFaults()
    let (store, draft) = try await confirmedDraft(faults: faults)
    let translator = HeldTranslator()
    let launch = try await Launch(store: store, draft: draft, translator: translator)
    let line = try #require(launch.lines.first)
    faults.set(["/retranslations/"])
    launch.model.begin(launch.target, lines: [line])
    launch.model.confirm(launch.target)
    try await until("저장 실패를 알려야") { launch.session?.saveFailed == true }
    #expect(launch.session?.phase == .consent)
    #expect(launch.session?.blocksDismissal == false)
    #expect(translator.calls.isEmpty, "기록 없이 보내지 않는다")
    #expect(try await launch.stored() == nil)

    faults.set([])
    translator.release([line.originalName: "오늘의 정식"])
    launch.model.confirm(launch.target)
    try await until("결과가 와야") { launch.session?.phase == .results }
    #expect(translator.calls.count == 1)
    #expect(launch.session?.saveFailed == false)
    try await until("결과를 남겨야") { try await launch.stored()?.suggestions == [line.id: "오늘의 정식"] }
  }

  /// 받은 결과를 기기에 쓰지 못하면 결과는 메모리에 두고 저장 실패 안내를 보인다. ‘다시 저장’이 성공하면 안내가 사라진다.
  @Test func resultSaveFailureKeepsResultAndRetrySaveStoresIt() async throws {
    let faults = WriteFaults()
    let (store, draft) = try await confirmedDraft(faults: faults)
    let translator = HeldTranslator()
    let launch = try await Launch(store: store, draft: draft, translator: translator)
    let batch = launch.lines
    launch.model.begin(launch.target, lines: batch)
    for line in batch { launch.model.toggle(launch.target, line.id) }
    launch.model.confirm(launch.target)
    try await until("보낸 요청을 남겨야") { try await launch.stored()?.state == .requested }
    faults.set(["/retranslations/"])
    translator.release([batch[0].originalName: "오늘의 정식"])
    try await until("저장 실패를 알려야") { launch.session?.saveFailed == true }
    #expect(launch.session?.phase == .results)
    #expect(launch.session?.suggestions == [batch[0].id: "오늘의 정식"])
    #expect(try await launch.stored()?.state == .requested)

    faults.set([])
    launch.model.retrySave(launch.target)
    try await until("다시 저장해야") { launch.session?.saveFailed == false }
    #expect(try await launch.stored()?.state == .received)
    #expect(translator.calls.count == 1)
  }

  /// 끝낼 때(한 줄 적용, ‘닫기’) 기록을 지우지 못하면 시트를 그대로 두고 저장 실패 안내를 보인다. 다시 하면 끝난다.
  @Test func clearFailureKeepsTheSheetUntilItIsCleared() async throws {
    let faults = WriteFaults()
    let (store, draft) = try await confirmedDraft(faults: faults)
    let translator = HeldTranslator()
    let launch = try await Launch(store: store, draft: draft, translator: translator)
    let line = try #require(launch.lines.first)
    launch.model.begin(launch.target, lines: [line])
    launch.model.confirm(launch.target)
    translator.release([line.originalName: "오늘의 정식"])
    try await until("결과를 남겨야") { launch.session?.phase == .results && launch.session?.saving == false }

    faults.set(["/retranslations/"])
    launch.model.accept(launch.target, line, "오늘의 정식")
    try await until("저장 실패를 알려야") { launch.session?.failure == .clear(ending: true) }
    #expect(launch.plan.line(line.id)?.name == "오늘의 정식")
    #expect(launch.session?.accepted == [line.id: true])
    #expect(try await launch.stored() != nil)
    launch.model.close(launch.target)
    try await until("닫기도 실패를 알려야") { launch.session?.saving == false }
    #expect(launch.session?.saveFailed == true)

    faults.set([])
    launch.model.retrySave(launch.target)
    try await until("끝나야") { launch.session == nil }
    #expect(try await launch.stored() == nil)
  }

  // MARK: - 교차 검토 반영

  /// 실제 앱 모델 경로: 품목 계획(`items/`) 쓰기만 실패하면 적용하지 않은 것으로 본다. 제안과 기록이 그대로 남아
  /// (다시 열어도 고를 수 있다) ‘다시 저장’이 적용을 다시 한다. 계획이 기기에 남은 뒤에만 기록을 지운다.
  @Test func planWriteFailureInTheAppModelKeepsTheSuggestion() async throws {
    let gate = StorageGate()
    let root = root.appending(path: "receipt-import")
    let store = ReceiptDraftStore(root: root, writeFault: { gate.check($0) })
    let draft = try store.create(
      source: .share,
      photos: [IncomingPhoto(fileExtension: "png", content: .data(try Data(contentsOf: Self.itemPhoto)))])
    let seed = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    await seed.run()
    let item = try #require(await seed.snapshot().items.first)
    try await seed.confirm(item.id, fields: try await seed.proposal(item.id).fields, maskLineIDs: [])
    let target = ReviewTarget(draftID: draft.id, itemID: item.id)

    let translator = HeldTranslator()
    let model = try appModel(store, translator)
    await model.load()
    await model.prepareItemPlan(target)
    let line = try #require(model.itemPlans[target]?.retranslatableLines.first)
    let retranslation = model.retranslation
    #expect(retranslation.canBegin(target))
    retranslation.begin(target, lines: [line])
    retranslation.confirm(target)
    translator.release([line.originalName: "오늘의 정식"])
    try await until("결과를 남겨야") {
      retranslation.sessions[target]?.phase == .results && retranslation.sessions[target]?.saving == false
    }

    gate.fail(["/items/"])
    retranslation.accept(target, line, "오늘의 정식")
    try await until("적용 실패를 알려야") {
      retranslation.sessions[target]?.failure == .apply(lineID: line.id, name: "오늘의 정식")
    }
    #expect(retranslation.sessions[target]?.accepted.isEmpty == true)
    let fresh = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    #expect(try await fresh.itemPlan(item.id)?.line(line.id)?.name == "", "기기의 계획은 그대로다")
    let kept = try await fresh.itemRetranslation(item.id)
    #expect(kept?.suggestions == [line.id: "오늘의 정식"])
    #expect(kept?.accepted.isEmpty == true, "다시 열어도 제안을 고를 수 있다")

    gate.fail([])
    retranslation.retrySave(target)
    try await until("적용하고 끝나야") { retranslation.sessions[target] == nil }
    let reopened = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    #expect(try await reopened.itemPlan(item.id)?.line(line.id)?.name == "오늘의 정식")
    #expect(try await reopened.itemRetranslation(item.id) == nil)
  }

  /// 계획에는 적용한 이름이 남았는데 기록을 정리하기 전에 앱이 끝났다. 다시 열면 그 줄을 적용함으로 정리한다(한 줄이면 끝,
  /// 여러 줄이면 남은 줄만 고를 수 있다). 같은 제안을 다시 내밀지 않는다.
  @Test func alreadySavedNameIsNotOfferedAfterInterruptionDuringCleanup() async throws {
    let (store, draft) = try await confirmedDraft()
    let seed = try await Launch(store: store, draft: draft, translator: HeldTranslator(), restore: false)
    let batch = seed.lines
    var plan = seed.plan
    let applied = plan.acceptRetranslation("오늘의 정식", matching: batch[0])
    #expect(applied)
    try await seed.processor.saveItemPlan(seed.target.itemID, plan)

    try await storeRecord(
      ItemRetranslationRecord(
        state: .received, batch: false, requested: [batch[0]], suggestions: [batch[0].id: "오늘의 정식"]), store, draft)
    let single = try await Launch(store: store, draft: draft, translator: HeldTranslator())
    try await until("정리해야") { try await single.stored() == nil }
    #expect(single.session == nil)

    try await storeRecord(
      ItemRetranslationRecord(
        state: .received, batch: true, requested: batch,
        suggestions: [batch[0].id: "오늘의 정식", batch[1].id: "녹차"]), store, draft)
    let many = try await Launch(store: store, draft: draft, translator: HeldTranslator())
    try await until("적용함으로 정리해야") { try await many.stored()?.accepted == [batch[0].id: true] }
    #expect(many.session?.accepted == [batch[0].id: true])
    #expect(many.session?.phase == .results)
  }

  /// 받은 결과를 처음 기기에 쓰는 동안에는 저장 중이라 적용·닫기를 받지 않는다. 쓰기가 끝나면 적용할 수 있다.
  @Test func firstResultWriteBlocksApplyAndClose() async throws {
    let gate = StorageGate()
    let root = root.appending(path: "receipt-import")
    let store = ReceiptDraftStore(root: root, writeFault: { gate.check($0) })
    let draft = try store.create(
      source: .share,
      photos: [IncomingPhoto(fileExtension: "png", content: .data(try Data(contentsOf: Self.itemPhoto)))])
    let seed = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    await seed.run()
    let item = try #require(await seed.snapshot().items.first)
    try await seed.confirm(item.id, fields: try await seed.proposal(item.id).fields, maskLineIDs: [])
    let translator = HeldTranslator()
    let launch = try await Launch(store: store, draft: draft, translator: translator)
    let line = try #require(launch.lines.first)
    launch.model.begin(launch.target, lines: [line])
    launch.model.confirm(launch.target)
    try await until("요청이 가야") { translator.calls.count == 1 }

    gate.hold(["/retranslations/"])
    translator.release([line.originalName: "오늘의 정식"])
    try await until("결과 쓰기가 붙잡혀야") { gate.waiting.contains("/retranslations/") }
    #expect(launch.session?.phase == .results)
    #expect(launch.session?.saving == true)
    #expect(launch.session?.canClose == false)
    #expect(launch.session?.blocksDismissal == true)
    launch.model.accept(launch.target, line, "오늘의 정식")
    launch.model.close(launch.target)
    #expect(launch.plan.line(line.id)?.name == "", "저장 중에는 적용하지 않는다")

    gate.hold([])
    try await until("결과를 남겨야") { launch.session?.saving == false }
    #expect(launch.session?.phase == .results)
    #expect(try await launch.stored()?.state == .received)
    launch.model.accept(launch.target, line, "오늘의 정식")
    try await until("적용하고 끝나야") { launch.session == nil }
  }

  /// 그 영수증의 기록을 다 읽기 전에는 새 재번역을 시작하지 않는다. 읽지 못하면 파일을 두고 다시 읽을 수 있다.
  @Test func newRetranslationWaitsForRestoreAndReadFailureCanBeRetried() async throws {
    let gate = StorageGate()
    let reads = StorageGate()
    let root = root.appending(path: "receipt-import")
    let store = ReceiptDraftStore(root: root, writeFault: { gate.check($0) }, readFault: { reads.check($0) })
    let draft = try store.create(
      source: .share,
      photos: [IncomingPhoto(fileExtension: "png", content: .data(try Data(contentsOf: Self.itemPhoto)))])
    let seed = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    await seed.run()
    let item = try #require(await seed.snapshot().items.first)
    try await seed.confirm(item.id, fields: try await seed.proposal(item.id).fields, maskLineIDs: [])
    let first = try await Launch(store: store, draft: draft, translator: HeldTranslator(), restore: false)
    let line = try #require(first.lines.first)
    let saved = ItemRetranslationRecord(
      state: .received, batch: false, requested: [line], suggestions: [line.id: "오늘의 정식"])
    try await storeRecord(saved, store, draft)

    let launch = try await Launch(store: store, draft: draft, translator: HeldTranslator(), restore: false)
    #expect(!launch.model.canBegin(launch.target), "복원 전에는 시작하지 않는다")
    reads.fail(["/retranslations/"])
    await launch.model.restore(launch.target)
    #expect(launch.model.restores[launch.target] == .failed)
    launch.model.begin(launch.target, lines: [line])
    #expect(launch.session == nil, "읽지 못했으면 시작하지 않는다")
    reads.fail([])
    #expect(try await launch.stored() == saved, "파일은 그대로다")

    reads.hold(["/retranslations/"])
    let restoring = Task { await launch.model.restore(launch.target) }
    try await until("읽기가 붙잡혀야") { reads.waiting.contains("/retranslations/") }
    #expect(launch.model.restores[launch.target] == .restoring)
    launch.model.begin(launch.target, lines: [line])
    #expect(launch.session == nil, "읽는 동안에는 시작하지 않는다")
    reads.hold([])
    await restoring.value
    #expect(launch.session?.suggestions == [line.id: "오늘의 정식"])
    #expect(launch.model.restores[launch.target] == .done)
  }

  /// 적용 검사에 실패하면(원문은 같고 이름이 바뀜) 결과 단계에 그 줄의 변경 안내를 두고 기록을 남긴다. ‘닫기’로만 지운다.
  @Test func rejectedApplyKeepsTheResultUntilClosed() async throws {
    let (store, draft) = try await confirmedDraft()
    let translator = HeldTranslator()
    let launch = try await Launch(store: store, draft: draft, translator: translator)
    let line = try #require(launch.lines.first)
    launch.model.begin(launch.target, lines: [line])
    launch.model.confirm(launch.target)
    translator.release([line.originalName: "오늘의 정식"])
    try await until("결과를 남겨야") { launch.session?.phase == .results && launch.session?.saving == false }

    launch.plan.setName(line.id, "직접 적은 이름")
    try await launch.processor.saveItemPlan(launch.target.itemID, launch.plan)
    launch.model.accept(launch.target, line, "오늘의 정식")
    try await until("변경 안내를 남겨야") { try await launch.stored()?.accepted == [line.id: false] }
    #expect(launch.session?.phase == .results)
    #expect(launch.session?.accepted == [line.id: false])
    #expect(launch.session?.blocksDismissal == true)
    #expect(launch.plan.line(line.id)?.name == "직접 적은 이름")

    let after = try await Launch(store: store, draft: draft, translator: HeldTranslator())
    #expect(after.session?.phase == .results)
    #expect(after.session?.accepted == [line.id: false])
    after.model.close(after.target)
    try await until("닫으면 지워야") { try await after.stored() == nil }
  }

  /// 보낸다는 기록을 쓰는 동안 줄이 바뀌면 보내지 않고 변경 안내를 보이며 기록을 지운다.
  @Test func lineChangedWhileTheMarkerIsWrittenIsNotSent() async throws {
    let gate = StorageGate()
    let root = root.appending(path: "receipt-import")
    let store = ReceiptDraftStore(root: root, writeFault: { gate.check($0) })
    let draft = try store.create(
      source: .share,
      photos: [IncomingPhoto(fileExtension: "png", content: .data(try Data(contentsOf: Self.itemPhoto)))])
    let seed = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    await seed.run()
    let item = try #require(await seed.snapshot().items.first)
    try await seed.confirm(item.id, fields: try await seed.proposal(item.id).fields, maskLineIDs: [])
    let translator = HeldTranslator()
    let launch = try await Launch(store: store, draft: draft, translator: translator)
    let line = try #require(launch.lines.first)
    launch.model.begin(launch.target, lines: [line])
    gate.hold(["/retranslations/"])
    launch.model.confirm(launch.target)
    try await until("기록 쓰기가 붙잡혀야") { gate.waiting.contains("/retranslations/") }
    launch.plan.setName(line.id, "기기 번역 이름")
    gate.hold([])
    try await until("변경 안내로 가야") { launch.session?.phase == .changed && launch.session?.saving == false }
    #expect(translator.calls.isEmpty, "바뀐 줄은 보내지 않는다")
    #expect(try await launch.stored() == nil)
  }

  /// 번역 응답이 상한 안에 오지 않거나 취소 예외로 끝나도 세션이 살아 있으면 받지 못한 것으로 알린다(요청 단계에 갇히지 않는다).
  @Test func timeoutAndCancellationEndInTheFailureNotice() async throws {
    let (store, draft) = try await confirmedDraft()
    let slow = HeldTranslator()
    let launch = try await Launch(store: store, draft: draft, translator: slow, timeout: .milliseconds(300))
    let line = try #require(launch.lines.first)
    launch.model.begin(launch.target, lines: [line])
    launch.model.confirm(launch.target)
    try await until("상한을 넘기면 실패 안내여야") {
      launch.session?.phase == .unavailable && launch.session?.saving == false
    }
    #expect(slow.calls.count == 1)
    #expect(try await launch.stored() == nil)

    let cancelled = HeldTranslator()
    let other = try await Launch(store: store, draft: draft, translator: cancelled)
    other.model.begin(other.target, lines: [line])
    other.model.confirm(other.target)
    try await until("요청이 가야") { cancelled.calls.count == 1 }
    cancelled.cancel()
    try await until("취소도 실패 안내여야") { other.session?.phase == .unavailable }
  }

  // MARK: - 두 앱 차이 정렬(Android와 같게)

  /// 실제 앱 모델 경로: 풀 수 없는(손상된) 기록은 지우지 않고 “번역 제안을 받지 못했어요”와 ‘다시 시도’를 보인다. 파일은
  /// 사용자가 닫을 때까지 남고, ‘다시 시도’ 뒤 새 요청이 보내기 전 표시로 덮는다. 저절로 보내지 않는다.
  @Test func malformedRecordShowsFailureAndKeepsTheFileUntilClosedOrOverwritten() async throws {
    let root = root.appending(path: "receipt-import")
    let store = ReceiptDraftStore(root: root)
    let draft = try store.create(
      source: .share,
      photos: [IncomingPhoto(fileExtension: "png", content: .data(try Data(contentsOf: Self.itemPhoto)))])
    let seed = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    await seed.run()
    let item = try #require(await seed.snapshot().items.first)
    try await seed.confirm(item.id, fields: try await seed.proposal(item.id).fields, maskLineIDs: [])
    let target = ReviewTarget(draftID: draft.id, itemID: item.id)
    let file = root.appending(path: "drafts/\(draft.id)/retranslations/\(item.id).json")
    func corrupt() throws {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("{\"state\":".utf8).write(to: file)
    }

    try corrupt()
    let translator = HeldTranslator()
    let model = try appModel(store, translator)
    await model.load()
    await model.prepareItemPlan(target)
    let retranslation = model.retranslation
    let lines = try #require(model.itemPlans[target]?.retranslatableLines)
    #expect(retranslation.restores[target] == .done)
    #expect(retranslation.sessions[target]?.phase == .unavailable, "손상된 기록은 받지 못한 것으로 보인다")
    #expect(retranslation.sessions[target]?.candidates == lines)
    #expect(!retranslation.canBegin(target), "열린 안내가 있으면 새로 시작하지 않는다")
    #expect(FileManager.default.fileExists(atPath: file.path), "닫기 전에는 파일을 남긴다")
    #expect(translator.calls.isEmpty)
    var (window, sheet) = try await attach(retranslation, target)
    #expect(Self.labels(sheet).contains("번역 제안을 받지 못했어요. 이름을 직접 적거나 다시 시도해 주세요."))
    #expect(Self.labels(sheet).contains("다시 시도"))
    #expect(!sheet.isModalInPresentation, "실패 안내는 쉽게 닫힌다")

    retranslation.close(target)
    try await until("닫으면 끝나야") { retranslation.sessions[target] == nil }
    detach(window)
    #expect(!FileManager.default.fileExists(atPath: file.path), "닫으면 지운다")

    try corrupt()
    let relaunched = try appModel(store, translator)
    await relaunched.load()
    await relaunched.prepareItemPlan(target)
    let again = relaunched.retranslation
    #expect(again.sessions[target]?.phase == .unavailable)
    (window, sheet) = try await attach(again, target)
    defer { detach(window) }
    try await until("‘다시 시도’를 눌러야") { Self.press("다시 시도", in: sheet) }
    try await until("동의 단계로 가야") { again.sessions[target]?.phase == .consent }
    #expect(FileManager.default.fileExists(atPath: file.path), "다시 시도만으로는 지우지 않는다")
    for line in lines { again.toggle(target, line.id) }
    again.confirm(target)
    try await until("새 요청이 가야") { translator.calls.count == 1 }
    let marker = try await ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
      .itemRetranslation(item.id)
    #expect(marker?.state == .requested)
    #expect(marker?.requested == lines)
  }

  /// 실제 앱 모델과 시트: 기록 삭제 실패의 단추는 ‘다시 시도’이고(‘다시 저장’이 아니다), 누르면 삭제를 다시 한다. 실패·변경
  /// 안내 단계에서도 같고, 그때는 단계의 ‘다시 시도’를 함께 보이지 않는다(같은 이름의 단추가 둘이 되지 않게).
  @Test func clearFailureOffersRetryThatDeletesAgain() async throws {
    let gate = StorageGate()
    let root = root.appending(path: "receipt-import")
    let store = ReceiptDraftStore(root: root, writeFault: { gate.check($0) })
    let draft = try store.create(
      source: .share,
      photos: [IncomingPhoto(fileExtension: "png", content: .data(try Data(contentsOf: Self.itemPhoto)))])
    let seed = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    await seed.run()
    let item = try #require(await seed.snapshot().items.first)
    try await seed.confirm(item.id, fields: try await seed.proposal(item.id).fields, maskLineIDs: [])
    let target = ReviewTarget(draftID: draft.id, itemID: item.id)
    let file = root.appending(path: "drafts/\(draft.id)/retranslations/\(item.id).json")

    let translator = HeldTranslator()
    let model = try appModel(store, translator)
    await model.load()
    await model.prepareItemPlan(target)
    let retranslation = model.retranslation
    let line = try #require(model.itemPlans[target]?.retranslatableLines.first)
    retranslation.begin(target, lines: [line])
    retranslation.confirm(target)
    translator.release([line.originalName: "오늘의 정식"])
    try await until("결과를 남겨야") {
      retranslation.sessions[target]?.phase == .results && retranslation.sessions[target]?.saving == false
    }
    gate.fail(["/retranslations/"])
    retranslation.close(target)
    try await until("삭제 실패를 알려야") { retranslation.sessions[target]?.failure == .clear(ending: true) }
    let (window, resultsSheet) = try await attach(retranslation, target)
    defer { detach(window) }
    try await until("삭제 실패 단추는 ‘다시 시도’여야") { Self.labels(resultsSheet).contains("다시 시도") }
    #expect(Self.labels(resultsSheet).contains("품목을 기기에 저장하지 못했어요."))
    #expect(!Self.labels(resultsSheet).contains("다시 저장"), "‘다시 저장’은 결과 저장과 적용 실패에만 쓴다")
    gate.fail([])
    try await until("‘다시 시도’를 눌러야") { Self.press("다시 시도", in: resultsSheet) }
    // 모델 세션이 끝난 뒤 SwiftUI의 시트 닫힘도 완료되어야 다음 시트를 열 수 있다.
    try await until("다시 지우고 결과 시트가 닫혀야") {
      retranslation.sessions[target] == nil && window.rootViewController?.presentedViewController == nil
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))

    // 받지 못한 응답: 실패 안내 단계에서 보내기 전 표시를 지우지 못했다.
    translator.hold()
    retranslation.begin(target, lines: [line])
    retranslation.confirm(target)
    try await until("요청이 가야") { translator.calls.count == 2 }
    gate.fail(["/retranslations/"])
    translator.release([:])
    try await until("실패 안내에서 삭제 실패를 알려야") {
      retranslation.sessions[target]?.phase == .unavailable
        && retranslation.sessions[target]?.failure == .clear(ending: false)
    }
    let failureSheet = try await presentedSheet(in: window)
    try await until("삭제 실패의 ‘다시 시도’만 보여야") {
      let labels = Self.labels(failureSheet)
      return labels.filter { $0 == "다시 시도" }.count == 1 && !labels.contains("다시 저장")
    }
    #expect(FileManager.default.fileExists(atPath: file.path))
    gate.fail([])
    try await until("‘다시 시도’를 눌러야") { Self.press("다시 시도", in: failureSheet) }
    try await until("다시 지워야") {
      retranslation.sessions[target]?.failure == nil && retranslation.sessions[target]?.saving == false
    }
    #expect(retranslation.sessions[target]?.phase == .unavailable)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(translator.calls.count == 2, "지우기를 다시 해도 보내지 않는다")
  }

  /// 실제 앱 모델과 시트(계약 3, Android와 같게): 기록 삭제 실패가 남아 있으면 실패·변경 안내 단계라도 쓸어 닫기를 막는다
  /// (`isModalInPresentation`). 단추가 아닌 닫힘 알림도 무시하고, ‘다시 시도’나 ‘닫기’로만 끝낸다.
  @Test func clearFailureBlocksSwipeUntilRetriedOrClosed() async throws {
    let gate = StorageGate()
    let root = root.appending(path: "receipt-import")
    let store = ReceiptDraftStore(root: root, writeFault: { gate.check($0) })
    let draft = try store.create(
      source: .share,
      photos: [IncomingPhoto(fileExtension: "png", content: .data(try Data(contentsOf: Self.itemPhoto)))])
    let seed = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    await seed.run()
    let item = try #require(await seed.snapshot().items.first)
    try await seed.confirm(item.id, fields: try await seed.proposal(item.id).fields, maskLineIDs: [])
    let target = ReviewTarget(draftID: draft.id, itemID: item.id)
    let file = root.appending(path: "drafts/\(draft.id)/retranslations/\(item.id).json")

    let translator = HeldTranslator()
    let model = try appModel(store, translator)
    await model.load()
    await model.prepareItemPlan(target)
    let retranslation = model.retranslation
    let line = try #require(model.itemPlans[target]?.retranslatableLines.first)
    retranslation.begin(target, lines: [line])
    retranslation.confirm(target)
    try await until("요청이 가야") { translator.calls.count == 1 }
    gate.fail(["/retranslations/"])
    translator.release([:])
    try await until("실패 안내에서 삭제 실패를 알려야") {
      retranslation.sessions[target]?.failure == .clear(ending: false)
        && retranslation.sessions[target]?.saving == false
    }
    let session = try #require(retranslation.sessions[target])
    #expect(session.phase == .unavailable)
    #expect(session.blocksDismissal, "삭제 실패가 남아 있으면 쓸어 닫지 않는다")
    let (window, sheet) = try await attach(retranslation, target)
    defer { detach(window) }
    try await until("시트가 쓸기를 막아야") { sheet.isModalInPresentation }
    try await until("‘닫기’는 눌려야") { closeEnabled(sheet) == true }
    retranslation.dismissed(target, session.id)
    #expect(retranslation.sessions[target]?.failure == .clear(ending: false), "단추가 아닌 닫힘은 무시한다")
    #expect(FileManager.default.fileExists(atPath: file.path))

    retranslation.close(target)
    try await until("닫기도 실패를 알려야") {
      retranslation.sessions[target]?.failure == .clear(ending: true)
        && retranslation.sessions[target]?.saving == false
    }
    #expect(sheet.isModalInPresentation)
    gate.fail([])
    retranslation.close(target)
    try await until("‘닫기’로 지우고 끝나야") { retranslation.sessions[target] == nil }
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  /// 쉽게 닫히는 단계를 쓸어 닫으면 세션을 끝내고 기록을 지운다. 지우지 못해도 닫힌 시트를 다시 띄우지 않는다. 파일은 남아
  /// 다음에 품목 화면에 들어올 때 다시 보인다(새 요청이 덮을 수도 있다).
  @Test func swipeDismissalDoesNotReshowWhenItsDeleteFails() async throws {
    let gate = StorageGate()
    let root = root.appending(path: "receipt-import")
    let store = ReceiptDraftStore(root: root, writeFault: { gate.check($0) })
    let draft = try store.create(
      source: .share,
      photos: [IncomingPhoto(fileExtension: "png", content: .data(try Data(contentsOf: Self.itemPhoto)))])
    let seed = try ReceiptProcessor(store: store, draft: draft, recognizer: RowsRecognizer())
    await seed.run()
    let item = try #require(await seed.snapshot().items.first)
    try await seed.confirm(item.id, fields: try await seed.proposal(item.id).fields, maskLineIDs: [])
    let target = ReviewTarget(draftID: draft.id, itemID: item.id)
    let file = root.appending(path: "drafts/\(draft.id)/retranslations/\(item.id).json")
    let line = try #require(try await seed.itemPlan(item.id)?.retranslatableLines.first)
    try await seed.saveItemRetranslation(
      item.id, ItemRetranslationRecord(state: .requested, batch: false, requested: [line]))

    let model = try appModel(store, HeldTranslator())
    await model.load()
    await model.prepareItemPlan(target)
    let retranslation = model.retranslation
    let session = try #require(retranslation.sessions[target])
    #expect(session.phase == .unavailable)
    #expect(!session.blocksDismissal)

    gate.fail(["/retranslations/"])
    gate.hold(["/retranslations/"])
    retranslation.dismissed(target, session.id)
    #expect(retranslation.sessions[target] == nil)
    try await until("지우기를 시도해야") { gate.waiting.contains("/retranslations/") }
    gate.hold([])
    try await Task.sleep(for: .milliseconds(300))
    #expect(retranslation.sessions[target] == nil, "쓸어 닫은 시트를 다시 띄우지 않는다")
    #expect(FileManager.default.fileExists(atPath: file.path))

    gate.fail([])
    let relaunched = try appModel(store, HeldTranslator())
    await relaunched.load()
    await relaunched.prepareItemPlan(target)
    #expect(relaunched.retranslation.sessions[target]?.phase == .unavailable, "남은 기록은 다음에 다시 보인다")
  }

  private func appModel(_ store: ReceiptDraftStore, _ translator: HeldTranslator) throws -> AppModel {
    let auth = SignedOutAuth()
    let trips = ProposalFlowTests.Trips(
      RoomLedger(
        tripID: TripID(value: "t"), name: "가상", isFinalized: false, revision: 1, isHost: true,
        me: MemberID(value: "h"), members: [], expenses: []))
    var graph = AppGraph(
      auth: auth, trips: trips, settlement: UnavailableSettlementGateway(), drafts: store,
      joinFlow: JoinFlow(
        auth: auth, trips: trips, pendingInvites: PendingInviteStore(file: root.appending(path: "invite.json"))),
      recognizer: RowsRecognizer(), processingHooks: ProcessingHooks())
    graph.previewRetranslation = translator.translate
    return AppModel(graph: graph)
  }

  final class SignedOutAuth: AuthGateway, @unchecked Sendable {
    var providers: [SignInProvider] { [.apple] }
    var testOnlyNotice: String? { nil }
    func restoreSession() async -> AccountSession? { nil }
    func signIn(with provider: SignInProvider) async throws -> AccountSession { throw SignInFailure.unavailable }
    func endSession() async {}
  }
}
