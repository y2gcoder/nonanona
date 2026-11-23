import SwiftUI

/// 목록(홈)과 고른 화면. 넓은 창(가로 regular)에서는 나란히, 좁거나 낮은 창에서는 한 화면씩 쌓인다.
/// `NavigationSplitView`가 크기 종류에 따라 접고 펴며 접히는 부분(예약 영역)에 맞춰 열 폭을 정한다.
/// 고른 화면은 모델의 `selection`(안정 ID)이므로 창 크기·접기·회전이 바뀌어도 같은 화면이 남는다.
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
    NavigationSplitView {
      HomeView(model: model)
        // 목록을 숨겨 고른 화면이 창 전체(접히는 부분 포함)를 쓰는 일이 없게 한다. 두 열은 시스템이 접힘에 맞춘다.
        .toolbar(removing: .sidebarToggle)
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    .tint(.primary)
    #if DEBUG
      .background(DebugHingeLog())
    #endif
    .modifier(uploadConfirmation)
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

  /// 최종 확인은 한 곳(여기)에서만 띄운다. 개발용 화면이 없는 release에서는 아무것도 하지 않는다.
  private var uploadConfirmation: some ViewModifier {
    #if DEBUG
      DebugUploadConfirmation(
        confirmation: model.uploadConfirmation, onConfirm: model.confirmUpload, onCancel: model.cancelUploadConfirmation
      )
    #else
      EmptyModifier()
    #endif
  }

  @ViewBuilder private var detail: some View {
    switch model.selection {
    case .draft(let id):
      if let draft = model.drafts.first(where: { $0.id == id }) {
        DraftView(
          draft: draft, photoURLs: model.graph.drafts.photoURLs(of: draft),
          processing: model.processing[draft.id],
          onRetry: { model.retryPhoto(draftID: draft.id, itemID: $0) },
          onDebugConfirm: debugConfirm(draft.id),
          upload: DraftUploadContext(
            destination: model.room,
            confirmedCount: model.confirmedCount(draftID: draft.id),
            state: model.uploads[draft.id] ?? .idle,
            signedIn: model.session != nil,
            onRequest: { model.requestUpload(draftID: draft.id) },
            onLogin: model.showLogin))
      } else {
        DetailPlaceholder()
      }
    case .invite:
      InviteView(
        signedIn: model.session != nil, join: model.join,
        onLogin: model.showLogin,
        onJoin: { Task { await model.joinPendingInvite() } })
    case .room:
      if let room = model.room {
        TripRoomView(room: room, localDraftCount: model.drafts.count)
      } else {
        DetailPlaceholder()
      }
    case nil:
      DetailPlaceholder()
    }
  }
}

/// 넓은 창에서 아직 아무것도 고르지 않았을 때 목록 옆에 보인다. 좁은 창에서는 보이지 않는다.
private struct DetailPlaceholder: View {
  var body: some View {
    ContentUnavailableView {
      Text("초안을 골라 주세요").textRole(.sectionTitle)
    } description: {
      Text("목록에서 초안을 고르면 여기에 보여요.").textRole(.supporting)
    }
    .accessibilityIdentifier("detail-placeholder")
  }
}
