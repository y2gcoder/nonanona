import SwiftUI

/// 섹션 사이의 두꺼운 띠. 화면 좌우 끝까지 놓고(화면 여백 바깥), 카드 테두리나 구분선 대신 쓴다. 꾸밈이라 화면 읽기에서 숨긴다.
struct SectionBand: View {
  var body: some View {
    Palette.band
      .frame(maxWidth: .infinity)
      .frame(height: Size.bandHeight)
      .accessibilityHidden(true)
  }
}

#if DEBUG
  struct SectionBandSamples: View {
    var body: some View {
      VStack(alignment: .leading, spacing: Spacing.s) {
        Text("일행").textRole(.sectionTitle).padding(.horizontal, Spacing.m)
        SectionBand()
        Text("지출").textRole(.sectionTitle).padding(.horizontal, Spacing.m)
      }
      .padding(.vertical, Spacing.m)
    }
  }

  #Preview("라이트") { SectionBandSamples() }
  #Preview("다크") { SectionBandSamples().background(Palette.background).preferredColorScheme(.dark) }
  #Preview("큰 글자") { SectionBandSamples().dynamicTypeSize(.accessibility3) }
#endif
