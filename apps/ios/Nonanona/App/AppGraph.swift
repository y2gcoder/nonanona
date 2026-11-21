import Foundation
import ReceiptImport

/// 앱 시작 지점. 저장소와 경계 구현체를 한 번만 만들어 연결한다.
/// debug 빌드는 테스트 구현체(`Testing/`), release 빌드는 연결 전 구현체를 쓴다.
struct AppGraph: Sendable {
  static let appGroup = "group.app.nonanona"

  let auth: any AuthGateway
  let drafts: ReceiptDraftStore
  let joinFlow: JoinFlow

  static func live() -> AppGraph {
    let support = URL.applicationSupportDirectory
    #if DEBUG
      let auth = TestAuthGateway(sessionFile: support.appending(path: "test-auth/session.json"))
      let trips: any TripGateway = TestTripGateway(auth: auth)
    #else
      let auth = UnavailableAuthGateway()
      let trips: any TripGateway = UnavailableTripGateway()
    #endif
    // App Group은 공유 확장과 초안을 주고받는 데 필요하다. 없으면(서명 설정 누락) 앱 폴더로 대신한다.
    let drafts =
      (try? ReceiptDraftStore.inAppGroup(appGroup))
      ?? ReceiptDraftStore(root: support.appending(path: "receipt-import"))
    let pending = PendingInviteStore(file: support.appending(path: "account/pending-invite.json"))
    return AppGraph(
      auth: auth, drafts: drafts, joinFlow: JoinFlow(auth: auth, trips: trips, pendingInvites: pending))
  }
}
