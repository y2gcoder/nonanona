import SwiftUI
import UIKit

/// 글자 역할. 토큰(DesignTokens.Typography)의 크기·줄높이·굵기·자간을 Pretendard로 그린다.
/// 토큰 크기는 기본 글자 크기(Large)의 값이고, `textStyle`의 비율로 Dynamic Type을 따라 커지고 작아진다.
/// `routeCode`만 시스템 고정폭 글꼴이다(tokens.json 대체 글꼴 `ui-monospace`).
enum TextRole: CaseIterable {
  case screenTitle
  case heading
  case sectionTitle
  case amountHero
  case amount
  case rowTitle
  case button
  case body
  case bodyStrong
  case chip
  case supporting
  case status
  case routeCode

  var token: DesignTokens.TypeStyleToken {
    switch self {
    case .screenTitle: DesignTokens.Typography.screenTitle
    case .heading: DesignTokens.Typography.heading
    case .sectionTitle: DesignTokens.Typography.sectionTitle
    case .amountHero: DesignTokens.Typography.amountHero
    case .amount: DesignTokens.Typography.amount
    case .rowTitle: DesignTokens.Typography.rowTitle
    case .button: DesignTokens.Typography.button
    case .body: DesignTokens.Typography.body
    case .bodyStrong: DesignTokens.Typography.bodyStrong
    case .chip: DesignTokens.Typography.chip
    case .supporting: DesignTokens.Typography.supporting
    case .status: DesignTokens.Typography.status
    case .routeCode: DesignTokens.Typography.routeCode
    }
  }

  /// 커지는 비율을 빌려 올 시스템 텍스트 스타일. 기본 크기가 토큰 크기와 가장 가까운 것이다.
  var textStyle: UIFont.TextStyle {
    switch self {
    case .amountHero: .largeTitle
    case .screenTitle, .heading: .title1
    case .sectionTitle: .headline
    case .amount: .body
    case .rowTitle, .button: .callout
    case .body, .bodyStrong, .chip: .subheadline
    case .supporting: .footnote
    case .status: .caption1
    case .routeCode: .caption2
    }
  }

  /// 금액은 숫자 폭을 맞춰(표 정렬) 열이 흔들리지 않게 한다.
  var isAmount: Bool { self == .amountHero || self == .amount }

  /// 이 역할의 Pretendard PostScript 이름. 고정폭(`routeCode`)은 nil.
  var fontName: String? {
    guard self != .routeCode else { return nil }
    return Pretendard.name(weight: token.fontWeight)
  }

  var font: Font {
    let font: Font
    if let fontName {
      font = .custom(fontName, size: token.fontSize, relativeTo: Font.TextStyle(textStyle))
    } else {
      font = .system(Font.TextStyle(textStyle), design: .monospaced, weight: .medium)
    }
    return isAmount ? font.monospacedDigit() : font
  }

  /// 글자 크기 설정 하나에서의 값(pt). 줄높이와 자간도 글자 크기와 같은 비율로 커진다.
  func metrics(for size: DynamicTypeSize) -> TextMetrics {
    let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
    let scale = UIFontMetrics(forTextStyle: textStyle)
    let pointSize = scale.scaledValue(for: token.fontSize, compatibleWith: traits)
    let uiFont =
      fontName.flatMap { UIFont(name: $0, size: pointSize) }
      ?? .monospacedSystemFont(ofSize: pointSize, weight: .medium)
    return TextMetrics(
      pointSize: pointSize,
      lineHeight: scale.scaledValue(for: token.lineHeight, compatibleWith: traits),
      naturalLineHeight: uiFont.lineHeight,
      tracking: token.letterSpacing * pointSize
    )
  }
}

struct TextMetrics: Equatable {
  let pointSize: CGFloat
  let lineHeight: CGFloat
  let naturalLineHeight: CGFloat
  let tracking: CGFloat

  /// 토큰 줄높이를 맞추려고 더하는 행간. 반은 첫 줄 위, 반은 마지막 줄 아래에 둔다.
  var leading: CGFloat { max(0, lineHeight - naturalLineHeight) }
}

enum Pretendard {
  /// 앱에 넣은 굵기는 400·700·800뿐이다(Info.plist `UIAppFonts`).
  static func name(weight: Int) -> String {
    switch weight {
    case ...550: "Pretendard-Regular"
    case ...750: "Pretendard-Bold"
    default: "Pretendard-ExtraBold"
    }
  }
}

extension View {
  func textRole(_ role: TextRole) -> some View { modifier(TextRoleModifier(role: role)) }
}

private struct TextRoleModifier: ViewModifier {
  let role: TextRole
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  func body(content: Content) -> some View {
    let metrics = role.metrics(for: dynamicTypeSize)
    content
      .font(role.font)
      .tracking(metrics.tracking)
      .lineSpacing(metrics.leading)
      .padding(.vertical, metrics.leading / 2)
  }
}

extension Font.TextStyle {
  fileprivate init(_ style: UIFont.TextStyle) {
    self =
      switch style {
      case .largeTitle: .largeTitle
      case .title1: .title
      case .title2: .title2
      case .title3: .title3
      case .headline: .headline
      case .callout: .callout
      case .subheadline: .subheadline
      case .footnote: .footnote
      case .caption1: .caption
      case .caption2: .caption2
      default: .body
      }
  }
}
