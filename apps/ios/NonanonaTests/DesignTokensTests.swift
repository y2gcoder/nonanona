import SwiftUI
import Testing

@testable import Nonanona

struct DesignTokensTests {
  @Test(arguments: [(ColorScheme.light, Float(0.14)), (.dark, 0.3)])
  func pressEdgeResolvesForTheAppearance(scheme: ColorScheme, opacity: Float) {
    var environment = EnvironmentValues()
    environment.colorScheme = scheme
    let resolved = DesignTokens.Colors.pressEdge.resolve(in: environment)
    #expect(abs(resolved.opacity - opacity) < 0.0001)
  }
}
