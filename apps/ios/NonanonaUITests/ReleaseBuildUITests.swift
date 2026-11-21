import XCTest

/// release 빌드에는 테스트 로그인이 없고, 로그인할 수 없는 상태로 보여야 한다.
/// `TEST_RUNNER_EXPECT_RELEASE_APP=1 xcodebuild test -configuration Release ...`로만 실행한다.
@MainActor
final class ReleaseBuildUITests: XCTestCase {
  func testReleaseBuildShowsLoginUnavailable() throws {
    guard ProcessInfo.processInfo.environment["EXPECT_RELEASE_APP"] == "1" else {
      throw XCTSkip("release 빌드를 검사할 때만 실행한다")
    }
    let app = XCUIApplication()
    app.launch()
    XCUIDevice.shared.system.open(URL(string: "nonanona://invite/SYNTHINVITE01")!)
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let open = springboard.buttons["열기"].exists ? springboard.buttons["열기"] : springboard.buttons["Open"]
    if open.waitForExistence(timeout: 3) { open.tap() }

    XCTAssertTrue(app.buttons["invite-primary"].waitForExistence(timeout: 15))
    app.buttons["invite-primary"].tap()
    XCTAssertTrue(app.staticTexts["login-unavailable"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["login-apple"].exists)
    XCTAssertFalse(app.buttons["login-google"].exists)
    XCTAssertFalse(app.staticTexts["login-test-notice"].exists)
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "ios-release-login-unavailable"
    shot.lifetime = .keepAlways
    add(shot)
  }
}
