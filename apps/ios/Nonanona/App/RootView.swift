import SwiftUI

struct RootView: View {
  @Bindable var model: AppModel

  private func debugConfirm(_ draftID: String) -> ((String) -> Void)? {
    #if DEBUG
      return { model.debugConfirmWithSuggestions(draftID: draftID, itemID: $0) }
    #else
      return nil
    #endif
  }

  var body: some View {
    NavigationStack(path: $model.path) {
      HomeView(model: model)
        .navigationDestination(for: Route.self) { route in
          switch route {
          case .draft(let id):
            if let draft = model.drafts.first(where: { $0.id == id }) {
              DraftView(
                draft: draft, photoURLs: model.graph.drafts.photoURLs(of: draft),
                processing: model.processing[draft.id],
                onRetry: { model.retryPhoto(draftID: draft.id, itemID: $0) },
                onDebugConfirm: debugConfirm(draft.id),
                upload: DraftUploadContext(
                  destination: model.room,
                  confirmedCount: model.processing[draft.id]?.items.filter { $0.state == .confirmed }.count ?? 0,
                  state: model.uploads[draft.id] ?? .idle,
                  signedIn: model.session != nil,
                  onUpload: {
                    guard let room = model.room else { return }
                    Task { await model.uploadConfirmedReceipts(draftID: draft.id, to: room) }
                  },
                  onLogin: model.showLogin))
            }
          case .invite:
            InviteView(
              signedIn: model.session != nil, join: model.join,
              onLogin: model.showLogin,
              onJoin: { Task { await model.joinPendingInvite() } })
          case .room:
            if let room = model.room {
              TripRoomView(room: room, localDraftCount: model.drafts.count)
            }
          }
        }
    }
    .tint(.primary)
    .sheet(
      isPresented: Binding(
        get: { model.login != .hidden },
        set: { if !$0 { model.dismissLogin() } })
    ) {
      LoginSheet(
        state: model.login, providers: model.signInProviders, testOnlyNotice: model.testOnlyNotice,
        onSignIn: { provider in Task { await model.signIn(with: provider) } },
        onCancel: model.dismissLogin)
    }
  }
}
