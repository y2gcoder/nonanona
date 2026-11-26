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

/// 스크롤 내용의 가로 여백. 창이 넓으면 읽기 좋은 폭(`readableWidth`, Android와 같은 값)으로 가운데에 두고,
/// 접히는 부분(`ReservedRegion` division)이 세로로 가로지르면 넓은 쪽에만 둔다. 기기 모델이 아니라 이 뷰의 크기와
/// 시스템이 알려 준 예약 영역만 본다. 시스템 분할 보기·시트는 접힘을 스스로 피하므로 그 안에서는 보통 여백 0이다.
struct ContentMargins: Equatable {
  static let readableWidth: CGFloat = 640

  var leading: CGFloat = 0
  var trailing: CGFloat = 0

  /// - Parameters:
  ///   - width: 이 뷰의 폭(pt).
  ///   - divisions: 이 뷰 좌표의 활성 division 영역. 세로로 긴 것(세로 접힘)만 피한다. 가로 접힘을 지나는 스크롤 목록은
  ///     어디에 두어도 접힘을 지나므로 피하지 않는다.
  static func fitting(width: CGFloat, divisions: [CGRect]) -> ContentMargins {
    var segments: [ClosedRange<CGFloat>] = [0...max(width, 0)]
    for region in divisions where region.height > region.width {
      segments = segments.flatMap { segment -> [ClosedRange<CGFloat>] in
        guard region.minX < segment.upperBound, region.maxX > segment.lowerBound else { return [segment] }
        var parts: [ClosedRange<CGFloat>] = []
        if region.minX > segment.lowerBound { parts.append(segment.lowerBound...region.minX) }
        if region.maxX < segment.upperBound { parts.append(region.maxX...segment.upperBound) }
        return parts
      }
    }
    // 같은 폭이면 앞쪽(leading)을 고른다. 넓은 쪽이 바뀔 때만 자리를 옮겨 큰 이동을 줄인다.
    guard let widest = segments.max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }) else {
      return ContentMargins()
    }
    let extra = max(0, (widest.upperBound - widest.lowerBound) - readableWidth) / 2
    return ContentMargins(leading: widest.lowerBound + extra, trailing: width - widest.upperBound + extra)
  }
}

extension View {
  /// 목록·스크롤 화면에 읽기 좋은 폭과 접힘 피하기를 건다. 좁은 창에서는 아무것도 바꾸지 않는다.
  /// `file`·`line`은 DEBUG 로그에서 어느 화면인지 가리는 데만 쓴다.
  func adaptiveContentMargins(file: StaticString = #fileID, line: UInt = #line) -> some View {
    modifier(AdaptiveContentMargins(site: "\(file):\(line)"))
  }
}

private struct AdaptiveContentMargins: ViewModifier {
  let site: String
  @State private var margins = ContentMargins()

  func body(content: Content) -> some View {
    content
      .contentMargins(.leading, margins.leading, for: .scrollContent)
      .contentMargins(.trailing, margins.trailing, for: .scrollContent)
      .onGeometryChange(for: ContentMargins.self) { proxy in
        var divisions: [CGRect] = []
        if #available(iOS 27.1, *) {
          divisions = proxy.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
        }
        return .fitting(width: proxy.size.width, divisions: divisions)
      } action: {
        margins = $0
      }
      #if DEBUG
        // 시스템이 알려 준 division 예약 영역을 비활성 것까지 남긴다(iPhone Duo 자세 E2E가 읽는다, 창 좌표).
        .onGeometryChange(for: String.self) { proxy in
          var regions = "unavailable"
          if #available(iOS 27.1, *) {
            let global = proxy.frame(in: .global)
            regions =
              proxy.reservedRegions(kind: .division, options: .includeInactive).map {
                "\($0.frame.offsetBy(dx: global.minX, dy: global.minY)) active=\($0.isActive)"
              }.description
          }
          return "site=\(site) view=\(proxy.frame(in: .global)) divisions=\(regions)"
        } action: {
          debugLayoutLog.debug("reserved \($0, privacy: .public)")
        }
      #endif
  }
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
