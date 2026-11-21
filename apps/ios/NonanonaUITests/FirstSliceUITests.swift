import XCTest

/// 사진 앱 공유 → 로그인 전 초안 → 초대 링크 → (로그인 전 강제 종료) → 홈 화면 아이콘으로 다시 열기 → 로그인 → 초대받은 여행방.
/// `scripts/e2e.sh`가 두 단계 사이에 앱 프로세스를 강제로 끝내고 디스크 상태를 검사한다.
@MainActor
final class FirstSliceUITests: XCTestCase {
  private let app = XCUIApplication()
  private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

  override func setUp() async throws {
    continueAfterFailure = false
  }

  func test1_ShareFromPhotosSignedOutThenOpenInviteAndStartLogin() throws {
    shareFromPhotos(matching: "METADATA r01,")

    // 메신저의 초대 링크를 누른 것과 같은 시스템 경로로 연다.
    openLink("nonanona://invite/SYNTHINVITE01")
    XCTAssertTrue(app.staticTexts["참여하려면 로그인해 주세요. 공유한 영수증 초안은 그대로 남아요."].exists)
    snapshot("ios-invite-signed-out")
    app.buttons["invite-primary"].tap()

    XCTAssertTrue(app.buttons["login-apple"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["login-google"].exists)
    XCTAssertTrue(app.staticTexts["login-test-notice"].exists, "debug 빌드는 테스트 로그인임을 글자로 보여 준다")
    snapshot("ios-login-sheet")
    // 여기서 멈춘다. 로그인이 끝나기 전에 스크립트가 앱을 강제로 끝낸다.
  }

  func test2_RelaunchFromHomeScreenKeepsDraftAndInvite() throws {
    XCTAssertEqual(app.state, .notRunning, "이전 단계에서 앱 프로세스가 끝나 있어야 한다")
    springboard.activate()
    let icon = springboard.icons["노나노나"]
    XCTAssertTrue(icon.waitForExistence(timeout: 10))
    icon.tap()

    // 로그인 도중 끝났던 초대 화면으로 돌아온다.
    XCTAssertTrue(app.staticTexts["여행방에 초대받았어요"].waitForExistence(timeout: 15))
    app.navigationBars.buttons.element(boundBy: 0).tap()

    // 홈: 로그인 전 초안과 보관한 초대가 그대로 있다.
    XCTAssertTrue(app.buttons["draft-row"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["로그인 안 됨"].exists)
    XCTAssertTrue(app.staticTexts["초대받은 여행방이 있어요"].exists)
    snapshot("ios-home-signed-out-with-invite")
    // 여기서 멈춘다. 스크립트가 이 화면을 라이트·다크·큰 글자로 찍는다.
  }

  func test3_SignInReturnsToInvitedRoom() throws {
    app.activate()
    XCTAssertTrue(app.buttons["pending-invite-open"].waitForExistence(timeout: 10))
    app.buttons["pending-invite-open"].tap()
    app.buttons["invite-primary"].tap()
    let apple = app.buttons["login-apple"]
    XCTAssertTrue(apple.waitForExistence(timeout: 10))
    apple.tap()

    XCTAssertTrue(app.staticTexts["참여함"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.navigationBars["가상 도쿄 여행"].exists)
    XCTAssertTrue(app.staticTexts["다라"].exists)
    XCTAssertTrue(app.staticTexts["가나"].exists)
    snapshot("ios-room")

    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.staticTexts["로그인됨 · 가나"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["draft-row"].exists, "초안은 로그인 뒤에도 남는다")
    XCTAssertFalse(app.staticTexts["초대받은 여행방이 있어요"].exists, "수락한 초대는 지운다")
    snapshot("ios-home-signed-in")
  }

  /// debug 테스트 구현체의 가상 초대 코드로 실패와 복구를 확인한다. 앞 단계의 초안과 로그인 상태를 이어 쓴다.
  func test4_InviteFailuresRecoverWithoutLosingDraft() throws {
    app.activate()
    XCTAssertTrue(app.staticTexts["로그인됨 · 가나"].waitForExistence(timeout: 10))

    // 연결 실패 → 같은 초대로 다시 시도 → 참여.
    openLink("nonanona://invite/SYNTHOFFLINE01")
    app.buttons["invite-primary"].tap()
    XCTAssertTrue(failureText(contains: "인터넷에 연결할 수 없어요").waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons["invite-primary"].label, "다시 시도")
    snapshot("ios-invite-network-failure")
    app.buttons["invite-primary"].tap()
    XCTAssertTrue(app.staticTexts["참여함"].waitForExistence(timeout: 15))
    app.navigationBars.buttons.element(boundBy: 0).tap()

    // 만료된 초대 → 새 링크 요청 문구, 다시 시도 버튼 없음, 초대 카드 사라짐.
    openLink("nonanona://invite/SYNTHEXPIRED01")
    app.buttons["invite-primary"].tap()
    XCTAssertTrue(failureText(contains: "방장에게 새 링크를 요청해 주세요").waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["초대 만료됨"].exists)
    XCTAssertFalse(app.buttons["invite-primary"].exists, "만료된 초대는 다시 시도하지 않는다")
    snapshot("ios-invite-expired")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.buttons["draft-row"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["초대받은 여행방이 있어요"].exists)

    // 세션 만료 → 로그아웃 상태지만 초안과 초대는 남음 → 다시 로그인 → 같은 초대로 참여.
    openLink("nonanona://invite/SYNTHSESSION01")
    app.buttons["invite-primary"].tap()
    XCTAssertTrue(failureText(contains: "로그인이 만료됐어요").waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons["invite-primary"].label, "다시 로그인하기")
    snapshot("ios-invite-session-expired")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.staticTexts["로그인 안 됨"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["draft-row"].exists, "세션이 만료돼도 초안은 남는다")
    XCTAssertTrue(app.staticTexts["초대받은 여행방이 있어요"].exists, "세션이 만료돼도 초대는 남는다")
    app.buttons["pending-invite-open"].tap()
    app.buttons["invite-primary"].tap()
    let apple = app.buttons["login-apple"]
    XCTAssertTrue(apple.waitForExistence(timeout: 10))
    apple.tap()
    XCTAssertTrue(app.staticTexts["참여함"].waitForExistence(timeout: 15))
  }
}
