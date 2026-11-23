import PhotosUI
import ReceiptImport
import SwiftUI

struct HomeView: View {
  @Bindable var model: AppModel
  @State private var pickedItems: [PhotosPickerItem] = []

  var body: some View {
    // 고른 행은 모델의 selection으로만 나타낸다. 넓은 창에서는 고른 행이 강조되고, 좁은 창에서는 그 화면이 위에 쌓인다.
    List(selection: $model.selection) {
      Section {
        if let session = model.session {
          StatusLabel("로그인됨 · \(session.displayName)", role: .positive)
            .accessibilityIdentifier("account-status")
        } else {
          StatusLabel("로그인 안 됨", role: .neutral)
            .accessibilityIdentifier("account-status")
        }
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 0, leading: Spacing.m, bottom: 0, trailing: Spacing.m))

      if model.pendingInvite != nil {
        Section {
          PendingInviteCard { model.selection = .invite }
        }
      }

      if model.session != nil {
        TripListSection(trips: model.rooms.tripList, failure: model.rooms.listFailure, onOpen: model.openTrip)
      }

      Section {
        if model.loaded && model.drafts.isEmpty {
          DraftsEmptyView()
        }
        ForEach(model.drafts) { draft in
          NavigationLink(value: Route.draft(draft.id)) {
            DraftRow(draft: draft, firstPhoto: model.graph.drafts.photoURLs(of: draft).first)
          }
          .accessibilityIdentifier("draft-row")
        }
      } header: {
        Text("영수증 초안").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      }
    }
    // 분할 보기의 사이드바 기본 모양(sidebar) 대신 지금 디자인의 그룹 목록을 그대로 쓴다.
    .listStyle(.insetGrouped)
    .accessibilityIdentifier("home-screen")
    .adaptiveContentMargins()
    .navigationTitle("노나노나")
    .toolbar {
      ToolbarItem(placement: .bottomBar) {
        PhotosPicker(
          selection: $pickedItems, maxSelectionCount: ReceiptDraftStore.maxPhotos, matching: .images
        ) {
          // 하단 막대는 Label을 아이콘만으로 줄이므로 글자로 보여 준다(Android와 같은 동작 이름).
          Text("사진 고르기")
        }
        .accessibilityIdentifier("pick-photos")
      }
    }
    .onChange(of: pickedItems) { _, items in
      guard !items.isEmpty else { return }
      pickedItems = []
      Task { await importPicked(items) }
    }
    .alert("사진을 초안에 담지 못했어요. 다시 시도해 주세요.", isPresented: $model.importFailed) {
      Button("확인", role: .cancel) {}
    }
  }

  private func importPicked(_ items: [PhotosPickerItem]) async {
    var photos: [IncomingPhoto] = []
    for item in items {
      guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
      let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "img"
      photos.append(IncomingPhoto(fileExtension: ext, content: .data(data)))
    }
    model.importPhotos(photos, source: .picker)
  }
}
