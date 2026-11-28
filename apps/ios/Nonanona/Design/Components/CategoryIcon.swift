import SwiftUI

/// 지출 범주. 범주마다 색과 기호가 고정이다(하늘 숙소, 라임 교통, 살구 식음, 보라 쇼핑, 회색 그 밖).
enum ExpenseCategory: CaseIterable {
  case lodging
  case transport
  case foodDrink
  case shopping
  /// 송금, 초대, 기타. 송금·초대 행은 `CategoryIcon(systemImage:)`로 기호만 바꾼다.
  case other

  var foreground: Color {
    switch self {
    case .lodging: Palette.catSky
    case .transport: Palette.catLime
    case .foodDrink: Palette.catApricot
    case .shopping: Palette.catViolet
    case .other: Palette.catOther
    }
  }

  var background: Color {
    switch self {
    case .lodging: Palette.catSkyBg
    case .transport: Palette.catLimeBg
    case .foodDrink: Palette.catApricotBg
    case .shopping: Palette.catVioletBg
    case .other: Palette.catOtherBg
    }
  }

  /// 채운 SF Symbol. Android는 같은 뜻의 Material Symbols(둥근, 채움)를 쓴다.
  var systemImage: String {
    switch self {
    case .lodging: "bed.double.fill"
    case .transport: "car.fill"
    case .foodDrink: "fork.knife"
    case .shopping: "bag.fill"
    case .other: "square.grid.2x2.fill"
    }
  }
}

/// 목록 행 왼쪽의 범주 원(지름 40, 안 그림 20). 범주는 행 글자로 읽히므로 원은 꾸밈으로 숨긴다.
struct CategoryIcon: View {
  let category: ExpenseCategory
  var systemImage: String?

  init(_ category: ExpenseCategory, systemImage: String? = nil) {
    self.category = category
    self.systemImage = systemImage
  }

  var body: some View {
    Image(systemName: systemImage ?? category.systemImage)
      .resizable()
      .scaledToFit()
      .frame(width: 20, height: 20)
      .foregroundStyle(category.foreground)
      .frame(width: Size.categoryIcon, height: Size.categoryIcon)
      .background(category.background, in: .circle)
      .accessibilityHidden(true)
  }
}

#if DEBUG
  struct CategoryIconSamples: View {
    var body: some View {
      HStack(spacing: Spacing.s) {
        ForEach(ExpenseCategory.allCases, id: \.self) { CategoryIcon($0) }
        CategoryIcon(.other, systemImage: "paperplane.fill")
        CategoryIcon(.other, systemImage: "envelope.fill")
      }
      .padding(Spacing.m)
    }
  }

  #Preview("라이트") { CategoryIconSamples() }
  #Preview("다크") { CategoryIconSamples().background(Palette.background).preferredColorScheme(.dark) }
  #Preview("큰 글자") { CategoryIconSamples().dynamicTypeSize(.accessibility3) }
#endif
