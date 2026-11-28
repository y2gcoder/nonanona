import SwiftUI

/// 상태는 색이 아니라 글자로 전달한다. 색은 보조 신호다.
enum StatusRole: CaseIterable {
  case neutral
  case attention
  case positive
  case error

  var foreground: Color {
    switch self {
    case .neutral: Palette.neutral
    case .attention: Palette.attention
    case .positive: Palette.positive
    case .error: Palette.error
    }
  }

  var background: Color {
    switch self {
    case .neutral: Palette.container
    case .attention: Palette.attentionSoft
    case .positive: Palette.positiveSoft
    case .error: Palette.errorSoft
    }
  }
}

struct StatusLabel: View {
  let text: String
  let role: StatusRole

  init(_ text: String, role: StatusRole) {
    self.text = text
    self.role = role
  }

  var body: some View {
    Text(text)
      .textRole(.status)
      .foregroundStyle(role.foreground)
      .padding(.horizontal, Spacing.s)
      .padding(.vertical, Spacing.xs)
      .background(role.background, in: .rect(cornerRadius: Radius.radiusS))
  }
}

#if DEBUG
  struct StatusLabelSamples: View {
    var body: some View {
      VStack(alignment: .leading, spacing: Spacing.s) {
        StatusLabel("포함", role: .positive)
        StatusLabel("확인 필요", role: .attention)
        StatusLabel("읽지 못함", role: .error)
        StatusLabel("기기에만 저장됨", role: .neutral)
      }
      .padding(Spacing.m)
    }
  }

  #Preview("라이트") { StatusLabelSamples() }
  #Preview("다크") { StatusLabelSamples().background(Palette.background).preferredColorScheme(.dark) }
  #Preview("큰 글자") { StatusLabelSamples().dynamicTypeSize(.accessibility3) }
#endif
