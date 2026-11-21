import Foundation
import Observation
import ReceiptImport

enum Route: Hashable {
  case draft(String)
  case invite
  case room
}

enum LoginState: Equatable {
  case hidden
  case choosing
  case signingIn
  case failed
}

enum JoinState: Equatable {
  case idle
  case joining
  case failed
}

/// 화면 상태와 화면 이동. 저장과 경계 호출은 저장소·`JoinFlow`에 맡긴다.
@MainActor @Observable
final class AppModel {
  var path: [Route] = []
  private(set) var loaded = false
  private(set) var drafts: [ReceiptDraft] = []
  private(set) var session: AccountSession?
  private(set) var pendingInvite: PendingInvite?
  private(set) var room: TripRoom?
  var login: LoginState = .hidden
  private(set) var join: JoinState = .idle
  var importFailed = false

  let graph: AppGraph
  var signInProviders: [SignInProvider] { graph.auth.providers }
  var testOnlyNotice: String? { graph.auth.testOnlyNotice }

  init(graph: AppGraph) {
    self.graph = graph
  }

  func load() async {
    drafts = graph.drafts.list()
    pendingInvite = graph.joinFlow.pendingInvite()
    session = await graph.joinFlow.restoreSession()
    loaded = true
    // 로그인 도중 앱이 종료됐다면 다시 열 때 그 초대 화면으로 돌아간다.
    if pendingInvite != nil, !path.contains(.invite) { path.append(.invite) }
  }

  /// 공유 확장이 App Group에 초안을 더했을 수 있으므로 앱이 앞으로 올 때마다 다시 읽는다.
  func reloadDrafts() {
    drafts = graph.drafts.list()
  }

  func handle(url: URL) {
    guard let code = InviteCode(link: url) else { return }
    do {
      pendingInvite = try graph.joinFlow.receiveInvite(code)
    } catch {
      return
    }
    room = nil
    join = .idle
    path = [.invite]
  }

  func importPhotos(_ photos: [IncomingPhoto], source: DraftSource) {
    do {
      try graph.drafts.create(source: source, photos: photos)
    } catch {
      importFailed = true
    }
    reloadDrafts()
  }

  func showLogin() { login = .choosing }

  func dismissLogin() {
    if login != .signingIn { login = .hidden }
  }

  func signIn(with provider: SignInProvider) async {
    login = .signingIn
    guard let session = try? await graph.joinFlow.signIn(with: provider) else {
      login = .failed
      return
    }
    self.session = session
    login = .hidden
    await joinPendingInvite()
  }

  func joinPendingInvite() async {
    join = .joining
    do {
      guard let room = try await graph.joinFlow.joinPendingInvite() else {
        join = .idle
        return
      }
      self.room = room
      pendingInvite = nil
      join = .idle
      path = [.room]
    } catch {
      join = .failed
    }
  }
}
