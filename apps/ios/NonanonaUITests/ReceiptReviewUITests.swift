import XCTest

/// 목록 먼저 영수증 검토(로컬 Supabase 모드). `scripts/e2e-review.sh`가 앱을 띄우고(처리 늦추기, 한 사진의 가림 제안 비우기),
/// 단계 사이에 앱을 끝내거나 글자 크기·서버 상태를 바꾸고, 디스크와 서버에 실제로 남은 것을 확인한다. 테스트는 떠 있는 앱에 붙는다.
/// 가상 영수증만 쓴다. 사진 번호는 사진 앱이 넘긴 순서라 테스트는 화면에 보이는 번호(실패한 사진, 다음 사진)를 따라간다.
@MainActor
final class ReceiptReviewUITests: XCTestCase {
  private let app = XCUIApplication()
  private var env: [String: String] { ProcessInfo.processInfo.environment }

  override func setUp() async throws {
    continueAfterFailure = false
    guard env["EXPECT_LOCAL_BACKEND"] == "1" else {
      throw XCTSkip("로컬 Supabase 모드로 빌드했을 때만 실행한다")
    }
  }

  func testV1_ShareTenPhotos() throws {
    shareFromPhotos(matchingEach: (1...10).map { String(format: "METADATA r%02d,", $0) })
  }

  /// 목록이 먼저: 읽는 중과 대기를 나눠 보이고, 다 읽으면 확인 필요 9 · 읽지 못함 1과 실패 안내가 보인다.
  func testV2_QueueShowsActionableStates() throws {
    app.activate()
    app.buttons["draft-row"].firstMatch.tap()
    let breakdown = app.staticTexts["queue-breakdown"]
    waitFor(timeout: 30) { breakdown.exists && breakdown.label.contains("읽는 중 2") && breakdown.label.contains("대기") }
    XCTAssertTrue(app.buttons["review-start"].exists)
    snapshot("ios-review-queue-processing")
    let summary = app.staticTexts["processing-summary"]
    waitFor(timeout: 120) { summary.label == "읽음 10/10" }
    waitFor(timeout: 10) { breakdown.label == "확인 필요 9 · 읽지 못함 1" }
    XCTAssertEqual(app.buttons["review-start"].label, "확인할 영수증 검토 (9)")
    XCTAssertTrue(app.buttons["open-first-failed"].exists, "실패 안내에서 그 사진으로 바로 간다")
    XCTAssertEqual(app.staticTexts["review-summary"].label, "확인 0/10")
    snapshot("ios-review-queue-ready")
  }

  /// 읽지 못한 사진: 직접 입력하던 값이 "이 사진만 다시 읽기"를 지나도 남고, 다시 실패한 뒤 직접 입력으로 확인한다.
  func testV3_FailedPhotoRetryThenManualEntry() throws {
    app.activate()
    let openFailed = app.buttons["open-first-failed"]
    let failedPosition = Int(openFailed.label.filter(\.isNumber))!
    openFailed.tap()
    XCTAssertTrue(app.navigationBars["사진 \(failedPosition)"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["review-status"].label, "읽지 못함")
    let confirm = app.buttons["review-confirm-next"]
    XCTAssertFalse(confirm.isEnabled, "값이 없으면 확인할 수 없다")
    XCTAssertTrue(scrollTo(app.staticTexts["review-date-problem"]).exists, "왜 확인할 수 없는지 보인다")
    replaceText(app.textFields["review-merchant"], "ゆきみ茶屋")
    replaceText(app.textFields["review-amount"], "1760")
    dismissKeyboard()

    scrollTo(app.buttons["review-retry"]).tap()
    // 상태 라벨은 목록 맨 위에 있다. 다시 읽는 중임을 보이고(시도 횟수 2는 스크립트가 디스크에서 확인), 다시 실패를 기다린다.
    for _ in 0..<3 { app.collectionViews.firstMatch.swipeDown(velocity: .fast) }
    let status = app.staticTexts["review-status"]
    if status.exists && (status.label == "대기 중" || status.label == "읽는 중") { snapshot("ios-review-retrying") }
    waitFor(timeout: 60) { status.exists && status.label == "읽지 못함" }
    XCTAssertEqual(scrollTo(app.textFields["review-amount"]).value as? String, "1760", "다시 읽기를 지나도 입력이 남는다")
    // 일본어 자판에서 붙여넣은 것 같은 전각 날짜. 앱이 2026-11-08로 맞춘다(디스크 값은 스크립트가 확인).
    replaceText(app.textFields["review-date"], "２０２６－１１－０８")
    dismissKeyboard()
    waitFor(timeout: 5) { confirm.isEnabled }
    snapshot("ios-review-manual-entry")
    confirm.tap()
    let next = failedPosition == 10 ? 1 : failedPosition + 1
    XCTAssertTrue(app.navigationBars["사진 \(next)"].waitForExistence(timeout: 15), "다음 확인할 사진이 열린다")
    XCTAssertEqual(app.staticTexts["review-progress"].label, "확인 1/10")
  }

  /// 읽은 값을 고치고 확인하면 다음 사진으로 간다. 고친 값은 디스크와 서버에서 스크립트가 확인한다.
  func testV4_EditValuesThenConfirmAndNext() throws {
    app.activate()
    // 보통은 방금 열린 다음 사진이다. 가림 제안을 비운 사진이면 스크립트가 그 뒤 사진을 고른다.
    if currentTitle() != "사진 \(env["EDIT_POSITION"]!)" { openFromList(Int(env["EDIT_POSITION"]!)!) }
    let title = currentTitle()
    let amount = scrollTo(app.textFields["review-amount"])
    let original = Int((amount.value as? String ?? "").filter(\.isNumber))!
    replaceText(amount, String(original + 10))
    let merchant = app.textFields["review-merchant"]
    replaceText(merchant, (merchant.value as? String ?? "") + "(수정)")
    dismissKeyboard()
    snapshot("ios-review-edited")
    app.buttons["review-confirm-next"].tap()
    waitFor(timeout: 15) { self.currentTitle() != title }
    XCTAssertEqual(app.staticTexts["review-progress"].label, "확인 2/10")
  }

  /// 가림 제안이 비어 있는 사진(스크립트가 고른 위치): OCR 줄 켜기와 가림 영역 더하기로 놓친 곳을 고치고,
  /// 가린 사본 미리보기를 본 뒤 확인한다. 스크립트가 기기에서 꺼낸 사본의 픽셀을 정답과 비교한다.
  func testV5_CorrectMissedMaskWithPreview() throws {
    app.activate()
    if currentTitle() != "사진 \(env["MISSED_POSITION"]!)" { openFromList(Int(env["MISSED_POSITION"]!)!) }
    XCTAssertEqual(scrollTo(app.staticTexts["mask-count"]).label, "가림 0곳", "제안이 놓친 상태에서 시작한다")
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mask-warning").firstMatch.exists)
    snapshot("ios-review-missed-mask")
    let lineIDs = env["MASK_LINE_IDS"]!.split(separator: ",").map(String.init)
    var maskedTexts: [String] = []
    for id in lineIDs {
      let toggle = scrollTo(app.switches["mask-line-\(id)"])
      maskedTexts.append(toggle.label)
      toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
      waitFor(timeout: 5) { toggle.value as? String == "1" }
    }
    scrollTo(app.buttons["mask-add-region"]).tap()
    let region = scrollTo(app.descendants(matching: .any).matching(identifier: "region-1-value").firstMatch)
    let target = (top: Int(env["BAND_TOP"]!)!, height: Int(env["BAND_HEIGHT"]!)!)
    func band() -> (Int, Int) {
      let numbers = (region.value as? String ?? "").split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
      return (numbers[0], numbers[1] - numbers[0])
    }
    while band().0 != target.top {
      scrollTo(app.buttons[band().0 < target.top ? "region-1-down" : "region-1-up"]).tap()
    }
    while band().1 != target.height {
      scrollTo(app.buttons[band().1 < target.height ? "region-1-grow" : "region-1-shrink"]).tap()
    }
    let expectedCount = lineIDs.count + 1
    XCTAssertEqual(scrollTo(app.staticTexts["mask-count"]).label, "가림 \(expectedCount)곳")
    snapshot("ios-review-mask-corrected")

    scrollTo(app.segmentedControls["review-view-mode"]).buttons["가린 사본"].tap()
    let preview = app.images["review-preview"]
    XCTAssertTrue(preview.waitForExistence(timeout: 20))
    XCTAssertTrue(preview.label.hasPrefix("가린 사본 미리보기, 가림 \(expectedCount)곳"))
    for text in maskedTexts { XCTAssertFalse(preview.label.contains(text), "가린 글자를 읽어 주지 않는다") }
    snapshot("ios-review-masked-preview")
    app.segmentedControls["review-view-mode"].buttons["원본"].tap()
    let title = currentTitle()
    app.buttons["review-confirm-next"].tap()
    waitFor(timeout: 15) { self.currentTitle() != title }
    XCTAssertEqual(app.staticTexts["review-progress"].label, "확인 3/10")
  }

  /// 다음 사진에 값을 입력만 하고(확인하지 않음) 멈춘다. 스크립트가 앱을 SIGKILL로 끝낸다.
  func testV6_TypeWithoutConfirming() throws {
    app.activate()
    replaceText(scrollTo(app.textFields["review-amount"]), "999")
    dismissKeyboard()
    snapshot("ios-review-before-kill")
  }

  /// 저장 실패 주입(스크립트가 `debug-fail-writes`에 `reviews/`를 적음): 입력을 고치면 저장하지 못했다고 알리고, 화면 입력은 남는다.
  func testV6b_DraftSaveFailureIsSurfaced() throws {
    app.activate()
    replaceText(scrollTo(app.textFields["review-amount"]), "888")
    dismissKeyboard()
    XCTAssertTrue(app.staticTexts["review-save-error"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.textFields["review-amount"].value as? String, "888", "저장하지 못해도 화면의 입력은 남는다")
    snapshot("ios-review-save-failed")
  }

  /// 확인 저장 실패 주입(`processing.json`도): "확인하고 다음"이 확인을 남기지 못했다고 알리고, 같은 사진에 머문다.
  func testV6c_ConfirmFailureKeepsReceiptUnconfirmed() throws {
    app.activate()
    let title = currentTitle()
    app.buttons["review-confirm-next"].tap()
    XCTAssertTrue(app.staticTexts["review-confirm-error"].waitForExistence(timeout: 10))
    XCTAssertEqual(currentTitle(), title, "다음 사진으로 가지 않는다")
    snapshot("ios-review-confirm-failed")
    XCTAssertEqual(scrollTo(app.staticTexts["review-progress"]).label, "확인 3/10")
    XCTAssertEqual(app.staticTexts["review-status"].label, "확인 필요")
  }

  /// 다시 연 뒤: 확인 3장이 남고, "확인할 영수증 검토"가 목록 순서의 첫 확인 필요 사진(입력하던 값 그대로)을 연다.
  /// 고른 영수증과 입력이 세로 → 가로(넓은 창, 목록 옆 상세) → 세로를 지나도 남는다.
  func testV7_RecoverAfterRestartAndRotate() throws {
    app.activate()
    let row = app.buttons["draft-row"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    row.tap()
    let summary = app.staticTexts["review-summary"]
    waitFor(timeout: 10) { summary.exists && summary.label == "확인 3/10" }
    XCTAssertEqual(app.buttons["review-start"].label, "확인할 영수증 검토 (7)")
    snapshot("ios-review-after-restart-list")
    let typed = Int(env["TYPED_POSITION"]!)!
    XCTAssertEqual(scrollTo(app.staticTexts["item-\(typed)-status"]).label, "확인 필요", "입력만 한 사진은 확인되지 않았다")
    scrollTo(app.buttons["item-\(typed)-open"]).tap()
    let amount = scrollTo(app.textFields["review-amount"])
    XCTAssertEqual(amount.value as? String, "999", "확인하지 않은 입력이 앱을 다시 열어도 남는다")
    let title = currentTitle()
    replaceText(app.textFields["review-merchant"], "회전 전 입력")
    dismissKeyboard()

    XCUIDevice.shared.orientation = .landscapeLeft
    waitFor(timeout: 10) { self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height }
    XCTAssertEqual(currentTitle(), title, "넓은 창에서도 같은 영수증")
    XCTAssertEqual(app.textFields["review-merchant"].value as? String, "회전 전 입력")
    if env["EXPECT_WIDE_LANDSCAPE"] == "1" {
      XCTAssertTrue(app.staticTexts["account-status"].isHittable, "넓은 창: 목록 옆에 검토 화면")
    }
    snapshot("ios-review-landscape")
    XCUIDevice.shared.orientation = .portrait
    waitFor(timeout: 10) { self.app.windows.firstMatch.frame.width < self.app.windows.firstMatch.frame.height }
    XCTAssertEqual(currentTitle(), title)
    XCTAssertEqual(scrollTo(app.textFields["review-amount"]).value as? String, "999")
  }

  /// 가장 큰 글자(접근성 크기): 같은 영수증, 이름이 있는 조작, 스크롤로 마지막 조작까지 닿는다.
  func testV8_LargestTextStillReachable() throws {
    app.activate()
    XCTAssertTrue(app.otherElements["review-screen"].exists || app.collectionViews["review-screen"].exists)
    XCTAssertEqual(scrollTo(app.textFields["review-amount"]).value as? String, "999")
    XCTAssertTrue(scrollTo(app.buttons["mask-add-region"]).isHittable)
    XCTAssertEqual(app.buttons["mask-add-region"].label, "가림 영역 더하기")
    XCTAssertTrue(app.buttons["review-confirm-next"].isHittable)
    XCTAssertEqual(app.buttons["review-confirm-next"].label, "확인하고 다음")
    snapshot("ios-review-largest-text")
    // 목록으로 돌아간다(확인하지 않고 나가도 확인되지 않는다).
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.navigationBars["초안"].waitForExistence(timeout: 10))
    XCTAssertEqual(scrollTo(app.staticTexts["review-summary"]).label, "확인 3/10", "나가기는 확인이 아니다")
  }

  /// 올릴 곳이 없으면 올리기 버튼이 없다 → 초대로 참여 → 최종 확인 창(사본 2장, 직접 입력 제외 안내)에서 멈춘다.
  func testV9_NoDestinationThenJoinAndStopAtFinalConfirmation() throws {
    app.activate()
    XCTAssertTrue(
      scrollTo(app.staticTexts["참여한 여행방이 없어요. 초대 링크로 참여한 뒤 올릴 수 있어요."]).exists)
    XCTAssertFalse(app.buttons["upload-start"].exists, "올릴 곳이 없으면 올리기 버튼이 없다")
    openLink("nonanona://invite/SYNTHLOCAL0001")
    app.buttons["invite-primary"].tap()
    app.buttons["login-apple"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["참여함"].waitForExistence(timeout: 20))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.buttons["draft-row"].firstMatch.tap()
    XCTAssertTrue(scrollTo(app.staticTexts["올릴 곳: 가상 오사카 여행"]).exists)
    XCTAssertTrue(app.staticTexts["확인한 영수증 2장"].exists)
    XCTAssertTrue(app.staticTexts["upload-manual-excluded"].exists)
    scrollTo(app.buttons["upload-start"]).tap()
    XCTAssertTrue(finalButton().waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["‘가상 오사카 여행’에 영수증 2장을 올릴까요?"].exists)
    snapshot("ios-review-final-confirmation")
  }

  func testV10_CancelFinalConfirmationSendsNothing() throws {
    app.activate()
    app.alerts.buttons["취소"].tap()
    XCTAssertTrue(finalButton().waitForNonExistence(timeout: 5))
  }

  func testV11_UnauthorizedDestinationFailsClosed() throws {
    app.activate()
    uploadWithFinalConfirmation()
    expectStatus("이 여행방에 올릴 수 없어요. 여행방 구성원인지 확인해 주세요.")
    snapshot("ios-review-unauthorized")
  }

  func testV12_UploadThenRepeatConverges() throws {
    app.activate()
    uploadWithFinalConfirmation()
    expectStatus("올림 2장(이미 올린 0장 포함)")
    uploadWithFinalConfirmation()
    expectStatus("올림 2장(이미 올린 2장 포함)")
    snapshot("ios-review-uploaded")
  }

  // MARK: - 도우미

  /// 검토 화면의 제목("사진 N"). 넓은 창에서는 목록 열의 막대도 있으므로 이름으로 고른다.
  private func currentTitle() -> String {
    app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH '사진 '")).firstMatch.identifier
  }

  /// 검토 화면에서 목록으로 돌아가 그 번호의 영수증을 연다.
  private func openFromList(_ position: Int) {
    let back = app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH '사진 '")).firstMatch
      .buttons.element(boundBy: 0)
    if back.exists { back.tap() }
    XCTAssertTrue(app.navigationBars["초안"].waitForExistence(timeout: 10))
    scrollTo(app.buttons["item-\(position)-open"]).tap()
    XCTAssertTrue(app.navigationBars["사진 \(position)"].waitForExistence(timeout: 10))
  }

  private func finalButton() -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == '올리기'")).firstMatch
  }

  private func uploadWithFinalConfirmation() {
    let start = scrollTo(app.buttons["upload-start"])
    waitFor(timeout: 20) { start.isEnabled }
    start.tap()
    XCTAssertTrue(finalButton().waitForExistence(timeout: 10))
    finalButton().tap()
  }

  private func expectStatus(_ text: String) {
    let status = app.staticTexts["upload-status"]
    waitFor(timeout: 45) { status.exists && status.label == text }
  }

  /// 목록을 아래로(그다음 위로) 넘기며, 상단 막대와 하단 확인 막대에 가리지 않는 자리로 가져온다.
  /// (가려진 요소도 XCUI는 눌릴 수 있다고 보므로, 그 자리를 누르면 위에 있는 "확인하고 다음"이 눌린다.)
  @discardableResult
  private func scrollTo(_ element: XCUIElement) -> XCUIElement {
    func clear() -> Bool {
      guard element.exists, element.isHittable else { return false }
      let frame = element.frame
      let bar = app.staticTexts["review-confirm-hint"]
      if bar.exists, frame.maxY > bar.frame.minY - 4 { return false }
      let nav = app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH '사진 '")).firstMatch
      if nav.exists, frame.minY < nav.frame.maxY { return false }
      return true
    }
    if clear() { return element }
    dismissKeyboard()
    let list = app.collectionViews.firstMatch
    for direction in Array(repeating: true, count: 12) + Array(repeating: false, count: 24) {
      if clear() { return element }
      if direction { list.swipeUp(velocity: .slow) } else { list.swipeDown(velocity: .slow) }
      // 목록이 멈춘 뒤에 누른다(움직이는 목록의 첫 탭은 스크롤만 멈춘다).
      Thread.sleep(forTimeInterval: 0.8)
    }
    XCTAssertTrue(clear(), "\(element) not reachable")
    return element
  }

  private func replaceText(_ field: XCUIElement, _ text: String) {
    dismissKeyboard()
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
    if app.keyboards.firstMatch.exists {
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
