import XCTest

/// 다른 기기에서 올린 영수증의 품목 나누기 제안(ADR-0011, 로컬 Supabase 모드). `scripts/e2e-proposals.py`가 두 기기
/// (iOS 시뮬레이터·Android 에뮬레이터)의 역할(올린 회원·방장)을 정해 앱을 띄우고, 단계 사이에 서버 행과 오간 요청을 본다.
/// 값은 실행 환경(`TEST_RUNNER_P_*`)으로 받는다. 테스트는 떠 있는 앱에 붙기만 한다.
@MainActor
final class ProposalUITests: XCTestCase {
  private let app = XCUIApplication()
  private let env = ProcessInfo.processInfo.environment
  private var trip: String { env["P_TRIP"] ?? "" }

  override func setUp() async throws {
    continueAfterFailure = false
    guard env["EXPECT_LOCAL_BACKEND"] == "1", !trip.isEmpty else {
      throw XCTSkip("scripts/e2e-proposals.py가 로컬 Supabase 모드로 띄울 때만 실행한다")
    }
  }

  // MARK: 올린 회원

  func testU1_ShareI01() throws {
    shareFromPhotos(matching: "SYNTHETIC-ITEMS-METADATA i01,")
  }

  /// 제안 그대로 확인하고, 회원으로 로그인해 그 여행방에 사본을 올린다.
  func testU2_ConfirmLoginUpload() throws {
    app.activate()
    app.buttons["draft-row"].firstMatch.tap()
    let summary = app.staticTexts["processing-summary"]
    waitFor(timeout: 90) { summary.exists && summary.label == "읽음 1/1" }
    scrollTo(app.buttons["item-1-debug-confirm"]).tap()
    waitFor(timeout: 20) { self.app.staticTexts["item-1-status"].label == "확인함" }
    goHome()
    loginFromHome()
    openTrip()
    goHome()
    // 여행방 목록이 길면 홈이 아래로 넘겨진 채 돌아온다. 초안 줄까지 올린다.
    scrollTo(app.buttons["draft-row"].firstMatch).tap()
    XCTAssertTrue(scrollTo(app.staticTexts["올릴 곳: \(trip)"]).exists)
    scrollTo(app.buttons["upload-start"]).tap()
    let final = app.alerts.buttons["올리기"].firstMatch
    XCTAssertTrue(final.waitForExistence(timeout: 10))
    final.tap()
    let status = app.staticTexts["upload-status"]
    waitFor(timeout: 45) { status.exists && status.label == "올림 1장(이미 올린 0장 포함)" }
  }

  /// 장부에서 제안 화면을 열고 품목마다 낼 사람을 고른다. 남은 원은 고르기 전에는 보낼 수 없고, 고른 사람(`P_REMAINDER`)에게만 간다.
  /// 확인 창에서 보낼 값을 보고 보낸 뒤, 같은 내용을 다시 동의해 한 번 더 보낸다(새 보내기 → 새 행, 가장 최근은 같은 값).
  func testU3_ProposeWithExplicitRemainder() throws {
    openProposal()
    XCTAssertTrue(app.staticTexts["items-privacy"].label.contains("방장에게는 사람마다 부담 금액(원)만"))
    let basis = scrollTo(app.staticTexts["items-proposal-basis"]).label
    XCTAssertTrue(basis.contains(env["P_BASIS"] ?? "?"), basis)
    // 다시 열면(오래된 제안을 새로 보낼 때) 기기에 남은 계획이 그대로라 이미 켠 사람은 건드리지 않는다.
    for line in ["ocr-4", "ocr-6", "ocr-12"] {
      if !isOn(line, "가나") { person(line, "가나") }
      if !isOn(line, "다라") { person(line, "다라") }
    }
    if !isOn("ocr-8", "다라") { person("ocr-8", "다라") }
    if app.buttons["item-ocr-8-check"].exists {
      tapUntil(app.buttons["item-ocr-8-check"]) { !self.app.buttons["item-ocr-8-check"].exists }
    }
    if !isOn("ocr-10", "가나") { person("ocr-10", "가나") }
    let remainder = scrollTo(app.staticTexts["items-remainder"])
    XCTAssertTrue(remainder.label.contains("남은 원을 낼 사람을 골라 주세요. 저절로 정하지 않아요."), remainder.label)
    XCTAssertFalse(scrollTo(app.buttons["items-propose"]).isEnabled, "남은 원을 고르기 전에는 보낼 수 없다")
    snapshot("ios-proposal-remainder-unchosen")
    let choice = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'items-remainder-' AND label BEGINSWITH %@", env["P_REMAINDER"] ?? "?")
    ).firstMatch
    scrollTo(choice).tap()
    let preview = app.staticTexts["items-proposal-preview"]
    waitFor(timeout: 5) { preview.exists }
    XCTAssertEqual(scrollTo(preview).label, env["P_PREVIEW"])
    snapshot("ios-proposal-ready")
    send()
    // 같은 내용을 다시 동의해 보낸다(새 보내기). 불확실한 재시도의 같은 키는 단위 시험이 본다.
    send()
    XCTAssertEqual(scrollTo(app.staticTexts["items-proposal-state"]).label, "보낸 제안: 방장 확인을 기다려요.")
    snapshot("ios-proposal-sent")
  }

  /// 장부의 내 지출 줄에 보낸 제안 상태가 보인다(`P_STATE`). 확정된 방이면 제안 단추가 없다(`P_NO_PROPOSE`).
  func testU4_UploaderSeesState() throws {
    app.activate()
    goHome()
    loginFromHome()
    openTrip()
    app.buttons["room-refresh"].tap()
    let state = app.staticTexts["expense-proposal-1"]
    waitFor(timeout: 15) { state.exists && state.label == self.env["P_STATE"] }
    if env["P_NO_PROPOSE"] == "1" {
      XCTAssertFalse(app.buttons["propose-items-1"].exists)
    }
    snapshot("ios-proposal-uploader-\(env["P_SHOT"] ?? "state")")
  }

  // MARK: 방장

  /// 제안 상태 문구(`P_STATE`)와 채우기 단추가 없는지(오래된 제안) 본다. 서버에는 아무것도 보내지 않는다.
  func testH1_HostSeesStaleProposal() throws {
    openReview()
    let state = scrollTo(app.staticTexts["review-proposal-state"])
    XCTAssertEqual(state.label, env["P_STATE"])
    XCTAssertFalse(app.buttons["review-proposal-fill"].exists)
    snapshot("ios-proposal-host-stale")
    goHome()
  }

  /// 지금 제안을 확인하고 "직접 나누기"에 채운 뒤, 결제자를 고르고 직접 포함한다. 채우기만으로는 아무것도 보내지 않는다.
  func testH2_HostFillsConfirmsAndIncludes() throws {
    openReview()
    XCTAssertEqual(
      scrollTo(app.staticTexts["review-proposal-state"]).label,
      "지금 지출 값에 맞는 제안이에요. 채운 뒤 확인하고 \"포함하기\"를 눌러야 정산에 들어가요.")
    XCTAssertTrue(scrollTo(app.staticTexts["review-proposal-basis"]).label.contains(env["P_HOST_BASIS"] ?? "?"))
    for (index, expected) in (env["P_ROWS"] ?? "").split(separator: ";").enumerated() {
      XCTAssertTrue(
        scrollTo(app.descendants(matching: .any)["review-proposal-row-\(index + 1)"]).label.contains(expected),
        "row \(index + 1) should contain \(expected)")
    }
    snapshot("ios-proposal-host-current")
    scrollTo(app.buttons["review-proposal-fill"]).tap()
    let match = app.staticTexts["review-proposal-match"]
    waitFor(timeout: 5) { match.exists && match.label == "입력한 몫이 제안과 같아요." }
    scrollTo(app.buttons["review-payer"]).tap()
    app.buttons["다라"].firstMatch.tap()
    XCTAssertTrue(scrollTo(app.buttons["review-include"]).isEnabled)
    snapshot("ios-proposal-host-filled")
    scrollTo(app.buttons["review-include"]).tap()
    XCTAssertTrue(app.descendants(matching: .any)["room-screen"].waitForExistence(timeout: 15))
  }

  // MARK: - 도우미

  private func send() {
    scrollTo(app.buttons["items-propose"]).tap()
    let alert = app.alerts["방장에게 제안을 보낼까요?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 10))
    let body = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
    XCTAssertTrue(body.contains("품목 이름·품목 금액·영수증 글자는 보내지 않아요"), body)
    XCTAssertTrue(body.contains(env["P_CONSENT"] ?? "?"), body)
    alert.buttons["보내기"].firstMatch.tap()
    let sent = app.staticTexts["items-proposal-sent"]
    waitFor(timeout: 20) { sent.exists }
  }

  private func openProposal() {
    app.activate()
    goHome()
    loginFromHome()
    openTrip()
    app.buttons["room-refresh"].tap()
    Thread.sleep(forTimeInterval: 1.5)
    scrollTo(app.buttons["propose-items-1"]).tap()
    XCTAssertTrue(app.descendants(matching: .any)["item-split-screen"].waitForExistence(timeout: 15))
  }

  private func openReview() {
    app.activate()
    goHome()
    loginFromHome()
    openTrip()
    app.buttons["room-refresh"].tap()
    Thread.sleep(forTimeInterval: 1.5)
    scrollTo(app.buttons["expense-1"]).tap()
    XCTAssertTrue(app.descendants(matching: .any)["expense-review-screen"].waitForExistence(timeout: 10))
  }

  private func personButton(_ line: String, _ name: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "item-\(line)-person-", name)
    ).firstMatch
  }

  private func isOn(_ line: String, _ name: String) -> Bool {
    let element = scrollTo(personButton(line, name))
    return (element.value as? String) == "1" || element.isSelected
  }

  private func person(_ line: String, _ name: String) {
    let element = personButton(line, name)
    let before = scrollTo(element).value as? String
    tapUntil(element) { (element.value as? String) != before }
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
    XCTFail("\(element) tap had no effect")
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
    for direction in Array(repeating: true, count: 12) + Array(repeating: false, count: 24) {
      if element.exists && element.isHittable { return element }
      if app.keyboards.firstMatch.exists, app.buttons["keyboard-done"].firstMatch.exists {
        app.buttons["keyboard-done"].firstMatch.tap()
        continue
      }
      let list =
        ["item-split-screen", "expense-review-screen"].lazy
        .map { self.app.collectionViews[$0] }.first { $0.exists } ?? app.collectionViews.firstMatch
      if direction { list.swipeUp(velocity: .slow) } else { list.swipeDown(velocity: .slow) }
      Thread.sleep(forTimeInterval: 0.8)
    }
    XCTAssertTrue(element.exists && element.isHittable, "\(element) not reachable")
    return element
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
