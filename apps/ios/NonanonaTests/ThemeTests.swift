import SwiftUI
import Testing
import UIKit

@testable import Nonanona

struct ThemeTests {
  private static func hex(_ color: Color, _ style: UIUserInterfaceStyle) -> UInt32 {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
      .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return [red, green, blue].reduce(UInt32(0)) { $0 << 8 | UInt32(($1 * 255).rounded()) }
  }

  @Test(arguments: [
    ("brand", Palette.brand, UInt32(0x1769B8), UInt32(0x1B5FA3)),
    ("press", Palette.press, 0xD0FD5C, 0xD0FD5C),
    ("onPress", Palette.onPress, 0x191F28, 0x191F28),
    ("ink", Palette.ink, 0x1D2B45, 0xC9D6EE),
    ("background", Palette.background, 0xFFFFFF, 0x101418),
    ("content", Palette.content, 0x191F28, 0xF2F4F6),
    ("error", Palette.error, 0xC0261B, 0xFF8A80),
  ])
  func colorRoleFollowsTheAppearance(name: String, color: Color, light: UInt32, dark: UInt32) {
    #expect(Self.hex(color, .light) == light, "\(name) light")
    #expect(Self.hex(color, .dark) == dark, "\(name) dark")
  }

  @Test func statusLabelColorsComeFromTheirStatusTokens() {
    #expect(Self.hex(StatusRole.positive.foreground, .light) == 0x15803D)
    #expect(Self.hex(StatusRole.attention.background, .light) == 0xFDF1E1)
    #expect(Self.hex(StatusRole.error.background, .dark) == 0x3A1917)
    #expect(Self.hex(StatusRole.neutral.background, .light) == Self.hex(Palette.container, .light))
  }

  @Test(arguments: TextRole.allCases)
  func textRoleMatchesItsTokenAtTheDefaultSize(role: TextRole) throws {
    let metrics = role.metrics(for: .large)
    #expect(abs(metrics.pointSize - role.token.fontSize) < 0.01)
    #expect(abs(metrics.lineHeight - role.token.lineHeight) < 0.01)
    #expect(abs(metrics.tracking - role.token.letterSpacing * role.token.fontSize) < 0.001)
    if let name = role.fontName {
      let font = try #require(UIFont(name: name, size: role.token.fontSize), "\(name) is bundled and registered")
      #expect(font.familyName == "Pretendard")
    }
  }

  @Test(arguments: TextRole.allCases)
  func textRoleGrowsWithDynamicType(role: TextRole) {
    let base = role.metrics(for: .large)
    let large = role.metrics(for: .accessibility3)
    #expect(large.pointSize > base.pointSize)
    #expect(large.lineHeight > base.lineHeight)
  }

  @Test(arguments: TextRole.allCases)
  func textRoleScalesLikeTheClosestSystemStyle(role: TextRole) {
    let traits = UITraitCollection(preferredContentSizeCategory: .large)
    let styles: [UIFont.TextStyle] = [
      .largeTitle, .title1, .title2, .title3, .headline, .body, .callout, .subheadline, .footnote, .caption1, .caption2,
    ]
    func distance(_ style: UIFont.TextStyle) -> CGFloat {
      abs(UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize - role.token.fontSize)
    }
    #expect(distance(role.textStyle) == styles.map(distance).min())
  }

  @Test func textRoleUsesTheBundledWeights() {
    #expect(TextRole.body.fontName == "Pretendard-Regular")
    #expect(TextRole.rowTitle.fontName == "Pretendard-Bold")
    #expect(TextRole.amountHero.fontName == "Pretendard-ExtraBold")
    #expect(TextRole.routeCode.fontName == nil)
    #expect(TextRole.allCases.filter(\.isAmount) == [.amountHero, .amount])
  }

  @Test(arguments: [
    (ExpenseCategory.lodging, Palette.catSky, Palette.catSkyBg, "bed.double.fill"),
    (.transport, Palette.catLime, Palette.catLimeBg, "car.fill"),
    (.foodDrink, Palette.catApricot, Palette.catApricotBg, "fork.knife"),
    (.shopping, Palette.catViolet, Palette.catVioletBg, "bag.fill"),
    (.other, Palette.catOther, Palette.catOtherBg, "square.grid.2x2.fill"),
  ])
  func categoryHasItsColorsAndSymbol(category: ExpenseCategory, foreground: Color, background: Color, symbol: String) {
    for style in [UIUserInterfaceStyle.light, .dark] {
      #expect(Self.hex(category.foreground, style) == Self.hex(foreground, style))
      #expect(Self.hex(category.background, style) == Self.hex(background, style))
    }
    #expect(category.systemImage == symbol)
    #expect(UIImage(systemName: category.systemImage) != nil)
  }

  @Test func sendButtonSaysWhoSendsHowMuchToWhom() {
    #expect(SendButton.accessibilityText(sender: "가나", recipient: "다라", amountKRW: 136_030) == "가나가 다라에게 136,030원 보내기")
    #expect(SendButton.accessibilityText(sender: "민준", recipient: "다라", amountKRW: 5_000) == "민준이 다라에게 5,000원 보내기")
    #expect(Korean.subjectParticle(after: "Alex") == "이(가)")
  }

  @Test func flowLayoutWrapsToTheNextLine() {
    let layout = FlowLayout(spacing: 8, lineSpacing: 8)
    let sizes = [CGSize(width: 60, height: 44), CGSize(width: 60, height: 44), CGSize(width: 60, height: 30)]
    let result = layout.arrange(sizes, width: 140)
    #expect(result.origins == [CGPoint(x: 0, y: 0), CGPoint(x: 68, y: 0), CGPoint(x: 0, y: 52)])
    #expect(result.size == CGSize(width: 128, height: 82))
  }
}
