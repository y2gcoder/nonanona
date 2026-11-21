import XCTest

/// 사진 앱 공유 → 로그인 전 초안 → 초대 링크 → (로그인 전 강제 종료) → 홈 화면 아이콘으로 다시 열기 → 로그인 → 초대받은 여행방.
/// `scripts/e2e.sh`가 두 단계 사이에 앱 프로세스를 강제로 끝내고 디스크 상태를 검사한다.
@MainActor
final class FirstSliceUITests: XCTestCase {
  private let app = XCUIApplication()
  private let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
  private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

  override func setUp() async throws {
    continueAfterFailure = false
  }

  func test1_ShareFromPhotosSignedOutThenOpenInviteAndStartLogin() throws {
    shareFromPhotos(matching: "METADATA r01,")

    // 메신저의 초대 링크를 누른 것과 같은 시스템 경로로 연다.
    XCUIDevice.shared.system.open(URL(string: "nonanona://invite/SYNTHINVITE01")!)
    let open = springboard.buttons["열기"].exists ? springboard.buttons["열기"] : springboard.buttons["Open"]
    if open.waitForExistence(timeout: 3) { open.tap() }

    XCTAssertTrue(app.staticTexts["여행방에 초대받았어요"].waitForExistence(timeout: 15))
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

  private func shareFromPhotos(matching label: String) {
    photos.launch()
    if photos.buttons["Continue"].waitForExistence(timeout: 3) { photos.buttons["Continue"].tap() }
    if photos.buttons["Cancel"].exists { photos.buttons["Cancel"].tap() }
    let photo = photos.images.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    XCTAssertTrue(photo.waitForExistence(timeout: 10), "가상 영수증이 사진 앱에 있어야 한다")
    photos.buttons["Select"].tap()
    photo.tap()
    photos.buttons["Share"].tap()
    let ours = photos.cells.matching(NSPredicate(format: "label == '노나노나'")).firstMatch
    XCTAssertTrue(ours.waitForExistence(timeout: 10), "공유 메뉴에 노나노나가 보여야 한다")
    ours.tap()
    let save = photos.buttons["share-save"]
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    XCTAssertTrue(photos.staticTexts["share-status"].label.contains("사진 1장"))
    snapshot("ios-share-extension")
    save.tap()
    XCTAssertTrue(save.waitForNonExistence(timeout: 20), "공유 확장이 끝나야 한다")
    if photos.buttons["Cancel"].exists { photos.buttons["Cancel"].tap() }
  }

  private func snapshot(_ name: String) {
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
