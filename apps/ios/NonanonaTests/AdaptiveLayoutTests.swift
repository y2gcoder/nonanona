import Foundation
import ReceiptImport
import SwiftUI
import Testing
import UIKit

@testable import Nonanona

/// 창 크기·접기·회전이 바뀌어도 화면 상태가 남고, 넓은 창의 내용이 읽기 좋은 폭과 접힘을 지키는지 본다.
/// 실제 접기(자세)는 시뮬레이터 GUI로만 바꿀 수 있어, 여기서는 같은 신호(크기 종류, 크기, 예약 영역, 장면 다시 활성화)를 직접 준다.
struct ContentMarginsTests {
  @Test func narrowWindowKeepsFullWidth() {
    #expect(ContentMargins.fitting(width: 402, divisions: []) == ContentMargins())
    #expect(ContentMargins.fitting(width: 640, divisions: []) == ContentMargins())
  }

  @Test func wideWindowCentersReadableWidth() {
    #expect(ContentMargins.fitting(width: 1000, divisions: []) == ContentMargins(leading: 180, trailing: 180))
  }

  /// 세로 접힘이 가운데를 가로지르면 내용은 한쪽(같으면 앞쪽)에만 있고 접힘 영역과 겹치지 않는다.
  @Test func verticalFoldKeepsContentOnOneSide() {
    // 양쪽이 324pt로 같으면 앞쪽.
    let fold = CGRect(x: 324, y: 0, width: 21, height: 951)
    #expect(ContentMargins.fitting(width: 669, divisions: [fold]) == ContentMargins(leading: 0, trailing: 345))

    let offCenter = CGRect(x: 200, y: 0, width: 20, height: 951)
    let right = ContentMargins.fitting(width: 669, divisions: [offCenter])
    #expect(right == ContentMargins(leading: 220, trailing: 0))
  }

  @Test func foldOutsideTheViewIsIgnored() {
    let fold = CGRect(x: 700, y: 0, width: 20, height: 900)
    #expect(ContentMargins.fitting(width: 600, divisions: [fold]) == ContentMargins())
  }

  /// 가로 접힘(노트북 자세)을 지나는 스크롤 목록은 어디에 두어도 접힘을 지나므로 폭을 바꾸지 않는다.
  @Test func horizontalFoldDoesNotNarrowScrollingContent() {
    let fold = CGRect(x: 0, y: 330, width: 951, height: 20)
    #expect(ContentMargins.fitting(width: 951, divisions: [fold]) == ContentMargins(leading: 155.5, trailing: 155.5))
  }
}

/// 호출 수를 세는 OCR. 같은 사진을 두 번 읽으면 중복 처리다.
private final class CountingRecognizer: ReceiptRecognizer, @unchecked Sendable {
  private let lock = NSLock()
  private let inner = VisionReceiptRecognizer()
  private var count = 0
  var calls: Int { lock.withLock { count } }

  func recognize(_ url: URL) throws -> OCRResult {
    lock.withLock { count += 1 }
    return try inner.recognize(url)
  }
}

private final class SignedInAuth: AuthGateway, @unchecked Sendable {
  var providers: [SignInProvider] { [.apple] }
  var testOnlyNotice: String? { nil }
  func restoreSession() async -> AccountSession? {
    AccountSession(accountID: AccountID(value: "account-1"), displayName: "가나")
  }
  func signIn(with provider: SignInProvider) async throws(SignInFailure) -> AccountSession {
    AccountSession(accountID: AccountID(value: "account-1"), displayName: "가나")
  }
  func endSession() async {}
}

/// 초대 코드마다 다른 가상 여행방을 돌려주고, 올린 요청을 센다.
private final class RecordingTrips: TripGateway, @unchecked Sendable {
  private let lock = NSLock()
  private var submitted: [TripID] = []
  var submissions: [TripID] { lock.withLock { submitted } }

  func acceptInvite(_ code: InviteCode) async throws(InviteAcceptFailure) -> TripRoom {
    TripRoom(id: TripID(value: "trip-\(code.value)"), name: "가상 \(code.value)", members: [])
  }
  func submitReceipt(_ upload: ReceiptExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
    lock.withLock { submitted.append(trip) }
    return SubmittedExpense(expenseID: "expense-\(upload.requestID)", replayed: false)
  }
}

private let fixtures = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "fixtures/receipts")

@MainActor
private func until(_ what: String, timeout: Duration = .seconds(60), _ condition: () -> Bool) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while !condition() {
    guard clock.now < deadline else {
      Issue.record("시간 안에 \(what) 되지 않았다")
      throw CancellationError()
    }
    try await Task.sleep(for: .milliseconds(50))
  }
}

@MainActor
struct AdaptiveStateTests {
  private let root = FileManager.default.temporaryDirectory.appending(path: "adaptive-\(UUID().uuidString)")
  private let recognizer = CountingRecognizer()
  private let trips = RecordingTrips()

  private func model(faults: WriteFaults? = nil) throws -> (AppModel, ReceiptDraft) {
    var fault: (@Sendable (URL) -> Bool)?
    if let faults { fault = { url in faults.shouldFail(url) } }
    let drafts = ReceiptDraftStore(root: root.appending(path: "receipt-import"), writeFault: fault)
    let photos = try ["receipt-r01.png", "receipt-r02.png"].map {
      IncomingPhoto(fileExtension: "png", content: .data(try Data(contentsOf: fixtures.appending(path: $0))))
    }
    let draft = try drafts.list().first ?? drafts.create(source: .share, photos: photos)
    let auth = SignedInAuth()
    let graph = AppGraph(
      auth: auth, trips: trips, drafts: drafts,
      joinFlow: JoinFlow(
        auth: auth, trips: trips, pendingInvites: PendingInviteStore(file: root.appending(path: "invite.json"))),
      recognizer: recognizer, processingHooks: ProcessingHooks())
    return (AppModel(graph: graph), draft)
  }

  /// 접기·펴기로 앱이 다른 화면으로 옮겨 가면 장면이 다시 활성화되어 `reloadDrafts()`가 불린다.
  /// 처리 중에 여러 번 불려도 사진마다 OCR은 한 번이고, 고른 초안(안정 ID)은 그대로다.
  @Test func sceneReactivationDuringProcessingDoesNotRepeatOCR() async throws {
    let (model, draft) = try model()
    await model.load()
    model.selection = .draft(draft.id)
    for _ in 0..<5 {
      model.reloadDrafts()
      try await Task.sleep(for: .milliseconds(20))
    }
    try await until("두 장 처리가") { model.processing[draft.id]?.processedCount == 2 }
    model.reloadDrafts()
    try await Task.sleep(for: .milliseconds(200))

    #expect(recognizer.calls == 2)
    #expect(model.processing[draft.id]?.items.map(\.attempts) == [1, 1])
    #expect(model.selection == .draft(draft.id))
  }

  /// 최종 확인은 모델에 있어 화면이 다시 그려져도 같은 올릴 곳·장수를 묻는다. 올리기는 한 번만 간다.
  @Test func uploadConfirmationKeepsDestinationAndUploadsOnce() async throws {
    let (model, draft) = try model()
    await model.load()
    try await until("처리가") { model.processing[draft.id]?.processedCount == 2 }
    let ready = try #require(model.processing[draft.id]?.items.first { $0.state == .ready })
    model.debugConfirmWithSuggestions(draftID: draft.id, itemID: ready.id)
    try await until("확인이") { model.confirmedCount(draftID: draft.id) == 1 }

    await model.requestUpload(draftID: draft.id)
    #expect(model.uploadConfirmation == nil, "참여한 여행방이 없으면 확인을 열지 않는다")

    model.handle(url: URL(string: "nonanona://invite/SYNTHTRIPA01")!)
    await model.joinPendingInvite()
    model.selection = .draft(draft.id)
    await model.requestUpload(draftID: draft.id)
    let asked = try #require(model.uploadConfirmation)
    #expect(asked.draftID == draft.id && asked.tripID == TripID(value: "trip-SYNTHTRIPA01"))
    #expect(asked.tripName == "가상 SYNTHTRIPA01" && asked.count == 1)
    #expect(asked.receipts.map(\.itemID) == [ready.id], "동의한 영수증의 사진 ID·사본 해시·값을 담는다")

    // 화면 배치가 바뀌는 동안 모델 값은 그대로다(같은 확인을 다시 그린다).
    model.reloadDrafts()
    #expect(model.uploadConfirmation == asked)

    model.confirmUpload(asked)
    try await until("올리기가") { model.uploads[draft.id] == .done(created: 1, replayed: 0) }
    #expect(trips.submissions == [TripID(value: "trip-SYNTHTRIPA01")])
    #expect(model.uploadConfirmation == nil)
  }

  /// 확인 창이 열린 사이 다른 초대로 올릴 곳이 바뀌면, 예전 확인으로는 아무것도 올리지 않는다.
  @Test func staleConfirmationForAnotherDestinationUploadsNothing() async throws {
    let (model, draft) = try model()
    await model.load()
    try await until("처리가") { model.processing[draft.id]?.processedCount == 2 }
    let ready = try #require(model.processing[draft.id]?.items.first { $0.state == .ready })
    model.debugConfirmWithSuggestions(draftID: draft.id, itemID: ready.id)
    try await until("확인이") { model.confirmedCount(draftID: draft.id) == 1 }
    model.handle(url: URL(string: "nonanona://invite/SYNTHTRIPA01")!)
    await model.joinPendingInvite()
    await model.requestUpload(draftID: draft.id)
    let asked = try #require(model.uploadConfirmation)

    model.handle(url: URL(string: "nonanona://invite/SYNTHTRIPB01")!)
    #expect(model.uploadConfirmation == nil)
    await model.joinPendingInvite()
    model.confirmUpload(asked)
    try await Task.sleep(for: .milliseconds(300))

    #expect(trips.submissions.isEmpty)
    #expect(model.uploads[draft.id] == nil)
  }

  /// 검토 중인 영수증과 고치던 값은 모델에 있어 분할 보기가 접히고 펴져도 남는다. "확인하고 다음"은 목록 순서로 다음 사진을 열고,
  /// 남은 사진이 없으면 목록으로 돌아간다. 확인한 값은 고친 값이다.
  @Test func reviewSurvivesWidthChangesAndConfirmAdvancesInOrder() async throws {
    let (model, draft) = try model()
    await model.load()
    try await until("처리가") { model.processing[draft.id]?.processedCount == 2 }
    model.selection = .draft(draft.id)
    model.startReview(draftID: draft.id)
    let items = try #require(model.processing[draft.id]?.items.sorted { $0.position < $1.position })
    let first = ReviewTarget(draftID: draft.id, itemID: items[0].id)
    #expect(model.reviewing == first, "목록 순서의 첫 확인 필요 사진")
    try await until("제안이") { model.proposals[first] != nil }
    model.edit(first, .amount("1500"))
    model.edit(first, .addRegion)

    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 951, height: 669))
    window.rootViewController = UIHostingController(rootView: RootView(model: model))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    for (sizeClass, size) in [
      (UIUserInterfaceSizeClass.regular, CGSize(width: 951, height: 669)),
      (.compact, CGSize(width: 466, height: 678)),
      (.regular, CGSize(width: 951, height: 669)),
    ] {
      window.frame = CGRect(origin: .zero, size: size)
      window.traitOverrides.horizontalSizeClass = sizeClass
      try await until("분할 보기가 바뀌기가", timeout: .seconds(5)) {
        splitViewController(in: window)?.isCollapsed == (sizeClass == .compact)
      }
      #expect(model.reviewing == first)
      #expect(model.resolvedReview(first).amount == "1500")
      #expect(model.resolvedReview(first).regions.count == 1)
    }

    await model.confirmAndNext(first)
    let second = ReviewTarget(draftID: draft.id, itemID: items[1].id)
    #expect(model.reviewing == second)
    #expect(model.item(first)?.confirmed?.fields.amountMinor == 1500)
    try await until("다음 제안이") { model.proposals[second] != nil }
    await model.confirmAndNext(second)
    #expect(model.reviewing == nil, "남은 확인 필요 사진이 없으면 목록으로")
    #expect(model.reviewFinished.contains(draft.id))
    #expect(recognizer.calls == 2, "검토와 배치 변경이 OCR을 다시 돌리지 않는다")
  }

  /// 최종 확인 뒤 올릴 영수증이 바뀌면(다른 영수증을 더 확인) 동의한 것과 달라 아무것도 보내지 않는다.
  @Test func shareConsentSnapshotRejectsChangedContentAndSendsNothing() async throws {
    let (model, draft) = try model()
    await model.load()
    try await until("처리가") { model.processing[draft.id]?.processedCount == 2 }
    let items = try #require(model.processing[draft.id]?.items.sorted { $0.position < $1.position })
    model.debugConfirmWithSuggestions(draftID: draft.id, itemID: items[0].id)
    try await until("확인이") { model.confirmedCount(draftID: draft.id) == 1 }
    model.handle(url: URL(string: "nonanona://invite/SYNTHTRIPA01")!)
    await model.joinPendingInvite()
    await model.requestUpload(draftID: draft.id)
    let asked = try #require(model.uploadConfirmation)
    #expect(asked.count == 1)

    model.debugConfirmWithSuggestions(draftID: draft.id, itemID: items[1].id)
    try await until("두 번째 확인이") { model.confirmedCount(draftID: draft.id) == 2 }
    model.confirmUpload(asked)
    try await until("거절이") { model.uploads[draft.id] == .contentChanged }
    #expect(trips.submissions.isEmpty, "동의하지 않은 내용은 하나도 보내지 않는다")

    // 다시 확인하면 지금 내용(2장)으로 묻고, 그대로 보낸다.
    await model.requestUpload(draftID: draft.id)
    let again = try #require(model.uploadConfirmation)
    #expect(again.count == 2)
    model.confirmUpload(again)
    try await until("올리기가") { model.uploads[draft.id] == .done(created: 2, replayed: 0) }
  }

  /// 저장 실패: 입력 저장이 실패하면 알리고 메모리 입력은 남는다. 확인을 디스크에 쓰지 못하면 확인되지 않고,
  /// 선택·입력이 그대로이며 다음 사진으로 가지 않는다. 앱을 다시 열면 마지막으로 쓴 입력과 확인 전 상태다.
  @Test func storageFailuresAreSurfacedAndNothingIsExposedUntilDurable() async throws {
    let faults = WriteFaults()
    let (model, draft) = try model(faults: faults)
    await model.load()
    try await until("처리가") { model.processing[draft.id]?.processedCount == 2 }
    model.selection = .draft(draft.id)
    model.startReview(draftID: draft.id)
    let first = try #require(model.reviewing)
    try await until("제안이") { model.proposals[first] != nil }
    model.edit(first, .amount("1500"))
    try await Task.sleep(for: .milliseconds(200))

    faults.set(["reviews/"])
    model.edit(first, .amount("1600"))
    try await until("저장 실패 안내가") { model.draftSaveFailed.contains(first) }
    #expect(model.resolvedReview(first).amount == "1600", "메모리 입력은 남는다")

    faults.set(["processing.json"])
    await model.confirmAndNext(first)
    #expect(model.confirmFailed.contains(first))
    #expect(model.reviewing == first, "다음 사진으로 가지 않는다")
    #expect(model.item(first)?.state == .ready)
    #expect(model.resolvedReview(first).amount == "1600")
    #expect(model.reviewFinished.isEmpty)

    // 앱을 다시 연다: 디스크에는 확인 전 상태와 마지막으로 쓴 입력(1500)이 있다.
    faults.set([])
    let (reopened, _) = try self.model(faults: faults)
    await reopened.load()
    try await until("다시 연 처리 상태가") { reopened.processing[draft.id] != nil }
    #expect(reopened.item(first)?.state == .ready)
    reopened.openReview(first)
    try await until("저장된 입력이") { reopened.reviewDrafts[first] != nil && reopened.proposals[first] != nil }
    #expect(reopened.resolvedReview(first).amount == "1500")

    // 쓰기가 돌아오면 다시 저장·확인이 된다.
    model.retrySave(first)
    try await until("저장 안내가 사라지기가") { !model.draftSaveFailed.contains(first) }
    await model.confirmAndNext(first)
    #expect(!model.confirmFailed.contains(first))
    #expect(model.item(first)?.confirmed?.fields.amountMinor == 1600)
  }

  /// 시스템 분할 보기를 실제 창에 띄워 좁은 창(compact) ↔ 넓은 창(regular)을 오가게 한다(접기·펴기·분할 화면과 같은 신호).
  /// 넓으면 목록과 고른 화면이 나란히, 좁으면 고른 화면이 위에 쌓이고, 고른 초안은 그대로다.
  @Test func splitViewFollowsWidthClassAndKeepsSelection() async throws {
    let (model, draft) = try model()
    await model.load()
    model.selection = .draft(draft.id)

    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 669, height: 951))
    window.rootViewController = UIHostingController(rootView: RootView(model: model))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }

    for (sizeClass, size) in [
      (UIUserInterfaceSizeClass.regular, CGSize(width: 669, height: 951)),  // 펼친 안쪽 화면(세로)
      (.compact, CGSize(width: 466, height: 678)),  // 바깥 화면
      (.regular, CGSize(width: 951, height: 669)),  // 펼친 안쪽 화면(가로)
      (.compact, CGSize(width: 320, height: 951)),  // 분할 화면의 좁은 창
    ] {
      window.frame = CGRect(origin: .zero, size: size)
      window.traitOverrides.horizontalSizeClass = sizeClass
      try await until("분할 보기가 \(sizeClass == .compact ? "접히기" : "펴지기")가", timeout: .seconds(5)) {
        splitViewController(in: window)?.isCollapsed == (sizeClass == .compact)
      }
      #expect(model.selection == .draft(draft.id))
    }
    #expect(recognizer.calls <= 2)
  }
}

@MainActor
private func splitViewController(in window: UIWindow) -> UISplitViewController? {
  window.layoutIfNeeded()
  var stack: [UIViewController] = window.rootViewController.map { [$0] } ?? []
  while let next = stack.popLast() {
    if let split = next as? UISplitViewController { return split }
    stack.append(contentsOf: next.children)
  }
  return nil
}

final class WriteFaults: @unchecked Sendable {
  private let lock = NSLock()
  private var failing: Set<String> = []
  func set(_ parts: Set<String>) { lock.withLock { failing = parts } }
  func shouldFail(_ url: URL) -> Bool { lock.withLock { failing.contains { url.path.contains($0) } } }
}
