import XCTest

/// 로컬 Supabase 모드로 빌드한 debug 앱의 실제 서버 흐름. `scripts/e2e-local.sh`가 단계 사이에
/// API 게이트웨이를 멈추고(연결 실패) 서버 세션을 지운다(세션 만료). 가상 계정과 가상 초대만 쓴다.
@MainActor
final class LocalBackendUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUp() async throws {
    continueAfterFailure = false
    guard ProcessInfo.processInfo.environment["EXPECT_LOCAL_BACKEND"] == "1" else {
      throw XCTSkip("로컬 Supabase 모드로 빌드했을 때만 실행한다")
    }
  }

  func testL1_AcceptRepeatExpiredAndInvalidInvites() throws {
    shareFromPhotos(matching: "METADATA r01,")

    openLink("nonanona://invite/SYNTHLOCAL0001")
    app.buttons["invite-primary"].tap()
    XCTAssertTrue(app.staticTexts["login-test-notice"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["login-test-notice"].label, "로컬 테스트 계정 · 실제 소셜 로그인이 아니에요")
    snapshot("ios-local-login-sheet")
    app.buttons["login-apple"].tap()
    assertInRoom("가상 오사카 여행")
    snapshot("ios-local-room")
    back()

    // 같은 계정의 반복 수락은 같은 여행방으로 수렴한다.
    openLink("nonanona://invite/SYNTHLOCAL0001")
    XCTAssertEqual(app.buttons["invite-primary"].label, "참여하기")
    app.buttons["invite-primary"].tap()
    assertInRoom("가상 오사카 여행")
    back()

    openLink("nonanona://invite/SYNTHLOCALEXPIRED")
    app.buttons["invite-primary"].tap()
    XCTAssertTrue(failureText(contains: "초대 링크가 만료됐어요").waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["invite-primary"].exists)
    snapshot("ios-local-invite-expired")
    back()

    openLink("nonanona://invite/SYNTHLOCALREVOKED")
    app.buttons["invite-primary"].tap()
    XCTAssertTrue(failureText(contains: "이 초대 링크는 쓸 수 없어요").waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["쓸 수 없는 초대"].exists)
    XCTAssertFalse(app.buttons["invite-primary"].exists)
    snapshot("ios-local-invite-invalid")
    back()

    // 다음 단계 전에 스크립트가 API 게이트웨이를 멈춘다.
    openLink("nonanona://invite/SYNTHLOCALRETRY")
  }

  func testL2_JoinWhileServerUnreachableShowsRetry() throws {
    app.activate()
    let join = app.buttons["invite-primary"]
    XCTAssertTrue(join.waitForExistence(timeout: 10))
    join.tap()
    XCTAssertTrue(failureText(contains: "인터넷에 연결할 수 없어요").waitForExistence(timeout: 30))
    XCTAssertEqual(join.label, "다시 시도")
    snapshot("ios-local-network-failure")
  }

  func testL3_RetryAfterServerIsBackJoins() throws {
    app.activate()
    let retry = app.buttons["invite-primary"]
    XCTAssertTrue(retry.waitForExistence(timeout: 10))
    XCTAssertEqual(retry.label, "다시 시도")
    retry.tap()
    assertInRoom("가상 교토 여행")
    back()
  }

  func testL4_ExpiredServerSessionReauthKeepsDraftAndInvite() throws {
    app.activate()
    openLink("nonanona://invite/SYNTHLOCALRELOG")
    app.buttons["invite-primary"].tap()
    XCTAssertTrue(failureText(contains: "로그인이 만료됐어요").waitForExistence(timeout: 20))
    XCTAssertEqual(app.buttons["invite-primary"].label, "다시 로그인하기")
    snapshot("ios-local-session-expired")
    back()
    XCTAssertTrue(app.staticTexts["로그인 안 됨"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["draft-row"].exists, "세션이 만료돼도 초안은 남는다")
    XCTAssertTrue(app.staticTexts["초대받은 여행방이 있어요"].exists, "세션이 만료돼도 초대는 남는다")
    app.buttons["pending-invite-open"].tap()
    app.buttons["invite-primary"].tap()
    let apple = app.buttons["login-apple"]
    XCTAssertTrue(apple.waitForExistence(timeout: 10))
    apple.tap()
    assertInRoom("가상 나라 여행")
    back()
    XCTAssertTrue(app.staticTexts["로그인됨 · 가나"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["draft-row"].exists)
  }

  private func assertInRoom(_ name: String) {
    XCTAssertTrue(app.staticTexts["참여함"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.navigationBars[name].exists, "서버의 가상 여행방")
    XCTAssertTrue(app.staticTexts["다라"].exists)
    XCTAssertTrue(app.staticTexts["가나"].exists)
  }

  private func back() {
    app.navigationBars.buttons.element(boundBy: 0).tap()
  }
}
