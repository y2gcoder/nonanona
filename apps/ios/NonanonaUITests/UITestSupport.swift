import XCTest

/// 여러 UI 테스트가 함께 쓰는 실제 기기 진입 경로: 사진 앱 공유, 시스템 링크 열기, 화면 기록.
@MainActor
extension XCTestCase {
  var nonanona: XCUIApplication { XCUIApplication() }

  func shareFromPhotos(matching label: String) {
    let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
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

  /// 메신저의 초대 링크를 누른 것과 같은 시스템 경로로 연다.
  func openLink(_ link: String) {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    XCUIDevice.shared.system.open(URL(string: link)!)
    let open = springboard.buttons["열기"].exists ? springboard.buttons["열기"] : springboard.buttons["Open"]
    if open.waitForExistence(timeout: 3) { open.tap() }
    XCTAssertTrue(nonanona.staticTexts["여행방에 초대받았어요"].waitForExistence(timeout: 15))
  }

  func failureText(contains text: String) -> XCUIElement {
    nonanona.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
  }

  func snapshot(_ name: String) {
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
