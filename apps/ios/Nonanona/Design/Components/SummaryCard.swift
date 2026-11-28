import SwiftUI

/// 화면 맨 위의 진한 하늘 요약 카드. 화면당 한 장, 핵심 금액 하나를 흰 글자로 크게 보여 준다.
/// 금액이 확정 전 예상값을 포함하면 `label`이나 `detail`에 "예상 포함"을 글자로 쓴다.
struct SummaryCard<Artwork: View>: View {
  let label: String
  /// 서버가 계산한 값을 그대로 쓴 문자열: "136,030원".
  let amount: String
  var detail: String?
  var emphasizesDetail = false
  /// 카드 안 상태 칩: "미리보기 · 아직 확정 전".
  var status: String?
  /// 오른쪽 위 그림 자리(폭 약 96, 비행기 친구). 꾸밈이라 화면 읽기에서 숨기고, 아주 큰 글자에서는 빼서 금액 자리를 넓힌다.
  @ViewBuilder var artwork: Artwork

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label).textRole(.supporting).foregroundStyle(Palette.onBrandSoft)
      HStack(alignment: .top, spacing: Spacing.s) {
        Text(amount).textRole(.amountHero).foregroundStyle(Palette.onBrand)
        Spacer(minLength: 0)
        if !dynamicTypeSize.isAccessibilitySize {
          artwork.frame(maxWidth: 96).accessibilityHidden(true)
        }
      }
      if let detail {
        Text(detail)
          .textRole(emphasizesDetail ? .bodyStrong : .body)
          .foregroundStyle(emphasizesDetail ? Palette.onBrand : Palette.onBrandSoft)
      }
      if let status {
        Text(status)
          .textRole(.status)
          .foregroundStyle(Palette.brand)
          .padding(.horizontal, Spacing.s)
          .padding(.vertical, Spacing.xs)
          .background(Palette.onBrandSoft, in: .rect(cornerRadius: Radius.radiusS))
          .padding(.top, Spacing.xs)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.m)
    .background(Palette.brand, in: .rect(cornerRadius: Radius.radiusXl))
    .accessibilityElement(children: .combine)
  }
}

extension SummaryCard where Artwork == EmptyView {
  init(label: String, amount: String, detail: String? = nil, emphasizesDetail: Bool = false, status: String? = nil) {
    self.init(label: label, amount: amount, detail: detail, emphasizesDetail: emphasizesDetail, status: status) {
      EmptyView()
    }
  }
}

#if DEBUG
  struct SummaryCardSamples: View {
    var body: some View {
      VStack(spacing: Spacing.m) {
        SummaryCard(
          label: "포함한 지출 · 예상 포함", amount: "412,000원", detail: "4명 · 지출 12건", status: "미리보기 · 아직 확정 전"
        ) {
          Image(systemName: "airplane").resizable().scaledToFit().foregroundStyle(Palette.planeWing).frame(height: 40)
        }
        SummaryCard(label: "내가 보낼 돈", amount: "136,030원", detail: "다라에게 보내면 끝나요.", emphasizesDetail: true)
      }
      .padding(Spacing.m)
    }
  }

  #Preview("라이트") { SummaryCardSamples() }
  #Preview("다크") { SummaryCardSamples().background(Palette.background).preferredColorScheme(.dark) }
  #Preview("큰 글자") { SummaryCardSamples().dynamicTypeSize(.accessibility3) }
#endif
