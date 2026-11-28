import SwiftUI

@main
struct NonanonaApp: App {
  @State private var model = AppModel(graph: .live())
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if DesignGallery.isRequested {
          DesignGallery().nonanonaTheme()
        } else {
          root
        }
      #else
        root
      #endif
    }
  }

  private var root: some View {
    RootView(model: model)
      .task { await model.load() }
      .onOpenURL { model.handle(url: $0) }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active, model.loaded { model.reloadDrafts() }
      }
  }
}
