import XCTest

/// 로컬 Supabase 모드의 품목별 나누기(방장 기기 하나). `scripts/e2e-items.py`가 앱을 띄우고(번역 제공자 선택 포함)
/// 단계 사이에 서버 행(지출 상태·몫)과 서버 전체에 품목 글자가 없는지 확인한다. 테스트는 떠 있는 앱에 붙기만 한다.
@MainActor
final class ItemSplitUITests: XCTestCase {
  private let app = XCUIApplication()
  private let env = ProcessInfo.processInfo.environment
  private let trip = "가상 후쿠오카 정산"

  override func setUp() async throws {
    continueAfterFailure = false
    guard env["EXPECT_LOCAL_BACKEND"] == "1" else { throw XCTSkip("로컬 Supabase 모드로 빌드했을 때만 실행한다") }
  }

  func testI1_ShareItemReceipts() throws {
    shareFromPhotos(matchingEach: ["SYNTHETIC-ITEMS-METADATA i01,", "SYNTHETIC-ITEMS-METADATA i02,"])
  }

  /// 두 장을 제안 그대로 확인하고, 방장으로 로그인해 정산 여행방에 사본 2장을 올린다.
  func testI2_ConfirmLoginUpload() throws {
    app.activate()
    app.buttons["draft-row"].firstMatch.tap()
    let summary = app.staticTexts["processing-summary"]
    waitFor(timeout: 90) { summary.exists && summary.label == "읽음 2/2" }
    for position in 1...2 {
      let confirm = app.buttons["item-\(position)-debug-confirm"]
      scrollTo(confirm).tap()
      waitFor(timeout: 20) { self.app.staticTexts["item-\(position)-status"].label == "확인함" }
    }
    goHome()
    loginFromHome()
    openTrip()
    goHome()
    app.buttons["draft-row"].firstMatch.tap()
    XCTAssertTrue(scrollTo(app.staticTexts["올릴 곳: \(trip)"]).exists)
    scrollTo(app.buttons["upload-start"]).tap()
    let final = app.alerts.buttons["올리기"].firstMatch
    XCTAssertTrue(final.waitForExistence(timeout: 10))
    final.tap()
    let status = app.staticTexts["upload-status"]
    waitFor(timeout: 45) { status.exists && status.label == "올림 2장(이미 올린 0장 포함)" }
  }

  /// 실제 기기 번역 제공자(Apple Translation)의 상태만 기록한다. 시뮬레이터는 번역하지 않으므로 기대값을 두지 않는다.
  func testI3a_RealTranslatorStatus() throws {
    app.activate()
    openItemSplit(amount: "3,500 JPY", krw: "31500")
    let status = app.staticTexts["items-translation-status"]
    waitFor(timeout: 20) { status.exists && !status.label.contains("확인 중") }
    XCTAssertFalse(status.label.contains("미리보기"), "실제 제공자 상태: \(status.label)")
    let note = XCTAttachment(string: status.label)
    note.name = "ios-real-translator-status"
    note.lifetime = .keepAlways
    add(note)
    if app.buttons["items-translate"].exists {
      app.buttons["items-translate"].tap()
      waitFor(timeout: 30) { !status.label.contains("번역하는 중") }
      let after = XCTAttachment(string: status.label)
      after.name = "ios-real-translator-after-translate"
      after.lifetime = .keepAlways
      add(after)
    }
    snapshot("ios-items-real-translator")
  }

  /// i01(3,500엔, 내세): 직접 적은 이름은 번역이 덮지 않고, 첫 번역 실패 뒤 다시 번역한다(미리보기 대역).
  /// 공유 셋·한 사람 둘. 31,500원은 나눠떨어지지 않아 남은 1원이 보이고, 채우기는 서버에 아무것도 보내지 않는다.
  func testI3b_MixedSplitRemainderFillsExactWithoutSending() throws {
    app.activate()
    openItemSplit(amount: "3,500 JPY", krw: "31500")
    XCTAssertTrue(app.staticTexts["items-privacy"].exists)
    let status = app.staticTexts["items-translation-status"]
    waitFor(timeout: 10) { status.label.contains("미리보기 대역 · 실제 번역 아님") }
    replaceText(app.textFields["item-ocr-4-name"], "풋콩 직접")
    scrollTo(app.buttons["items-translate"]).tap()
    waitFor(timeout: 10) { status.label == "번역하지 못했어요. 다시 시도하거나 이름을 직접 적어 주세요." }
    scrollTo(app.buttons["items-translate"]).tap()
    waitFor(timeout: 10) { status.label.hasPrefix("4개 이름을 채웠어요") }
    XCTAssertEqual(scrollTo(app.textFields["item-ocr-6-name"]).value as? String, "닭튀김(미리보기)")
    XCTAssertEqual(app.staticTexts["item-ocr-6-source"].label, "미리보기 대역 · 실제 번역 아님")
    XCTAssertEqual(scrollTo(app.textFields["item-ocr-4-name"]).value as? String, "풋콩 직접")
    XCTAssertTrue(app.staticTexts["item-ocr-8-original"].label.contains("生ビール 2杯"))
    snapshot("ios-items-translated")

    XCTAssertEqual(scrollTo(app.staticTexts["items-problem"]).label, "'풋콩 직접'을(를) 낼 사람을 골라 주세요.")
    for line in ["ocr-4", "ocr-6", "ocr-12"] {
      person(line, "가나")
      person(line, "다라")
    }
    person("ocr-8", "다라")
    XCTAssertTrue(scrollTo(app.staticTexts["items-problem"]).label.contains("확인이 필요해요"))
    tapUntil(app.buttons["item-ocr-8-check"]) { !self.app.buttons["item-ocr-8-check"].exists }
    person("ocr-10", "가나")
    let remainder = scrollTo(app.staticTexts["items-remainder"])
    XCTAssertEqual(remainder.label, "원 단위로 나눠떨어지지 않아 1원이 남아요. 채운 뒤 \"직접 나누기\"에서 누가 낼지 정해 주세요.")
    XCTAssertTrue(shareRow(containing: "19,957원").exists, "다라 2,217.5엔 × 9 = 19,957.5원 → 내림")
    XCTAssertTrue(shareRow(containing: "11,542원").exists, "가나 1,282.5엔 × 9 = 11,542.5원 → 내림")
    snapshot("ios-items-remainder")
    scrollTo(app.buttons["items-apply"]).tap()

    XCTAssertTrue(app.collectionViews["expense-review-screen"].waitForExistence(timeout: 10))
    XCTAssertEqual(scrollTo(app.staticTexts["review-share-problem"]).label, "1원이 남았어요. 합계가 원화와 같아야 해요.")
    XCTAssertFalse(scrollTo(app.buttons["review-include"]).isEnabled)
    snapshot("ios-items-filled-exact-remainder")
    // 여기서 멈춘다. 스크립트가 서버에 몫이 없는지(아직 확인 필요) 본다.
  }

  /// 방장이 남은 1원을 직접 정해(결제자 다라 19,958원) 포함한다. 몫만 서버에 간다.
  func testI4_HostDecidesRemainderAndIncludes() throws {
    app.activate()
    let fields = (1...2).map { app.textFields["review-exact-\($0)"] }
    let field = try XCTUnwrap(
      fields.first { scrollTo($0).label.contains("다라") }, "다라의 직접 나누기 칸: \(fields.map(\.label))")
    replaceText(field, "19958")
    dismissKeyboard()
    XCTAssertFalse(app.staticTexts["review-share-problem"].exists)
    scrollTo(app.buttons["review-include"]).tap()
    XCTAssertTrue(app.descendants(matching: .any)["room-screen"].waitForExistence(timeout: 15))
  }

  /// i02(699엔, 외세·할인): 품목 합 698엔은 저절로 나누지 않는다. 방장이 할인(-50, 다라)·세금(51, 둘) 조정 줄을 더하면
  /// 6,990원이 3,345 / 3,645원으로 정확히 나뉜다. 채우지 않고 멈춘다(스크립트가 앱을 죽이고 다시 연다).
  func testI5_AdjustmentsMakeExactThenStop() throws {
    app.activate()
    openItemSplit(amount: "699 JPY", krw: "6990")
    person("ocr-2", "다라")
    person("ocr-4", "가나")
    person("ocr-6", "가나")
    person("ocr-6", "다라")
    XCTAssertEqual(scrollTo(app.staticTexts["items-problem"]).label, "줄 합계가 영수증 합계와 1 JPY 달라요. 저절로 나누지 않아요.")
    XCTAssertTrue(app.staticTexts["items-difference"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["items-summary-ocr-8"].exists, "할인 줄은 요약에만 있다")
    snapshot("ios-items-mismatch")
    scrollTo(app.buttons["items-add-adjustment"]).tap()
    replaceText(app.textFields["item-manual-1-name"], "할인")
    replaceText(app.textFields["item-manual-1-amount"], "-50")
    person("manual-1", "다라")
    scrollTo(app.buttons["items-add-adjustment"]).tap()
    replaceText(app.textFields["item-manual-2-name"], "소비세")
    replaceText(app.textFields["item-manual-2-amount"], "51")
    dismissKeyboard()
    person("manual-2", "가나")
    person("manual-2", "다라")
    XCTAssertTrue(shareRow(containing: "3,345원").exists)
    XCTAssertTrue(shareRow(containing: "3,645원").exists)
    XCTAssertFalse(app.staticTexts["items-remainder"].exists)
    snapshot("ios-items-exact")
  }

  /// 앱을 죽였다 다시 연 뒤: 검토 입력(원화·결제자)은 다시 적지만 품목 계획(이름·조정 줄·사람)은 기기에 남아 있다.
  func testI6_ReopenKeepsPlanApplyAndInclude() throws {
    app.activate()
    openItemSplit(amount: "699 JPY", krw: "6990")
    XCTAssertEqual(scrollTo(app.textFields["item-manual-1-name"]).value as? String, "할인")
    XCTAssertEqual(scrollTo(app.textFields["item-manual-2-amount"]).value as? String, "51")
    XCTAssertTrue(shareRow(containing: "3,345원").exists)
    XCTAssertTrue(shareRow(containing: "3,645원").exists)
    snapshot("ios-items-reopened")
    scrollTo(app.buttons["items-apply"]).tap()
    XCTAssertTrue(app.collectionViews["expense-review-screen"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["review-share-problem"].exists)
    scrollTo(app.buttons["review-include"]).tap()
    XCTAssertTrue(app.descendants(matching: .any)["room-screen"].waitForExistence(timeout: 15))
  }

  // MARK: - 도우미

  private func openItemSplit(amount: String, krw: String) {
    goHome()
    loginFromHome()
    openTrip()
    app.buttons["room-refresh"].tap()
    Thread.sleep(forTimeInterval: 1.5)
    let row = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'expense-' AND label CONTAINS %@", amount)
    )
    .firstMatch
    scrollTo(row).tap()
    XCTAssertTrue(app.descendants(matching: .any)["expense-review-screen"].waitForExistence(timeout: 10))
    scrollTo(app.buttons["review-payer"]).tap()
    app.buttons["다라"].firstMatch.tap()
    replaceText(app.textFields["review-krw"], krw)
    dismissKeyboard()
    scrollTo(app.buttons["review-item-split"]).tap()
    XCTAssertTrue(app.descendants(matching: .any)["item-split-screen"].waitForExistence(timeout: 10))
  }

  /// 그 줄의 사람 단추를 눌러 켜고 꺼짐이 실제로 바뀌었는지 본다(목록이 아직 움직일 때 누르면 빗나간다).
  @discardableResult
  private func person(_ line: String, _ name: String) -> XCUIElement {
    let element = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "item-\(line)-person-", name)
    ).firstMatch
    let before = scrollTo(element).value as? String
    tapUntil(element) { (element.value as? String) != before }
    return element
  }

  private func tapUntil(_ element: XCUIElement, _ changed: @escaping () -> Bool) {
    for _ in 0..<3 {
      scrollTo(element).tap()
      let deadline = Date().addingTimeInterval(3)
      while Date() < deadline {
        if changed() { return }
        Thread.sleep(forTimeInterval: 0.2)
      }
    }
    XCTFail("\(element) tap had no effect (value \(String(describing: element.value)))")
  }

  private func shareRow(containing text: String) -> XCUIElement {
    let element = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'items-share-' AND label CONTAINS %@", text)
    ).firstMatch
    return scrollTo(element)
  }

  private func goHome() {
    for _ in 0..<5 where !app.descendants(matching: .any)["home-screen"].exists {
      let back = app.navigationBars.buttons.element(boundBy: 0)
      if back.exists { back.tap() } else { break }
    }
    XCTAssertTrue(app.descendants(matching: .any)["home-screen"].waitForExistence(timeout: 10))
  }

  private func loginFromHome() {
    if app.buttons["home-login"].exists {
      app.buttons["home-login"].tap()
      app.buttons["login-apple"].firstMatch.tap()
    }
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '로그인됨'")).firstMatch
        .waitForExistence(timeout: 20))
  }

  private func openTrip() {
    let row = app.buttons.matching(NSPredicate(format: "identifier == 'trip-row' AND label CONTAINS %@", trip))
      .firstMatch
    XCTAssertTrue(scrollTo(row).exists)
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["room-screen"].waitForExistence(timeout: 20))
  }

  @discardableResult
  private func scrollTo(_ element: XCUIElement) -> XCUIElement {
    for direction in Array(repeating: true, count: 10) + Array(repeating: false, count: 20) {
      if element.exists && element.isHittable { return element }
      // 자판이 목록 아래를 가리면 닫고 다시 본다.
      if app.keyboards.firstMatch.exists, app.buttons["keyboard-done"].firstMatch.exists {
        app.buttons["keyboard-done"].firstMatch.tap()
        continue
      }
      let list =
        ["item-split-screen", "expense-review-screen"].lazy.map { self.app.collectionViews[$0] }.first { $0.exists }
        ?? app.collectionViews.firstMatch
      if direction { list.swipeUp(velocity: .slow) } else { list.swipeDown(velocity: .slow) }
      Thread.sleep(forTimeInterval: 0.8)
    }
    XCTAssertTrue(element.exists && element.isHittable, "\(element) not reachable")
    return element
  }

  private func replaceText(_ field: XCUIElement, _ text: String) {
    // 오른쪽 끝을 눌러 커서를 글자 끝에 둔다(가운데를 누르면 지우기가 앞부분만 지운다).
    scrollTo(field).coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
    let current = field.value as? String ?? ""
    let placeholder = field.placeholderValue ?? ""
    if !current.isEmpty && current != placeholder {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
    field.typeText(text)
    waitFor(timeout: 5) { field.value as? String == text }
  }

  private func dismissKeyboard() {
    if app.keyboards.firstMatch.exists {
      let done =
        app.buttons["keyboard-done"].firstMatch.exists
        ? app.buttons["keyboard-done"].firstMatch : app.buttons["완료"].firstMatch
      if done.exists { done.tap() }
    }
    waitFor(timeout: 5) { !self.app.keyboards.firstMatch.exists }
  }

  private func waitFor(timeout: TimeInterval, _ condition: @escaping () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      Thread.sleep(forTimeInterval: 0.3)
    }
    XCTFail("condition not met in \(timeout)s")
  }
}
