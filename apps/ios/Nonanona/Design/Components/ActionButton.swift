import SwiftUI

/// 버튼 세 가지. 라임(`press`)은 누를 것, 네이비(`ink`)는 가벼운 이동이다.
/// 누를 수 없으면 `.disabled(true)`를 걸고, 왜 못 누르는지 한 줄 안내를 버튼 위에 둔다(BottomBar의 `note`).
struct ActionButtonStyle: ButtonStyle {
  enum Kind {
    /// 화면당 하나, 하단 고정 막대 안 전체 너비.
    case primary
    case secondary
    /// 바탕 없는 `ink` 글자. "가림 영역 더하기", "확인함".
    case text
  }

  let kind: Kind
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    switch kind {
    case .primary, .secondary:
      let shape = RoundedRectangle(cornerRadius: Radius.radiusL)
      configuration.label
        .textRole(.button)
        .multilineTextAlignment(.center)
        .foregroundStyle(isEnabled ? (kind == .primary ? Palette.onPress : Palette.content) : Palette.contentSecondary)
        .padding(.horizontal, Spacing.m)
        .frame(maxWidth: .infinity, minHeight: Size.buttonHeight)
        .background(isEnabled ? (kind == .primary ? Palette.press : Palette.container) : Palette.background, in: shape)
        .overlay { shape.strokeBorder(edge, lineWidth: 1) }
        .contentShape(shape)
        .opacity(configuration.isPressed ? 0.8 : 1)
    case .text:
      configuration.label
        .textRole(.bodyStrong)
        .foregroundStyle(isEnabled ? Palette.ink : Palette.contentSecondary)
        .frame(minHeight: Size.touchMin)
        .contentShape(.rect)
        .opacity(configuration.isPressed ? 0.6 : 1)
    }
  }

  private var edge: Color {
    if !isEnabled { return Palette.line }
    return kind == .primary ? Palette.pressEdge : .clear
  }
}

extension ButtonStyle where Self == ActionButtonStyle {
  static var primaryAction: ActionButtonStyle { ActionButtonStyle(kind: .primary) }
  static var secondaryAction: ActionButtonStyle { ActionButtonStyle(kind: .secondary) }
  static var textAction: ActionButtonStyle { ActionButtonStyle(kind: .text) }
}

#if DEBUG
  struct ActionButtonSamples: View {
    var body: some View {
      VStack(spacing: Spacing.m) {
        Button("정산 확정") {}.buttonStyle(.primaryAction)
        Button("다시 읽기") {}.buttonStyle(.secondaryAction)
        Button("확인하고 다음") {}.buttonStyle(.primaryAction).disabled(true)
        Button("가림 영역 더하기") {}.buttonStyle(.textAction)
      }
      .padding(Spacing.m)
    }
  }

  #Preview("라이트") { ActionButtonSamples() }
  #Preview("다크") { ActionButtonSamples().background(Palette.background).preferredColorScheme(.dark) }
  #Preview("큰 글자") { ActionButtonSamples().dynamicTypeSize(.accessibility3) }
#endif
