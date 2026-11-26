import Foundation
import ReceiptImport

/// 앱 시작 지점. 저장소와 경계 구현체를 한 번만 만들어 연결한다.
/// debug 빌드는 테스트 구현체(`Testing/`) 또는 로컬 Supabase 구현체(`LocalBackend/`), release 빌드는 연결 전 구현체를 쓴다.
struct AppGraph: Sendable {
  static let appGroup = "group.app.nonanona"

  let auth: any AuthGateway
  let trips: any TripGateway
  let settlement: any SettlementGateway
  let drafts: ReceiptDraftStore
  let joinFlow: JoinFlow
  let recognizer: any ReceiptRecognizer
  let processingHooks: ProcessingHooks
  /// 품목 이름 번역(기기 안). debug는 실행 환경 변수로 미리보기 대역을 고를 수 있다.
  var itemTranslator: any ItemNameTranslator = AppleItemTranslator()

  var previewRetranslation: (@Sendable ([String]) async throws -> [String?])?

  static func live() -> AppGraph {
    let support = URL.applicationSupportDirectory
    #if DEBUG
      // debug 빌드는 기본이 테스트 구현체다. Config/Local.xcconfig로 로컬 모드를 켜면 로컬 Supabase에 붙는다.
      let auth: any AuthGateway
      let trips: any TripGateway
      let settlement: any SettlementGateway
      if let local = LocalBackendConfig.fromBundle() {
        let session = LocalSupabaseSession(config: local, file: support.appending(path: "local-auth/session.json"))
        auth = LocalAuthGateway(session: session)
        trips = LocalTripGateway(
          session: session,
          failOnceAfterStorage: ProcessInfo.processInfo.environment["NONANONA_UPLOAD_FAIL_AFTER_STORAGE_ONCE"] == "1"
            ? LocalTripGateway.FailOnce() : nil)
        settlement = LocalSettlementGateway(session: session)
      } else {
        let test = TestAuthGateway(sessionFile: support.appending(path: "test-auth/session.json"))
        auth = test
        trips = TestTripGateway(auth: test)
        settlement = UnavailableSettlementGateway()
      }
    #else
      let auth = UnavailableAuthGateway()
      let trips: any TripGateway = UnavailableTripGateway()
      let settlement: any SettlementGateway = UnavailableSettlementGateway()
    #endif
    // App Group은 공유 확장과 초안을 주고받는 데 필요하다. 없으면(서명 설정 누락) 앱 폴더로 대신한다.
    #if DEBUG
      let writeFault = Self.debugFileFault()
      let readFault = Self.debugFileFault(listName: "debug-fail-reads")
    #else
      let writeFault: (@Sendable (URL) -> Bool)? = nil
      let readFault: (@Sendable (URL) -> Bool)? = nil
    #endif
    let drafts =
      (try? ReceiptDraftStore.inAppGroup(appGroup, writeFault: writeFault, readFault: readFault))
      ?? ReceiptDraftStore(
        root: support.appending(path: "receipt-import"), writeFault: writeFault, readFault: readFault)
    let pending = PendingInviteStore(file: support.appending(path: "account/pending-invite.json"))
    #if DEBUG
      let hooks = Self.debugProcessingHooks()
    #else
      let hooks = ProcessingHooks()
    #endif
    #if DEBUG
      // 시뮬레이터는 Apple Translation이 번역하지 않는다. 화면 흐름만 볼 때 정해 둔 사전(실제 번역 아님)을 쓴다.
      let translationMode = ProcessInfo.processInfo.environment["NONANONA_ITEM_TRANSLATION"] ?? ""
      let translator: any ItemNameTranslator =
        translationMode.hasPrefix("preview")
        ? PreviewItemTranslator(failOnce: translationMode == "preview-fail-once") : AppleItemTranslator()
    #else
      let translator: any ItemNameTranslator = AppleItemTranslator()
    #endif
    var graph = AppGraph(
      auth: auth, trips: trips, settlement: settlement, drafts: drafts,
      joinFlow: JoinFlow(auth: auth, trips: trips, pendingInvites: pending),
      recognizer: VisionReceiptRecognizer(), processingHooks: hooks, itemTranslator: translator)
    #if DEBUG
      if ProcessInfo.processInfo.environment["NONANONA_ITEM_RETRANSLATION"] == "preview" {
        graph.previewRetranslation = { names in names.map { PreviewItemTranslator.dictionary[$0] } }
      }
    #endif
    return graph
  }

  #if DEBUG
    /// 검증용 저장 실패 주입: 초안 저장소 폴더의 `debug-fail-writes` 파일에 적힌 경로 조각(줄마다, 예: `processing.json`,
    /// `reviews/`)이 들어간 파일 쓰기를 실패시킨다. 파일을 지우면 바로 돌아온다. E2E가 호스트에서 만들고 지운다(debug 빌드만).
    /// `listName`이 `debug-fail-reads`이면 같은 방식으로 있는 파일 읽기를 실패시킨다(품목 계획 읽기 실패 검증).
    static func debugFileFault(listName: String = "debug-fail-writes") -> @Sendable (URL) -> Bool {
      { url in
        var root = url.deletingLastPathComponent()
        while root.lastPathComponent != "receipt-import", root.pathComponents.count > 1 {
          root = root.deletingLastPathComponent()
        }
        guard let text = try? String(contentsOf: root.appending(path: listName), encoding: .utf8) else {
          return false
        }
        return text.split(whereSeparator: \.isNewline).contains { !$0.isEmpty && url.path.contains($0) }
      }
    }

    /// 검증용: 실행 환경 변수로 처리를 늦추거나, 한 위치의 첫 시도를 실패시키거나, 한 위치의 가림 제안을 비운다(debug 빌드만).
    static func debugProcessingHooks(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ProcessingHooks {
      ProcessingHooks(
        delayPerItem: .milliseconds(env["NONANONA_PROCESSING_DELAY_MS"].flatMap(Int.init) ?? 0),
        failFirstAttemptAtPosition: env["NONANONA_FAIL_FIRST_ATTEMPT_POSITION"].flatMap(Int.init),
        dropSuggestionsAtPosition: env["NONANONA_DROP_SUGGESTIONS_POSITION"].flatMap(Int.init))
    }
  #endif
}
