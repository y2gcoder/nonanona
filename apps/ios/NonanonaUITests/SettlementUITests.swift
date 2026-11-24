import XCTest

/// 로컬 Supabase 모드의 여행방 정산. `scripts/e2e-settlement.py`가 두 기기(iOS·Android)를 번갈아 움직이며 단계 사이에 서버
/// 상태를 확인한다. 회원 단계(M)는 가상 회원, 방장 단계(H)는 가상 방장 계정(`NONANONA_LOCAL_ACCOUNT=host`)으로 실행한 앱에 붙는다.
/// 기대 값(송금·확정 번호)은 스크립트가 `TEST_RUNNER_`로 넘긴다.
@MainActor
final class SettlementUITests: XCTestCase {
  private let app = XCUIApplication()
  private let env = ProcessInfo.processInfo.environment
  private let trip = "가상 후쿠오카 정산"

  override func setUp() async throws {
    continueAfterFailure = false
    guard env["EXPECT_LOCAL_BACKEND"] == "1" else { throw XCTSkip("로컬 Supabase 모드로 빌드했을 때만 실행한다") }
  }

  // MARK: - 회원

  func testM1_ShareReceipts() throws {
    shareFromPhotos(matchingEach: ["METADATA r01,", "METADATA r02,", "METADATA r10,"])
  }

  /// 읽은 두 장은 제안 그대로 확인하고, 읽지 못한 한 장은 사진 없이 값만 직접 입력해 확인한다(KRW 입장권).
  func testM2_ConfirmTwoAndEnterOneManually() throws {
    app.activate()
    app.buttons["draft-row"].firstMatch.tap()
    let summary = app.staticTexts["processing-summary"]
    waitFor(timeout: 90) { summary.exists && summary.label == "읽음 3/3" }
    for position in 1...3 {
      let confirm = app.buttons["item-\(position)-debug-confirm"]
      if scrollIfNeeded(confirm) {
        confirm.tap()
        waitFor(timeout: 20) { self.app.staticTexts["item-\(position)-status"].label == "확인함" }
      }
    }
    let openFailed = scrollTo(app.buttons["open-first-failed"])
    let position = Int(openFailed.label.filter(\.isNumber))!
    let title = app.navigationBars["사진 \(position)"]
    for _ in 0..<3 where !title.exists {
      scrollTo(app.buttons["open-first-failed"]).tap()
      _ = title.waitForExistence(timeout: 5)
    }
    XCTAssertTrue(title.exists, "읽지 못한 사진의 검토 화면이 열린다")
    replaceText(app.textFields["review-merchant"], "ticket")
    replaceText(app.textFields["review-amount"], "38000")
    replaceText(app.textFields["review-date"], "2026-11-08")
    dismissKeyboard()
    scrollTo(app.buttons["review-currency"]).tap()
    app.buttons["KRW"].firstMatch.tap()
    let confirm = app.buttons["review-confirm-next"]
    waitFor(timeout: 5) { confirm.isEnabled }
    snapshot("ios-settlement-manual-entry")
    confirm.tap()
    XCTAssertTrue(app.navigationBars["초안"].waitForExistence(timeout: 15))
  }

  /// 홈에서 로그인 → 시드 여행방을 열어 올릴 곳으로 정한다 → 사본 2장을 올린다 → 직접 입력 1건을 따로 확인받고 올린다 → 다시 올려도 같은 지출.
  func testM3_LoginOpenTripUploadReceiptsAndManual() throws {
    app.activate()
    goHome()
    loginFromHome()
    openTrip()
    XCTAssertTrue(app.staticTexts["아직 올라온 지출이 없어요."].waitForExistence(timeout: 10))
    goHome()
    app.buttons["draft-row"].firstMatch.tap()
    XCTAssertTrue(scrollTo(app.staticTexts["올릴 곳: \(trip)"]).exists)
    XCTAssertTrue(app.staticTexts["확인한 영수증 2장"].exists)
    XCTAssertTrue(app.staticTexts["upload-manual-excluded"].exists)
    scrollTo(app.buttons["upload-start"]).tap()
    finalButton().tap()
    expect("upload-status", "올림 2장(이미 올린 0장 포함)")
    scrollTo(app.buttons["manual-upload-start"]).tap()
    XCTAssertTrue(app.alerts.staticTexts["‘\(trip)’에 직접 입력 1건을 올릴까요?"].waitForExistence(timeout: 10))
    snapshot("ios-settlement-manual-consent")
    finalButton().tap()
    expect("manual-upload-status", "올림 1건(이미 올린 0건 포함)")
    scrollTo(app.buttons["manual-upload-start"]).tap()
    finalButton().tap()
    expect("manual-upload-status", "올림 1건(이미 올린 1건 포함)")
  }

  /// 회원은 방장과 같은 지출을 보지만 검토·확정 동작이 없다. 미리보기는 볼 수 있다.
  func testM4_MemberSeesSameExpensesWithoutHostActions() throws {
    app.activate()
    goHome()
    openTrip()
    refreshRoom()
    for i in 1...3 { XCTAssertTrue(scrollTo(app.descendants(matching: .any)["expense-\(i)"]).exists) }
    XCTAssertFalse(app.buttons["expense-1"].exists, "회원에게는 지출이 눌리는 검토 버튼이 아니다")
    snapshot("ios-settlement-member-ledger")
    scrollTo(app.buttons["open-settlement"]).tap()
    XCTAssertTrue(app.descendants(matching: .any)["settlement-status"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["settlement-finalize"].exists, "회원에게는 확정 버튼이 없다")
    snapshot("ios-settlement-member-preview")
    app.navigationBars.buttons.element(boundBy: 0).tap()
  }

  /// 확정 뒤(그리고 앱을 다시 연 뒤) 회원도 같은 확정본을 본다.
  func testM5_MemberSeesFinalizedSettlement() throws {
    app.activate()
    goHome()
    openTrip()
    refreshRoom()
    XCTAssertTrue(app.descendants(matching: .any)["room-finalized"].waitForExistence(timeout: 20))
    scrollTo(app.buttons["open-settlement"]).tap()
    expectFinal("ios-settlement-member-final")
  }

  // MARK: - 방장

  func testH1_LoginAndReviewIncludeAndHold() throws {
    app.activate()
    goHome()
    loginFromHome()
    openTrip()
    refreshRoom()
    XCTAssertTrue(app.descendants(matching: .any)["room-pending"].waitForExistence(timeout: 15))
    snapshot("ios-settlement-host-ledger-pending")

    // r01(외화): 확인한 원화 13,377원(홀수)을 둘이 반씩 — 결제자 다라가 1원을 더 부담한다(6,689 / 6,688).
    openExpense(matching: "1,408 JPY")
    pickPayer("다라")
    replaceText(app.textFields["review-krw"], "13377")
    dismissKeyboard()
    let evenOdd = "다라 6,689원 · 가나 6,688원 · 합계 13,377원. 남는 1원은 결제자(다라)가 더 부담해요."
    XCTAssertEqual(scrollTo(app.staticTexts["review-even-summary"]).label, evenOdd)
    XCTAssertFalse(app.staticTexts["review-share-problem"].exists)
    XCTAssertTrue(scrollTo(app.buttons["review-include"]).isEnabled)
    snapshot("ios-settlement-review-even-odd")
    // 직접 나누기는 그대로 쓸 수 있다: 합이 원화와 다르면 막힌다. 반씩으로 돌아가 포함한다.
    scrollTo(app.segmentedControls["review-share-mode"]).buttons["직접 나누기"].tap()
    replaceText(app.textFields["review-exact-1"], "6688")
    dismissKeyboard()
    XCTAssertEqual(scrollTo(app.staticTexts["review-share-problem"]).label, "6,689원이 남았어요. 합계가 원화와 같아야 해요.")
    XCTAssertFalse(scrollTo(app.buttons["review-include"]).isEnabled)
    snapshot("ios-settlement-review-exact")
    scrollTo(app.segmentedControls["review-share-mode"]).buttons["둘이 반씩"].tap()
    XCTAssertEqual(scrollTo(app.staticTexts["review-even-summary"]).label, evenOdd)
    scrollTo(app.buttons["review-include"]).tap()
    XCTAssertTrue(app.descendants(matching: .any)["room-screen"].waitForExistence(timeout: 15))

    // r02(외화, 원화 모름): 사유와 함께 보류.
    openExpense(matching: "1,276 JPY")
    hold(reason: "원화 청구액 확인 대기")
    XCTAssertTrue(app.descendants(matching: .any)["room-screen"].waitForExistence(timeout: 15))

    // 직접 입력(KRW 38,000): 원화 그대로, 둘이 반씩.
    openExpense(matching: "38,000 KRW")
    XCTAssertTrue(scrollTo(app.staticTexts["review-krw-fixed"]).exists)
    pickPayer("다라")
    XCTAssertEqual(scrollTo(app.staticTexts["review-even-summary"]).label, "한 사람 19,000원 · 합계 38,000원")
    scrollTo(app.buttons["review-include"]).tap()
    XCTAssertTrue(app.descendants(matching: .any)["room-screen"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.descendants(matching: .any)["room-pending"].exists)
    snapshot("ios-settlement-host-ledger-reviewed")
  }

  /// 공유한 가림 사본 보기: 연 사본의 확인 해시가 서버에 저장된 사본과 같다 → 뒤로 갔다 다시 열면 지워져 있다
  /// → 직접 입력은 증빙 없음. 사본은 화면에 들어가는 이 화면(넓은 창이면 목록 옆 상세 열)에서 연다.
  func testH1b_ViewMaskedReceipt() throws {
    app.activate()
    openExpense(matching: "1,408 JPY")
    scrollTo(app.buttons["review-receipt-show"]).tap()
    let verified = app.staticTexts["review-receipt-verified"]
    XCTAssertTrue(verified.waitForExistence(timeout: 20))
    XCTAssertEqual(verified.label, "올린 사본과 같아요 · 확인 \(env["ARTIFACT_SHA_PREFIX"] ?? "?")")
    XCTAssertTrue(app.images["review-receipt-image"].exists)
    XCTAssertEqual(app.images["review-receipt-image"].label, "가린 영수증 사본")
    snapshot("ios-settlement-receipt-shown")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    openExpense(matching: "1,408 JPY")
    XCTAssertTrue(app.buttons["review-receipt-show"].waitForExistence(timeout: 5), "다시 열면 다시 눌러야 받는다")
    XCTAssertFalse(app.images["review-receipt-image"].exists)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    openExpense(matching: "38,000 KRW")
    XCTAssertTrue(scrollTo(app.staticTexts["review-receipt-none"]).exists)
    XCTAssertFalse(app.buttons["review-receipt-show"].exists)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    openExpense(matching: "1,408 JPY")
  }

  /// 서버에 닿지 않을 때: 다시 시도할 수 있는 실패가 보이고, 검토(결제자 고르기)는 그대로 된다. 스크립트가 API를 멈춘 상태.
  func testH1c_ReceiptNetworkFailureDoesNotBlockReview() throws {
    app.activate()
    scrollTo(app.buttons["review-receipt-show"]).tap()
    let failure = app.staticTexts["review-receipt-failure"]
    XCTAssertTrue(failure.waitForExistence(timeout: 30))
    XCTAssertEqual(failure.label, "인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요.")
    XCTAssertTrue(app.buttons["review-receipt-retry"].exists)
    XCTAssertTrue(scrollTo(app.buttons["review-payer"]).isEnabled, "사본을 못 받아도 검토할 수 있다")
    snapshot("ios-settlement-receipt-network-failure")
  }

  /// 서버가 돌아온 뒤 다시 시도 → 같은 사본. 큰 글자(스크립트가 바꿈)에서도 사본·확인 문구에 닿고, 가로(넓은 창)에서도 보인다.
  func testH1d_RetryThenLargeTextAndLandscape() throws {
    app.activate()
    scrollTo(app.buttons["review-receipt-retry"]).tap()
    // 큰 글자에서는 목록이 길어져 확인 문구가 화면 밖일 수 있다. 받기가 끝난 뒤 그 자리로 넘긴다.
    waitFor(timeout: 20) {
      !self.app.buttons["review-receipt-retry"].exists && !self.app.staticTexts["review-receipt-loading"].exists
    }
    let verified = scrollTo(app.staticTexts["review-receipt-verified"])
    XCTAssertEqual(verified.label, "올린 사본과 같아요 · 확인 \(env["ARTIFACT_SHA_PREFIX"] ?? "?")")
    XCTAssertTrue(scrollTo(app.images["review-receipt-image"]).exists)
    snapshot("ios-settlement-receipt-large-text")
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(scrollTo(app.staticTexts["review-receipt-verified"]).exists, "가로에서도 같은 사본")
    snapshot("ios-settlement-receipt-landscape")
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(app.staticTexts["review-receipt-verified"].waitForExistence(timeout: 10))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.descendants(matching: .any)["room-screen"].waitForExistence(timeout: 10))
  }

  /// 미리보기: 서버가 계산한 송금(가나 → 다라 25,688원), 보류 제외. 스크립트가 미리보기를 연 뒤 회원 지출을 하나 더 넣는다.
  func testH2_OpenPreview() throws {
    app.activate()
    scrollTo(app.buttons["open-settlement"]).tap()
    XCTAssertTrue(app.descendants(matching: .any)["transfer-1"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.descendants(matching: .any)["transfer-1"].label, "가나 → 다라, 25,688원")
    XCTAssertEqual(app.descendants(matching: .any)["settlement-total"].label, "함께 쓴 돈, 51,377원")
    XCTAssertTrue(app.descendants(matching: .any)["excluded-1"].label.contains("보류: 원화 청구액 확인 대기"))
    snapshot("ios-settlement-preview")
  }

  /// 미리보기 뒤 회원 지출이 들어와 확정이 거절되고(오래된 revision), 새 미리보기에 확인 필요 1건이 보인다.
  /// 그 지출을 보류하고 다시 확정한다.
  func testH3_FinalizeStaleThenHoldLateThenFinalize() throws {
    app.activate()
    app.buttons["settlement-finalize"].tap()
    app.alerts.buttons["확정"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["settlement-refreshed"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["settlement-pending"].exists)
    XCTAssertFalse(app.buttons["settlement-finalize"].isEnabled)
    snapshot("ios-settlement-finalize-stale")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    openExpense(matching: "5,000 KRW")
    hold(reason: "결제 여부 불명확")
    XCTAssertTrue(app.descendants(matching: .any)["room-screen"].waitForExistence(timeout: 15))
    scrollTo(app.buttons["open-settlement"]).tap()
    let finalize = app.buttons["settlement-finalize"]
    waitFor(timeout: 15) { finalize.exists && finalize.isEnabled }
    XCTAssertEqual(app.descendants(matching: .any)["transfer-1"].label, "가나 → 다라, 25,688원")
    finalize.tap()
    XCTAssertTrue(app.alerts.buttons["확정"].firstMatch.waitForExistence(timeout: 5))
    snapshot("ios-settlement-finalize-confirm")
    app.alerts.buttons["확정"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["정산 확정됨"].waitForExistence(timeout: 20))
  }

  /// 확정본(그리고 앱을 다시 연 뒤): 같은 확정 번호·송금·제외 목록. 장부에는 검토 동작이 없다.
  func testH4_HostSeesFinalizedSettlement() throws {
    app.activate()
    goHome()
    openTrip()
    refreshRoom()
    XCTAssertTrue(app.descendants(matching: .any)["room-finalized"].waitForExistence(timeout: 20))
    XCTAssertFalse(app.buttons["expense-1"].exists, "확정 뒤에는 지출을 검토할 수 없다")
    scrollTo(app.buttons["open-settlement"]).tap()
    expectFinal("ios-settlement-host-final")
  }

  // MARK: - 도우미

  private func expectFinal(_ shot: String) {
    let id = app.staticTexts["settlement-final-id"]
    XCTAssertTrue(id.waitForExistence(timeout: 20))
    XCTAssertTrue(id.label.hasPrefix("확정 번호 \(env["FINAL_ID_PREFIX"] ?? "?")"), id.label)
    XCTAssertEqual(app.descendants(matching: .any)["transfer-1"].label, "가나 → 다라, 25,688원")
    XCTAssertFalse(app.descendants(matching: .any)["transfer-2"].exists)
    XCTAssertEqual(app.descendants(matching: .any)["settlement-total"].label, "함께 쓴 돈, 51,377원")
    XCTAssertTrue(app.descendants(matching: .any)["excluded-1"].label.contains("보류"))
    XCTAssertTrue(app.descendants(matching: .any)["excluded-2"].label.contains("보류"))
    XCTAssertFalse(app.buttons["settlement-finalize"].exists)
    snapshot(shot)
  }

  private func goHome() {
    for _ in 0..<4 where !app.otherElements["home-screen"].exists && !app.collectionViews["home-screen"].exists {
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
    XCTAssertTrue(row.waitForExistence(timeout: 20))
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["room-screen"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.navigationBars[trip].waitForExistence(timeout: 20))
  }

  private func refreshRoom() {
    app.buttons["room-refresh"].tap()
    Thread.sleep(forTimeInterval: 1.5)
  }

  /// 가게 이름은 기기 OCR이 다르게 읽을 수 있어(Android ML Kit은 みなと珈琲를 みなと迦芽로 읽는다) 금액으로 찾는다.
  private func openExpense(matching amount: String) {
    let row = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'expense-' AND label CONTAINS %@", amount)
    )
    .firstMatch
    scrollTo(row).tap()
    XCTAssertTrue(app.descendants(matching: .any)["expense-review-screen"].waitForExistence(timeout: 10))
  }

  private func hold(reason: String) {
    let button = app.buttons[reason].firstMatch
    for _ in 0..<3 where !button.exists {
      scrollTo(app.buttons["review-hold"]).tap()
      _ = button.waitForExistence(timeout: 5)
    }
    button.tap()
  }

  private func pickPayer(_ name: String) {
    scrollTo(app.buttons["review-payer"]).tap()
    app.buttons[name].firstMatch.tap()
  }

  private func finalButton() -> XCUIElement {
    let button = app.alerts.buttons["올리기"].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    return button
  }

  private func expect(_ id: String, _ text: String) {
    let status = app.staticTexts[id]
    waitFor(timeout: 45) { status.exists && status.label == text }
  }

  private func scrollIfNeeded(_ element: XCUIElement) -> Bool {
    for _ in 0..<4 {
      if element.exists && element.isHittable { return true }
      app.collectionViews.firstMatch.swipeUp(velocity: .slow)
    }
    return element.exists && element.isHittable
  }

  @discardableResult
  private func scrollTo(_ element: XCUIElement) -> XCUIElement {
    // 넓은 창(목록 옆 상세)에서는 목록이 둘이다. 검토 화면이 있으면 그 목록을 넘긴다.
    let review = app.collectionViews["expense-review-screen"]
    let list = review.exists ? review : app.collectionViews.firstMatch
    for direction in Array(repeating: true, count: 8) + Array(repeating: false, count: 16) {
      if element.exists && element.isHittable { return element }
      if direction { list.swipeUp(velocity: .slow) } else { list.swipeDown(velocity: .slow) }
      Thread.sleep(forTimeInterval: 0.5)
    }
    XCTAssertTrue(element.exists && element.isHittable, "\(element) not reachable")
    return element
  }

  private func replaceText(_ field: XCUIElement, _ text: String) {
    scrollTo(field).tap()
    let current = field.value as? String ?? ""
    let placeholder = field.placeholderValue ?? ""
    if !current.isEmpty && current != placeholder {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
    field.typeText(text)
    waitFor(timeout: 5) { field.value as? String == text }
  }

  private func dismissKeyboard() {
    if app.keyboards.firstMatch.exists, app.buttons["keyboard-done"].firstMatch.exists {
      app.buttons["keyboard-done"].firstMatch.tap()
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
