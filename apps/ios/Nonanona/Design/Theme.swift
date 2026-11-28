import SwiftUI
import UIKit

// 공통 디자인 기준의 역할을 생성된 토큰(DesignTokens.swift, 원본 design/tokens.json)에 연결한다.
// 역할 이름은 docs/design/mobile-foundations.md와 Android `Theme.kt`가 같이 쓴다. 값은 토큰 파일 하나에서 바꾼다.

/// 색 역할. 토큰 이름이 곧 역할 이름이고, 라이트·다크는 기기 설정을 따라 저절로 바뀐다.
typealias Palette = DesignTokens.Colors

/// 간격 역할(pt = Android dp).
enum Spacing {
  static let xs = DesignTokens.Spacing.spaceXs
  static let s = DesignTokens.Spacing.spaceS
  static let m = DesignTokens.Spacing.spaceM
  static let l = DesignTokens.Spacing.spaceL
  static let xl = DesignTokens.Spacing.spaceXl
}

typealias Radius = DesignTokens.Radius
typealias Size = DesignTokens.Size

/// 하단 시트와 하단 고정 막대의 그림자(tokens.json `shadow-sheet`). 생성기가 그림자를 내보내지 않아 값을 옮겨 둔다.
/// CSS `0 -2px 16px`의 흐림 16은 SwiftUI 반지름 8에 해당한다.
enum Elevation {
  static let sheetColor = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(white: 0, alpha: 0.4) : UIColor(red: 25 / 255, green: 31 / 255, blue: 40 / 255, alpha: 0.08)
    })
  static let sheetRadius: CGFloat = 8
  static let sheetY: CGFloat = -2
}

extension View {
  /// 앱 맨 위에 한 번 건다. 시스템 글자색 단계(`.primary`·`.secondary`·`.tertiary`)와 tint를 토큰 색으로 바꿔,
  /// 아직 부품으로 바꾸지 않은 화면도 같은 색을 쓰게 한다.
  func nonanonaTheme() -> some View {
    foregroundStyle(Palette.content, Palette.contentSecondary, Palette.contentSecondary)
      .tint(Palette.ink)
  }
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
