#if DEBUG
  import SwiftUI

  /// 디자인 부품을 시뮬레이터에서 한 화면에 모아 본다. `NONANONA_DESIGN_GALLERY=1`로 띄운 debug 빌드에만 있다.
  /// 각 부품 파일의 미리보기와 같은 표본을 쓴다.
  struct DesignGallery: View {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["NONANONA_DESIGN_GALLERY"] != nil }
    /// 스크린샷용으로 한 화면에 다 들어가지 않는 부품을 나눈다(`NONANONA_DESIGN_GALLERY=1`~`4`, 4는 큰 글자 확인용 목록 행).
    private let page = ProcessInfo.processInfo.environment["NONANONA_DESIGN_GALLERY"] ?? "1"

    var body: some View {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.s) {
            switch page {
            case "4":
              section("ExpenseRow") { ExpenseRowSamples() }
              section("InfoRow") { InfoRowSamples() }
            case "3":
              section("Button") { ActionButtonSamples() }
              section("SectionBand") { SectionBandSamples() }
            case "2":
              section("PersonChip") { PersonChipSamples() }
              section("SendButton") { SendButtonSamples() }
              section("InputField") { InputFieldSamples() }
            default:
              section("SummaryCard") { SummaryCardSamples() }
              section("MemberLine") { MemberLineSamples() }
              section("ExpenseRow") { ExpenseRowSamples() }
              section("InfoRow") { InfoRowSamples() }
              section("CategoryIcon") { CategoryIconSamples() }
              section("StatusLabel") { StatusLabelSamples() }
            }
          }
        }
        .background(Palette.background)
        .navigationTitle("디자인 부품")
        .bottomBar(note: "확인하면 가린 사본을 만들어요. 원본은 이 기기에만 남아요.") {
          Button("확인하고 다음") {}
        }
      }
    }

    private func section(_ name: String, @ViewBuilder content: () -> some View) -> some View {
      VStack(alignment: .leading, spacing: 0) {
        Text(name).textRole(.routeCode).foregroundStyle(Palette.contentSecondary).padding(.horizontal, Spacing.m)
        content()
      }
    }
  }
#endif
