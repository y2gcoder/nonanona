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
  case failed(SignInFailure)
}

enum UploadState: Equatable {
  case idle
  case uploading
  case done(created: Int, replayed: Int)
  case failed(ReceiptUploadFailure, uploadedBefore: Int)
}

enum JoinState: Equatable {
  case idle
  case joining
  case failed(InviteAcceptFailure)
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
  /// 초안별 사진 처리 상태. 처리기가 디스크에 쓴 뒤 알려 준다.
  private(set) var processing: [String: ProcessingManifest] = [:]
  private var processors: [String: ReceiptProcessor] = [:]
  /// 초안별 올리기 상태. 개발용 올리기 화면이 쓴다.
  private(set) var uploads: [String: UploadState] = [:]

  let graph: AppGraph
  var signInProviders: [SignInProvider] { graph.auth.providers }
  var testOnlyNotice: String? { graph.auth.testOnlyNotice }

  init(graph: AppGraph) {
    self.graph = graph
  }

  func load() async {
    drafts = graph.drafts.list()
    startProcessing()
    pendingInvite = graph.joinFlow.pendingInvite()
    session = await graph.joinFlow.restoreSession()
    loaded = true
    // 로그인 도중 앱이 종료됐다면 다시 열 때 그 초대 화면으로 돌아간다.
    if pendingInvite != nil, !path.contains(.invite) { path.append(.invite) }
  }

  /// 공유 확장이 App Group에 초안을 더했을 수 있으므로 앱이 앞으로 올 때마다 다시 읽는다.
  func reloadDrafts() {
    drafts = graph.drafts.list()
    startProcessing()
  }

  /// 처리할 사진이 남은 초안마다 처리기를 만들어 돌린다. 처리기를 만들 때 끝나지 않은 사진을 대기열로 되돌린다.
  func startProcessing() {
    for draft in drafts {
      if let processor = processors[draft.id] {
        Task { await processor.run() }
        continue
      }
      let processor: ReceiptProcessor
      do {
        processor = try ReceiptProcessor(
          store: graph.drafts, draft: draft, recognizer: graph.recognizer, hooks: graph.processingHooks,
          onChange: { [weak self] manifest in Task { @MainActor in self?.processing[manifest.draftID] = manifest } })
      } catch {
        continue
      }
      processors[draft.id] = processor
      Task {
        processing[draft.id] = await processor.snapshot()
        await processor.run()
      }
    }
  }

  /// 확인한 영수증을 참여한 여행방에 올린다. 사용자가 올릴 곳과 장수를 보고 최종 확인한 뒤에만 부른다.
  /// 기기 경계(`outboundReceipts`)를 지난 가림 사본과 허용 필드만 보낸다. 한 장이라도 실패하면 거기서 멈춘다.
  func uploadConfirmedReceipts(draftID: String, to room: TripRoom) async {
    guard let processor = processors[draftID], uploads[draftID] != .uploading else { return }
    uploads[draftID] = .uploading
    let outbound: [OutboundReceipt]
    do {
      outbound = try await processor.outboundReceipts()
    } catch {
      uploads[draftID] = .failed(.unknown, uploadedBefore: 0)
      return
    }
    var created = 0
    var replayed = 0
    for item in outbound {
      let fields = item.receipt.fields
      let upload = ReceiptExpenseUpload(
        requestID: ReceiptExpenseUpload.requestID(trip: room.id, artifactSHA256: item.receipt.artifactSHA256),
        date: fields.date, amountMinor: fields.amountMinor, currency: fields.currency, merchant: fields.merchant,
        artifactPNG: item.artifactPNG, artifactSHA256: item.receipt.artifactSHA256)
      do {
        let result = try await graph.trips.submitReceipt(upload, to: room.id)
        if result.replayed { replayed += 1 } else { created += 1 }
      } catch {
        let failure = error as? ReceiptUploadFailure ?? .unknown
        if failure == .sessionExpired {
          // 세션만 지운다. 초안·확인한 사본은 그대로이고, 다시 로그인한 뒤 같은 요청 키로 다시 올린다.
          await graph.auth.endSession()
          session = nil
        }
        uploads[draftID] = .failed(failure, uploadedBefore: created + replayed)
        return
      }
    }
    uploads[draftID] = .done(created: created, replayed: replayed)
  }

  /// 실패한 사진 한 장만 다시 읽는다.
  func retryPhoto(draftID: String, itemID: String) {
    guard let processor = processors[draftID] else { return }
    Task {
      try? await processor.retry(itemID)
      await processor.run()
    }
  }

  #if DEBUG
    /// 검토 화면이 정해지기 전의 개발용 확인: 제안된 값과 가림을 그대로 확인한다. release 빌드에는 없다.
    func debugConfirmWithSuggestions(draftID: String, itemID: String) {
      guard let processor = processors[draftID] else { return }
      Task {
        guard let proposal = try? await processor.proposal(itemID) else { return }
        _ = try? await processor.confirm(
          itemID, fields: proposal.fields, maskLineIDs: Set(proposal.suggestedMaskLineIDs))
      }
    }
  #endif

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
    let previous = login
    login = .signingIn
    let result: SignInResult
    do {
      result = try await graph.joinFlow.signIn(with: provider)
    } catch {
      // 화면을 떠나 작업이 취소됐다. 상태만 되돌리고 아무것도 지우지 않는다.
      login = previous
      return
    }
    switch result {
    case .signedIn(let session):
      self.session = session
      login = .hidden
      await joinPendingInvite()
    // 취소는 오류로 보이지 않고 고르기 상태로 돌아간다. 초안과 보관한 초대는 그대로다.
    case .failed(.cancelled):
      login = .choosing
    case .failed(let failure):
      login = .failed(failure)
    }
  }

  func joinPendingInvite() async {
    join = .joining
    let result: JoinResult
    do {
      result = try await graph.joinFlow.joinPendingInvite()
    } catch {
      join = .idle
      return
    }
    switch result {
    case .joined(let room):
      self.room = room
      pendingInvite = nil
      join = .idle
      path = [.room]
    case .noPendingInvite:
      join = .idle
    case .failed(let failure):
      switch failure {
      // 세션만 지웠다. 초대 화면에서 다시 로그인하면 같은 초대로 이어서 참여한다.
      case .sessionExpired: session = nil
      // 초대를 지웠다. 홈의 초대 카드도 사라진다.
      case .inviteExpired, .inviteInvalid: pendingInvite = nil
      case .network, .unavailable, .unknown: break
      }
      join = .failed(failure)
    }
  }
}
