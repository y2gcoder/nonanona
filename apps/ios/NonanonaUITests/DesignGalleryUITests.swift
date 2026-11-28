import XCTest

/// 입력 틀에 붙인 시스템 날짜 선택기와 통화 메뉴가 실제로 열리고 값을 바꾸는지 debug 부품 모음에서 확인한다.
@MainActor
final class DesignGalleryUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testDateAndCurrencyFieldsOpenSystemPickers() {
    let app = XCUIApplication()
    app.launchEnvironment["NONANONA_DESIGN_GALLERY"] = "2"
    app.launch()

    let date = app.buttons["날짜"]
    XCTAssertTrue(date.waitForExistence(timeout: 10))
    XCTAssertEqual(date.value as? String, "2026-11-03")
    date.tap()
    let picker = app.datePickers.firstMatch
    XCTAssertTrue(picker.waitForExistence(timeout: 5), "날짜 칸을 누르면 시스템 달력이 열린다")
    let fifth = app.buttons.matching(NSPredicate(format: "label CONTAINS '11월 5일' OR label CONTAINS 'November 5'"))
      .firstMatch
    XCTAssertTrue(fifth.waitForExistence(timeout: 5))
    fifth.tap()
    XCTAssertTrue(picker.waitForNonExistence(timeout: 5), "날짜를 고르면 달력이 닫힌다")
    XCTAssertEqual(date.value as? String, "2026-11-05")

    let currency = app.buttons["통화"]
    XCTAssertEqual(currency.value as? String, "JPY")
    currency.tap()
    let usd = app.buttons["USD"]
    XCTAssertTrue(usd.waitForExistence(timeout: 5), "통화 칸을 누르면 시스템 메뉴가 열린다")
    usd.tap()
    XCTAssertEqual(currency.value as? String, "USD")
  }
}
