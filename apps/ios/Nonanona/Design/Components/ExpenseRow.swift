import SwiftUI

/// 장부의 지출 한 줄: 범주 원, 무엇과 누가, 오른쪽 끝에 금액과 상태. 흰 바탕에 테두리·구분선 없이 쌓는다.
/// `action`이 있으면 행 전체가 누르는 영역이다(방장의 검토 열기).
struct ExpenseRow: View {
  let category: ExpenseCategory
  let title: String
  /// "다라가 냄 · 4명", "마바가 올림", "다라가 냄 · 예상 ₩11,551".
  let detail: String
  /// 기호를 앞에 둔 금액: "₩52,300", "¥1,840".
  let amount: String
  var status: StatusLabel?
  var action: (() -> Void)?

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    if let action {
      Button(action: action) { row.contentShape(.rect) }.buttonStyle(.plain)
    } else {
      row
    }
  }

  private var row: some View {
    let large = dynamicTypeSize.isAccessibilitySize
    return HStack(alignment: large ? .top : .center, spacing: Spacing.m) {
      CategoryIcon(category)
      let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs)) : AnyLayout(HStackLayout())
      layout {
        VStack(alignment: .leading, spacing: 0) {
          Text(title).textRole(.rowTitle).foregroundStyle(Palette.content).lineLimit(large ? nil : 1)
          Text(detail).textRole(.supporting).foregroundStyle(Palette.contentSecondary)
        }
        if !large { Spacer(minLength: Spacing.s) }
        VStack(alignment: large ? .leading : .trailing, spacing: Spacing.xs) {
          Text(amount).textRole(.amount).foregroundStyle(Palette.content)
          status
        }
      }
    }
    .frame(maxWidth: .infinity, minHeight: Size.rowMin, alignment: .leading)
    .padding(.vertical, Spacing.s)
    .accessibilityElement(children: .combine)
  }
}

#if DEBUG
  struct ExpenseRowSamples: View {
    var body: some View {
      VStack(spacing: 0) {
        ExpenseRow(
          category: .lodging, title: "숙소 3박", detail: "다라가 냄 · 4명", amount: "₩412,000",
          status: StatusLabel("포함", role: .positive), action: {})
        ExpenseRow(
          category: .foodDrink, title: "이치란 라멘 텐진 니시도리점", detail: "마바가 올림", amount: "¥1,840",
          status: StatusLabel("확인 필요", role: .attention))
        ExpenseRow(
          category: .transport, title: "공항 열차", detail: "다라가 냄 · 예상 ₩11,551", amount: "¥1,280",
          status: StatusLabel("보류", role: .neutral))
      }
      .padding(.horizontal, Spacing.m)
    }
  }

  #Preview("라이트") { ExpenseRowSamples() }
  #Preview("다크") { ExpenseRowSamples().background(Palette.background).preferredColorScheme(.dark) }
  #Preview("큰 글자") { ExpenseRowSamples().dynamicTypeSize(.accessibility3) }
#endif
