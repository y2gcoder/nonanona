import XCTest

/// 사진 앱에서 가상 영수증 10장 공유 → (스크립트: 앱 실행, 처리 도중 SIGKILL) → 다시 열어 이어서 처리
/// → 실패한 사진만 다시 읽기 → 개발용 확인으로 가림을 구운 사본 만들기. `scripts/e2e-receipts.sh`가 단계 사이에
/// 앱을 SIGKILL로 끝내고 디스크 상태와 가림 사본을 검사한다.
@MainActor
final class ReceiptProcessingUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUp() async throws {
    continueAfterFailure = false
  }

  func testR1_ShareTenPhotos() throws {
    shareFromPhotos(matchingEach: (1...10).map { String(format: "METADATA r%02d,", $0) })
    // 여기서 멈춘다. 스크립트가 처리를 늦춘 설정으로 앱을 띄우고, 처리 도중 SIGKILL로 끝낸다.
  }

  func testR2_ReopenResumesThenRetryOnlyFailedAndConfirm() throws {
    app.launchEnvironment = [:]
    app.launch()
    app.buttons["draft-row"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["processing-recovered"].waitForExistence(timeout: 15), "끝나지 않은 사진을 이어서 읽는다")
    let summary = app.staticTexts["processing-summary"]
    waitFor(timeout: 120) { self.processed(summary) == 10 }
    let failed = (1...10).filter { status($0).label == "읽지 못함" }
    XCTAssertEqual(failed.count, 2, "주입한 일시 실패 1장 + 초점이 나간 r10")
    XCTAssertTrue(failed.contains(4))
    let unreadable = failed.first { $0 != 4 }!
    snapshot("ios-receipts-after-resume")

    // 일시 실패한 사진만 다시 읽는다.
    let before = labels()
    scrollTo(app.buttons["item-4-retry"]).tap()
    waitFor(timeout: 60) { self.status(4).label == "확인 필요" }
    // 읽을 수 없는 사진은 다시 읽어도 실패하고, 다른 사진은 그대로다.
    scrollTo(app.buttons["item-\(unreadable)-retry"]).tap()
    waitFor(timeout: 60) { self.status(unreadable).label == "읽지 못함" }
    let after = labels()
    for i in 1...10 where i != 4 { XCTAssertEqual(before[i], after[i], "사진 \(i)") }

    // 개발용 확인: 제안된 값과 가림을 그대로 확인해 가림 사본을 만든다.
    let confirm = 1 == unreadable ? 2 : 1
    scrollTo(app.buttons["item-\(confirm)-debug-confirm"]).tap()
    waitFor(timeout: 30) { self.status(confirm).label == "확인함" }
    snapshot("ios-receipts-confirmed")
    let record = XCTAttachment(string: "confirmedPosition=\(confirm)\nunreadablePosition=\(unreadable)\n")
    record.name = "receipt-positions"
    record.lifetime = .keepAlways
    add(record)
  }

  private func status(_ position: Int) -> XCUIElement { scrollTo(app.staticTexts["item-\(position)-status"]) }

  private func labels() -> [Int: String] { Dictionary(uniqueKeysWithValues: (1...10).map { ($0, status($0).label) }) }

  private func processed(_ summary: XCUIElement) -> Int {
    guard let r = summary.label.range(of: #"읽음 (\d+)/"#, options: .regularExpression) else { return -1 }
    return Int(String(summary.label[r].filter(\.isNumber))) ?? -1
  }

  /// 목록의 행은 화면 밖이면 접근성 트리에 없다. 보일 때까지 넘긴다.
  @discardableResult
  private func scrollTo(_ element: XCUIElement) -> XCUIElement {
    for direction in [true, false] {
      for _ in 0..<6 {
        if element.exists && element.isHittable { return element }
        let list = app.collectionViews.firstMatch
        direction ? list.swipeUp(velocity: .slow) : list.swipeDown(velocity: .slow)
      }
    }
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
