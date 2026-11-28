import SwiftUI

/// 화면 아래에 고정되는 주 동작 막대. 위에 한 줄 안내(누르면 무엇이 생기는지, 또는 왜 누를 수 없는지), 아래에 주 버튼 하나.
/// 버튼은 쓰는 쪽이 `Button`으로 넘기고 막대가 주 버튼 모양을 입힌다. 누를 수 없으면 버튼에 `.disabled(true)`를 건다.
/// `safeAreaInset`으로 붙여 스크롤 목록 끝이 막대 높이만큼 저절로 비고, 바탕은 홈 표시 막대 자리까지 내려간다.
struct BottomBar<Note: View, Action: View>: View {
  @ViewBuilder var note: Note
  @ViewBuilder var action: Action

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.s) {
      note
      action.buttonStyle(.primaryAction)
    }
    .padding(Spacing.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      Palette.container
        .shadow(color: Elevation.sheetColor, radius: Elevation.sheetRadius, y: Elevation.sheetY)
        .ignoresSafeArea(edges: .bottom)
    }
  }
}

extension BottomBar where Note == BottomBarNote {
  init(note: String?, @ViewBuilder action: () -> Action) {
    self.init(note: { BottomBarNote(text: note) }, action: action)
  }
}

struct BottomBarNote: View {
  let text: String?

  var body: some View {
    if let text {
      Text(text).textRole(.supporting).foregroundStyle(Palette.contentSecondary)
    }
  }
}

extension View {
  /// 이 화면 아래에 BottomBar를 고정한다.
  func bottomBar<Action: View>(note: String? = nil, @ViewBuilder action: () -> Action) -> some View {
    safeAreaInset(edge: .bottom, spacing: 0) { BottomBar(note: note, action: action) }
  }
}

#if DEBUG
  struct BottomBarSamples: View {
    var enabled = true

    var body: some View {
      List {
        ForEach(1..<30) { Text("사진 \($0)").textRole(.body) }
      }
      .listStyle(.plain)
      .bottomBar(
        note: enabled ? "확인하면 가린 사본을 만들어요. 원본은 이 기기에만 남아요." : "줄 합계가 영수증 합계와 ¥60 달라요."
      ) {
        Button("확인하고 다음") {}.disabled(!enabled)
      }
    }
  }

  #Preview("라이트") { BottomBarSamples() }
  #Preview("다크") { BottomBarSamples(enabled: false).preferredColorScheme(.dark) }
  #Preview("큰 글자") { BottomBarSamples().dynamicTypeSize(.accessibility3) }
#endif
