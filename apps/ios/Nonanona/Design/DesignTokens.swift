// 생성 파일. 직접 수정하지 마세요.
// 원본: design/tokens.json
// 생성: mise run design:tokens
import SwiftUI
import UIKit

enum DesignTokens {
  enum Colors {
    static let attention = adaptive(light: rgb(0xB45309), dark: rgb(0xFBBF24))
    static let attentionSoft = adaptive(light: rgb(0xFDF1E1), dark: rgb(0x3A2A10))
    static let background = adaptive(light: rgb(0xFFFFFF), dark: rgb(0x101418))
    static let band = adaptive(light: rgb(0xF2F6FA), dark: rgb(0x0A0D10))
    static let brand = adaptive(light: rgb(0x1769B8), dark: rgb(0x1B5FA3))
    static let catApricot = adaptive(light: rgb(0xC25A0E), dark: rgb(0xFFB27A))
    static let catApricotBg = adaptive(light: rgb(0xFFEEDD), dark: rgb(0x3A2412))
    static let catLime = adaptive(light: rgb(0x4F7A00), dark: rgb(0xB5E35A))
    static let catLimeBg = adaptive(light: rgb(0xEEF8D6), dark: rgb(0x24330C))
    static let catOther = adaptive(light: rgb(0x5F6B7A), dark: rgb(0xB4BEC9))
    static let catOtherBg = adaptive(light: rgb(0xEEF1F4), dark: rgb(0x262D36))
    static let catSky = adaptive(light: rgb(0x1769B8), dark: rgb(0x5CB6FF))
    static let catSkyBg = adaptive(light: rgb(0xE3F2FD), dark: rgb(0x12304A))
    static let catViolet = adaptive(light: rgb(0x6D46C9), dark: rgb(0xB9A3FF))
    static let catVioletBg = adaptive(light: rgb(0xEFE9FD), dark: rgb(0x2A2245))
    static let cheek = adaptive(light: rgb(0xFFB7C5), dark: rgb(0xD98A9B))
    static let container = adaptive(light: rgb(0xF2F6FA), dark: rgb(0x1A2027))
    static let content = adaptive(light: rgb(0x191F28), dark: rgb(0xF2F4F6))
    static let contentSecondary = adaptive(light: rgb(0x5F6B7A), dark: rgb(0x9AA5B2))
    static let error = adaptive(light: rgb(0xC0261B), dark: rgb(0xFF8A80))
    static let errorSoft = adaptive(light: rgb(0xFDECEA), dark: rgb(0x3A1917))
    static let focus = adaptive(light: rgb(0x1D2B45), dark: rgb(0xC9D6EE))
    static let ink = adaptive(light: rgb(0x1D2B45), dark: rgb(0xC9D6EE))
    static let line = adaptive(light: rgb(0xE5E8EB), dark: rgb(0x2A3038))
    static let mask = adaptive(light: rgb(0x000000), dark: rgb(0x000000))
    static let neutral = adaptive(light: rgb(0x5F6B7A), dark: rgb(0x9AA5B2))
    static let onBrand = adaptive(light: rgb(0xFFFFFF), dark: rgb(0xFFFFFF))
    static let onBrandSoft = adaptive(light: rgb(0xDCEFFF), dark: rgb(0xD6E9FF))
    static let onInk = adaptive(light: rgb(0xFFFFFF), dark: rgb(0x101418))
    static let onMask = adaptive(light: rgb(0xFFFFFF), dark: rgb(0xFFFFFF))
    static let onPress = adaptive(light: rgb(0x191F28), dark: rgb(0x191F28))
    static let planeWing = adaptive(light: rgb(0xD6ECFD), dark: rgb(0xD6ECFD))
    static let positive = adaptive(light: rgb(0x15803D), dark: rgb(0x4ADE80))
    static let positiveSoft = adaptive(light: rgb(0xE7F6EC), dark: rgb(0x143022))
    static let press = adaptive(light: rgb(0xD0FD5C), dark: rgb(0xD0FD5C))
    static let pressEdge = adaptive(light: rgb(0x191F28, alpha: 0.14), dark: rgb(0x000000, alpha: 0.3))
    static let scrim = adaptive(light: rgb(0x191F28, alpha: 0.42), dark: rgb(0x000000, alpha: 0.6))
    static let sky = adaptive(light: rgb(0x4FB0F5), dark: rgb(0x4FB0F5))

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
      Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
      UIColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
      )
    }
  }

  struct TypeStyleToken {
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let fontWeight: Int
    let letterSpacing: CGFloat
  }

  enum Typography {
    static let amount = TypeStyleToken(fontSize: 17, lineHeight: 24, fontWeight: 800, letterSpacing: 0)
    static let amountHero = TypeStyleToken(fontSize: 34, lineHeight: 40, fontWeight: 800, letterSpacing: -0.02)
    static let body = TypeStyleToken(fontSize: 15, lineHeight: 22, fontWeight: 400, letterSpacing: 0)
    static let bodyStrong = TypeStyleToken(fontSize: 15, lineHeight: 22, fontWeight: 700, letterSpacing: 0)
    static let button = TypeStyleToken(fontSize: 16, lineHeight: 24, fontWeight: 800, letterSpacing: 0)
    static let chip = TypeStyleToken(fontSize: 14, lineHeight: 20, fontWeight: 700, letterSpacing: 0)
    static let heading = TypeStyleToken(fontSize: 26, lineHeight: 36, fontWeight: 800, letterSpacing: -0.02)
    static let routeCode = TypeStyleToken(fontSize: 11, lineHeight: 14, fontWeight: 500, letterSpacing: 0.08)
    static let rowTitle = TypeStyleToken(fontSize: 16, lineHeight: 24, fontWeight: 700, letterSpacing: 0)
    static let screenTitle = TypeStyleToken(fontSize: 26, lineHeight: 34, fontWeight: 800, letterSpacing: -0.02)
    static let sectionTitle = TypeStyleToken(fontSize: 18, lineHeight: 26, fontWeight: 800, letterSpacing: 0)
    static let status = TypeStyleToken(fontSize: 12, lineHeight: 16, fontWeight: 700, letterSpacing: 0)
    static let supporting = TypeStyleToken(fontSize: 13, lineHeight: 18, fontWeight: 400, letterSpacing: 0)
  }

  enum Spacing {
    static let spaceL: CGFloat = 24
    static let spaceM: CGFloat = 16
    static let spaceS: CGFloat = 8
    static let spaceXl: CGFloat = 32
    static let spaceXs: CGFloat = 4
  }

  enum Radius {
    static let radiusL: CGFloat = 16
    static let radiusM: CGFloat = 12
    static let radiusPill: CGFloat = 999
    static let radiusS: CGFloat = 8
    static let radiusXl: CGFloat = 20
  }

  enum Size {
    static let bandHeight: CGFloat = 8
    static let buttonHeight: CGFloat = 56
    static let categoryIcon: CGFloat = 40
    static let inputHeight: CGFloat = 52
    static let rowMin: CGFloat = 56
    static let touchMin: CGFloat = 44
  }
}
