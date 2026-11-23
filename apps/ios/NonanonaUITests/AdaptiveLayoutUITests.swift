import XCTest

/// 창 크기·회전이 바뀌어도 고른 초안, 처리 상태, 최종 확인(올릴 곳), 로그인 시트가 그대로인지 본다(테스트 구현체).
/// `scripts/e2e-adaptive.sh`가 처리를 늦춘 채 앱을 띄우고, 단계 사이에 디스크의 시도 횟수와 글자 크기를 바꾼다.
/// 넓은 가로 창(가로 regular)이 기대되는 기기에서는 `EXPECT_WIDE_LANDSCAPE=1`로 목록과 초안이 나란히 보이는지도 본다.
@MainActor
final class AdaptiveLayoutUITests: XCTestCase {
  private let app = XCUIApplication()
  private var expectWideLandscape: Bool { ProcessInfo.processInfo.environment["EXPECT_WIDE_LANDSCAPE"] == "1" }

  override func setUp() async throws {
    continueAfterFailure = false
  }

  override func tearDown() async throws {
    XCUIDevice.shared.orientation = .portrait
  }

  /// 초안 둘: 사진 2장(r01, r02)과 사진 1장(r03).
  func testA1_ShareTwoDrafts() throws {
    shareFromPhotos(matchingEach: ["METADATA r01,", "METADATA r02,"])
    shareFromPhotos(matching: "METADATA r03,")
  }

  /// 읽는 중에 가로로 돌리고 되돌려도 같은 초안(사진 2장)과 처리 상태가 보이고, 넓은 가로 창에서는 목록이 옆에 있다.
  func testA2_RotateWhileReadingKeepsDraftAndProgress() throws {
    app.activate()
    XCTAssertEqual(XCUIDevice.shared.orientation, .portrait)
    openTwoPhotoDraft()
    let summary = app.staticTexts["processing-summary"]
    XCTAssertTrue(summary.waitForExistence(timeout: 10))
    XCTAssertLessThan(processed(summary), 2, "처리를 늦췄으므로 아직 읽는 중이어야 한다")
    XCTAssertFalse(listBeside(), "세로 창은 한 화면씩 보인다")

    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(twoPhotoHeader().waitForExistence(timeout: 10), "돌린 뒤에도 같은 초안")
    XCTAssertTrue(summary.exists)
    XCTAssertEqual(listBeside(), expectWideLandscape, "넓은 가로 창에서만 목록과 초안이 나란히 보인다")
    snapshot("ios-adaptive-landscape-reading")

    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(twoPhotoHeader().waitForExistence(timeout: 10), "되돌린 뒤에도 같은 초안")
    waitFor(timeout: 60) { self.processed(summary) == 2 }
    let confirm = app.buttons["item-1-debug-confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 10))
    confirm.tap()
    waitFor(timeout: 30) { self.app.staticTexts["item-1-status"].label == "확인함" }
    snapshot("ios-adaptive-portrait-read")
  }

  /// 올릴 곳·장수 최종 확인 창이 열린 채 돌려도 같은 문장으로 남고, 한 번 올리면 한 번만 올라간다.
  func testA3_UploadConfirmationSurvivesRotation() throws {
    app.activate()
    openLink("nonanona://invite/SYNTHINVITE01")
    app.buttons["invite-primary"].tap()
    let apple = app.buttons["login-apple"]
    XCTAssertTrue(apple.waitForExistence(timeout: 10))
    apple.tap()
    XCTAssertTrue(app.staticTexts["참여함"].waitForExistence(timeout: 15))
    goBack()
    openTwoPhotoDraft()

    let start = app.buttons["upload-start"]
    XCTAssertTrue(start.waitForExistence(timeout: 10))
    start.tap()
    let title = app.staticTexts["‘가상 도쿄 여행’에 영수증 1장을 올릴까요?"]
    // iOS 27 알림은 버튼 안에 같은 식별자의 버튼을 하나 더 둔다. 첫 번째만 본다.
    let final = app.buttons.matching(identifier: "upload-final").firstMatch
    XCTAssertTrue(final.waitForExistence(timeout: 10))
    XCTAssertTrue(title.exists)

    // 열린 확인 창을 가로(넓은 창이면 크기 종류도 바뀜)와 세로로 돌린다. 창은 계속 보이고 눌려야 한다.
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(final.waitForExistence(timeout: 10), "돌린 뒤에도 같은 올릴 곳·장수를 묻는다")
    waitFor(timeout: 10) { title.exists && final.isHittable }
    snapshot("ios-adaptive-landscape-confirmation")
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(final.waitForExistence(timeout: 10))
    waitFor(timeout: 10) { title.exists && final.isHittable }
    final.tap()

    let status = app.staticTexts["upload-status"]
    waitFor(timeout: 30) { status.exists && status.label == "올림 1장(이미 올린 0장 포함)" }
    XCTAssertFalse(title.exists)
  }

  /// 큰 글자 + 가로(낮은 창): 초안의 마지막 행과 로그인 시트의 버튼까지 스크롤로 닿는다.
  func testA4_LargeTextLandscapeScrollsToEveryControl() throws {
    app.activate()
    XCUIDevice.shared.orientation = .landscapeLeft
    if !listBeside() { goBackToList() }
    openTwoPhotoDraft()
    XCTAssertTrue(scrollTo(app.staticTexts["item-2-status"], in: app.collectionViews["draft-screen"]).isHittable)
    snapshot("ios-adaptive-large-text-landscape-draft")

    // 세션 만료 초대(첫 시도만 실패)로 로그인 시트를 연다.
    openLink("nonanona://invite/SYNTHSESSION01")
    app.buttons["invite-primary"].tap()
    let relogin = app.buttons.matching(NSPredicate(format: "label == '다시 로그인하기'")).firstMatch
    XCTAssertTrue(relogin.waitForExistence(timeout: 10))
    relogin.tap()
    let apple = app.buttons["login-apple"]
    XCTAssertTrue(apple.waitForExistence(timeout: 10))
    XCTAssertTrue(scrollTo(apple, in: app.scrollViews.firstMatch).isHittable, "낮은 창의 시트도 스크롤로 로그인 버튼에 닿는다")
    snapshot("ios-adaptive-large-text-landscape-login")
    apple.tap()
    XCTAssertTrue(app.staticTexts["참여함"].waitForExistence(timeout: 15))
  }

  // MARK: iPhone Duo 자세
  //
  // 자세는 `simctl`·XCTest로 바꿀 수 없어 Device Hub의 자세 버튼을 눌러야 한다(`scripts/e2e-posture.sh`).
  // 테스트가 `<POSTURE_DIR>/want-<단계>`를 쓰면 스크립트가 버튼을 누르고 `done-<단계>`를 쓴다.
  // 버튼에 접근성 이름이 없어 Device Hub가 그리는 기기 모양으로 부른다: folded(접음, 바깥 화면),
  // book(두 번째 버튼, 안쪽 화면이 접힘에서 꺾임), flat(세 번째 버튼, 안쪽 화면이 평평함).
  // XCTest 화면 기록은 바깥 화면만 찍어(안쪽 화면을 쓰면 검은 화면) book·flat 화면은 스크립트가 simctl로 찍는다.

  /// 읽는 중에 folded → book → flat → folded를 지나도 같은 초안(사진 2장)과 처리 상태가 보인다.
  /// 안쪽 화면(가로 regular)에서는 목록과 초안이 나란히, book에서는 요약·사진 상태가 division 밖에 있다.
  func testP2_PostureChangeWhileReadingKeepsDraftAndProgress() throws {
    app.activate()
    openTwoPhotoDraft()
    let summary = app.staticTexts["processing-summary"]
    XCTAssertTrue(summary.waitForExistence(timeout: 10))
    XCTAssertLessThan(processed(summary), 2, "처리를 늦췄으므로 아직 읽는 중이어야 한다")
    let folded = app.windows.firstMatch.frame
    XCTAssertFalse(listBeside(), "바깥 화면은 한 화면씩 보인다")
    record("folded-reading", summary)
    snapshot("ios-posture-folded-reading")

    for step in ["book", "flat"] {
      awaitPosture(step)
      XCTAssertTrue(twoPhotoHeader().waitForExistence(timeout: 10), "\(step): 같은 초안")
      waitFor(timeout: 10) { self.app.windows.firstMatch.frame.width > folded.width && self.listBeside() }
      XCTAssertTrue(summary.exists)
      let progress = processed(summary)
      XCTAssertLessThan(progress, 2, "\(step): 아직 읽는 중(자세 변경을 처리 중에 지난다)")
      record("\(step)-reading", summary)
      assertOffDivision([summary, app.staticTexts["item-1-status"]], step, enforce: step == "book")
      record("\(step)-list", app.buttons["draft-row"].firstMatch)
    }

    awaitPosture("folded")
    XCTAssertTrue(twoPhotoHeader().waitForExistence(timeout: 10), "다시 접은 뒤에도 같은 초안")
    waitFor(timeout: 10) { self.app.windows.firstMatch.frame == folded && !self.listBeside() }
    XCTAssertTrue(summary.exists)
    record("refolded-reading", summary)
    snapshot("ios-posture-refolded-reading")
    waitFor(timeout: 240) { self.processed(summary) == 2 }
    let confirm = app.buttons["item-1-debug-confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 10))
    confirm.tap()
    waitFor(timeout: 30) { self.app.staticTexts["item-1-status"].label == "확인함" }
  }

  /// 올릴 곳·장수 최종 확인 창이 열린 채 book → flat → folded를 지나도 같은 문장으로 남고(book에서는 division 밖),
  /// 한 번 올리면 한 번만 올라간다.
  func testP3_UploadConfirmationSurvivesPostureChange() throws {
    app.activate()
    openLink("nonanona://invite/SYNTHINVITE01")
    app.buttons["invite-primary"].tap()
    let apple = app.buttons["login-apple"]
    XCTAssertTrue(apple.waitForExistence(timeout: 10))
    apple.tap()
    XCTAssertTrue(app.staticTexts["참여함"].waitForExistence(timeout: 15))
    goBack()
    openTwoPhotoDraft()

    let start = app.buttons["upload-start"]
    XCTAssertTrue(start.waitForExistence(timeout: 10))
    start.tap()
    let title = app.staticTexts["‘가상 도쿄 여행’에 영수증 1장을 올릴까요?"]
    let final = app.buttons.matching(identifier: "upload-final").firstMatch
    XCTAssertTrue(final.waitForExistence(timeout: 10))
    XCTAssertTrue(title.exists)
    record("folded-confirmation", final)
    snapshot("ios-posture-folded-confirmation")

    for step in ["book", "flat", "folded"] {
      awaitPosture(step)
      XCTAssertTrue(final.waitForExistence(timeout: 10), "\(step): 같은 올릴 곳·장수를 묻는다")
      waitFor(timeout: 10) { title.exists && final.isHittable }
      record("\(step)-confirmation", final)
      if step == "folded" { snapshot("ios-posture-refolded-confirmation") }
      if step != "folded" { assertOffDivision([title, final], step, enforce: step == "book") }
    }
    final.tap()

    let status = app.staticTexts["upload-status"]
    waitFor(timeout: 30) { status.exists && status.label == "올림 1장(이미 올린 0장 포함)" }
    XCTAssertFalse(title.exists)
  }

  private var postureDir: URL? {
    ProcessInfo.processInfo.environment["POSTURE_DIR"].map { URL(fileURLWithPath: $0) }
  }

  /// 스크립트에 자세 변경을 부탁하고, 바꿨다는 표시가 올 때까지 기다린다.
  private func awaitPosture(_ step: String) {
    guard let dir = postureDir else { return XCTFail("POSTURE_DIR 없음") }
    let name = "\(name.contains("testP2") ? "P2" : "P3")-\(step)"
    FileManager.default.createFile(atPath: dir.appendingPathComponent("want-\(name)").path, contents: Data())
    let done = dir.appendingPathComponent("done-\(name)").path
    let deadline = Date().addingTimeInterval(180)
    let failed = dir.appendingPathComponent("failed-\(name)").path
    while !FileManager.default.fileExists(atPath: done) {
      XCTAssertFalse(FileManager.default.fileExists(atPath: failed), "Device Hub 자세 버튼(\(step))을 누르지 못했다")
      XCTAssertLessThan(Date(), deadline, "자세 변경(\(step))을 기다리다 시간이 다 됐다")
      Thread.sleep(forTimeInterval: 0.3)
    }
  }

  /// 창 크기와 요소 위치를 기록한다(증거).
  private func record(_ label: String, _ element: XCUIElement) {
    let window = app.windows.firstMatch.frame
    print("POSTURE \(label) window=\(window) element=\(element.identifier) frame=\(element.frame)", terminator: "")
    print(" label=\(element.label)")
  }

  /// 요소가 division 예약 영역과 겹치지 않는다. XCTest는 예약 영역을 읽지 못한다. 앱 DEBUG 로그(`Theme.swift`)가
  /// book 자세에서 알린 영역(창 가운데 40pt, 951pt 창의 455.5–495.5)을 쓴다. `enforce == false`면 기록만 한다.
  private func assertOffDivision(_ elements: [XCUIElement], _ step: String, enforce: Bool) {
    let window = app.windows.firstMatch.frame
    let division = CGRect(x: window.midX - 20, y: window.minY, width: 40, height: window.height)
    for element in elements where element.exists {
      let f = element.frame
      let name = element.identifier.isEmpty ? element.label : element.identifier
      print("POSTURE \(step) division=\(division) \(name)=\(f) overlaps=\(f.intersects(division))")
      guard enforce else { continue }
      XCTAssertFalse(f.intersects(division), "\(step): \(name)이 division 위에 있다 \(f)")
    }
  }

  private func twoPhotoHeader() -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label == '사진 2장'")).firstMatch
  }

  private func openTwoPhotoDraft() {
    let row = app.buttons.matching(NSPredicate(format: "identifier == 'draft-row' AND label CONTAINS '사진 2장'"))
      .firstMatch
    XCTAssertTrue(app.collectionViews["home-screen"].waitForExistence(timeout: 10))
    scrollTo(row, in: app.collectionViews["home-screen"]).tap()
    // 큰 글자의 낮은 창에서는 사진 목록 머리말이 화면 밖일 수 있다. 맨 위의 처리 요약(…/2)으로 같은 초안인지 본다.
    let summary = app.staticTexts["processing-summary"]
    waitFor(timeout: 10) { summary.exists && summary.label.hasSuffix("/2") }
  }

  /// 목록(홈)과 고른 화면이 함께 보이는지. 쌓인 화면에서는 목록의 행이 눌리지 않는다.
  private func listBeside() -> Bool {
    let row = app.buttons["draft-row"].firstMatch
    return app.collectionViews["draft-screen"].exists && row.exists && row.isHittable
  }

  private func goBack() {
    if !listBeside() { backButton().tap() }
  }

  private func goBackToList() {
    for _ in 0..<3 where !app.buttons["draft-row"].firstMatch.isHittable {
      backButton().tap()
    }
  }

  /// iPhone Duo 바깥 화면처럼 막대가 옆(세로)에 놓이면 뒤로 버튼은 내비게이션 막대가 아니라 세로 도구 막대에 있다.
  private func backButton() -> XCUIElement {
    let vertical = app.buttons["BackButton"].firstMatch
    return vertical.exists ? vertical : app.navigationBars.buttons.element(boundBy: 0)
  }

  private func processed(_ summary: XCUIElement) -> Int {
    guard let r = summary.label.range(of: #"읽음 (\d+)/"#, options: .regularExpression) else { return -1 }
    return Int(String(summary.label[r].dropFirst(3).prefix { $0.isNumber })) ?? -1
  }

  /// 목록·시트의 내용은 화면 밖이면 접근성 트리에 없다. 보일 때까지 그 영역을 넘긴다.
  @discardableResult
  private func scrollTo(_ element: XCUIElement, in area: XCUIElement) -> XCUIElement {
    for up in [true, false] {
      for _ in 0..<8 {
        if element.exists && element.isHittable { return element }
        up ? area.swipeUp(velocity: .slow) : area.swipeDown(velocity: .slow)
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
