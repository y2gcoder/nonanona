import SwiftUI

// 공통 디자인 기준(docs/design/mobile-foundations.md)의 역할을 SwiftUI 시스템 스타일에 연결한다.
// 색은 임시 중립 팔레트(시스템 라벨·배경색)다. 브랜드 색을 정하면 이 파일만 바꾼다.

/// 간격 역할. Android `Spacing`과 같은 값(pt = dp)을 쓴다.
enum Spacing {
  static let xs: CGFloat = 4
  static let s: CGFloat = 8
  static let m: CGFloat = 16
  static let l: CGFloat = 24
  static let xl: CGFloat = 32
}

/// 글자 역할. 시스템 텍스트 스타일을 써서 Dynamic Type을 따른다.
/// Android 대응: sectionTitle=titleMedium, body=bodyLarge, supporting=bodyMedium, caption=bodySmall, status=labelMedium.
enum TextRole {
  case sectionTitle
  case body
  case supporting
  case caption
  case status

  var font: Font {
    switch self {
    case .sectionTitle: .headline
    case .body: .body
    case .supporting: .subheadline
    case .caption: .footnote
    case .status: .caption.weight(.semibold)
    }
  }
}

extension View {
  func textRole(_ role: TextRole) -> some View { font(role.font) }
}

/// 상태는 색이 아니라 글자로 전달한다. 색은 보조 신호다.
enum StatusRole {
  case neutral
  case attention
  case positive
  case error
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
      .foregroundStyle(foreground)
      .padding(.horizontal, Spacing.s)
      .padding(.vertical, Spacing.xs)
      .background(background, in: Capsule())
  }

  private var foreground: Color {
    switch role {
    case .neutral: .secondary
    case .attention: Color(uiColor: .systemBackground)
    case .positive: .primary
    case .error: .red
    }
  }

  private var background: Color {
    switch role {
    case .neutral: Color(uiColor: .tertiarySystemFill)
    case .attention: .primary
    case .positive: Color(uiColor: .secondarySystemFill)
    case .error: Color.red.opacity(0.15)
    }
  }
}

/// 화면의 주 동작. 중립 팔레트에서는 라벨색 배경(라이트: 검정, 다크: 흰색)으로 그린다.
struct PrimaryActionStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .frame(maxWidth: .infinity, minHeight: 50)
      .padding(.horizontal, Spacing.m)
      .foregroundStyle(Color(uiColor: .systemBackground))
      .background(Color.primary.opacity(configuration.isPressed || !isEnabled ? 0.5 : 1), in: .rect(cornerRadius: 12))
  }
}

extension ButtonStyle where Self == PrimaryActionStyle {
  static var primaryAction: PrimaryActionStyle { PrimaryActionStyle() }
}
