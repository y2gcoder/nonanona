import XCTest

/// 로컬 Supabase 모드에서 확인한 영수증 올리기. `scripts/e2e-upload.sh`가 앱을 띄우고 단계 사이에 서버 상태를 바꾸고
/// (게이트웨이 정지, 구성원 빼기, 세션 삭제) 서버에 실제로 무엇이 남았는지 확인한다. 테스트는 떠 있는 앱에 붙기만 한다.
@MainActor
final class ReceiptUploadUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUp() async throws {
    continueAfterFailure = false
    guard ProcessInfo.processInfo.environment["EXPECT_LOCAL_BACKEND"] == "1" else {
      throw XCTSkip("로컬 Supabase 모드로 빌드했을 때만 실행한다")
    }
  }

  func testU1_ShareTwoReceipts() throws {
    shareFromPhotos(matchingEach: ["METADATA r01,", "METADATA r02,"])
  }

  /// 한 장만 확인하고, 초대로 여행방에 참여한 뒤, 올릴 곳·장수를 보여 주는 최종 확인 창에서 멈춘다.
  func testU2_ConfirmOneJoinTripAndStopAtFinalConfirmation() throws {
    app.activate()
    app.buttons["draft-row"].firstMatch.tap()
    let summary = app.staticTexts["processing-summary"]
    waitFor(timeout: 60) { summary.exists && summary.label == "읽음 2/2" }
    let confirm = app.buttons["item-1-debug-confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 10))
    confirm.tap()
    waitFor(timeout: 30) { self.app.staticTexts["item-1-status"].label == "확인함" }
    XCTAssertEqual(app.staticTexts["item-2-status"].label, "확인 필요", "두 번째 사진은 확인하지 않는다")
    XCTAssertTrue(app.staticTexts["참여한 여행방이 없어요. 초대 링크로 참여한 뒤 올릴 수 있어요."].exists)

    openLink("nonanona://invite/SYNTHLOCAL0001")
    app.buttons["invite-primary"].tap()
    app.buttons["login-apple"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["참여함"].waitForExistence(timeout: 20))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.buttons["draft-row"].firstMatch.tap()

    XCTAssertTrue(app.staticTexts["올릴 곳: 가상 오사카 여행"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["확인한 영수증 1장"].exists)
    app.buttons["upload-start"].tap()
    XCTAssertTrue(finalButton().waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["‘가상 오사카 여행’에 영수증 1장을 올릴까요?"].exists)
    snapshot("ios-upload-final-confirmation")
    // 여기서 멈춘다. 스크립트가 최종 확인 전에는 서버에 아무것도 없는지 본다.
  }

  func testU3_FinalConfirmWhileOfflineFails() throws {
    app.activate()
    finalButton().tap()
    expectStatus("인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요.")
  }

  func testU4_InvalidDestinationFailsClosed() throws {
    app.activate()
    uploadWithFinalConfirmation()
    expectStatus("이 여행방에 올릴 수 없어요. 여행방 구성원인지 확인해 주세요.")
    snapshot("ios-upload-invalid-destination")
  }

  /// 세션 만료 → 다시 로그인 → 다시 올리기(사본은 올라가고 지출 행을 만들기 전에 끊기는 첫 실패를 만난다).
  func testU5_SessionLossReloginThenPartialFailure() throws {
    app.activate()
    uploadWithFinalConfirmation()
    expectStatus("로그인이 만료됐어요. 다시 로그인한 뒤 다시 올려 주세요.")
    app.buttons["upload-login"].tap()
    let apple = app.buttons["login-apple"].firstMatch
    XCTAssertTrue(apple.waitForExistence(timeout: 10))
    apple.tap()
    let start = app.buttons["upload-start"]
    XCTAssertTrue(start.waitForExistence(timeout: 20))
    waitFor(timeout: 20) { start.isEnabled }
    uploadWithFinalConfirmation()
    expectStatus("인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요.")
  }

  func testU6_RetryCreatesOneExpenseThenRepeatReplays() throws {
    app.activate()
    uploadWithFinalConfirmation()
    expectStatus("올림 1장(이미 올린 0장 포함)")
    uploadWithFinalConfirmation()
    expectStatus("올림 1장(이미 올린 1장 포함)")
    snapshot("ios-upload-done")
  }

  /// 앱을 다시 연 뒤(여행방 화면 상태는 기기에 남지 않는다) 초대로 다시 들어가 같은 영수증을 올리면 같은 지출로 수렴한다.
  func testU7_ReopenAndUploadAgainReplays() throws {
    app.activate()
    openLink("nonanona://invite/SYNTHLOCAL0001")
    app.buttons["invite-primary"].tap()
    XCTAssertTrue(app.staticTexts["참여함"].waitForExistence(timeout: 20))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.buttons["draft-row"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["올릴 곳: 가상 오사카 여행"].waitForExistence(timeout: 10))
    uploadWithFinalConfirmation()
    expectStatus("올림 1장(이미 올린 1장 포함)")
  }

  private func finalButton() -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == '올리기'")).firstMatch
  }

  private func uploadWithFinalConfirmation() {
    let start = app.buttons["upload-start"]
    XCTAssertTrue(start.waitForExistence(timeout: 10))
    start.tap()
    XCTAssertTrue(finalButton().waitForExistence(timeout: 10))
    finalButton().tap()
  }

  private func expectStatus(_ text: String) {
    let status = app.staticTexts["upload-status"]
    waitFor(timeout: 45) { status.exists && status.label == text }
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
