import SwiftUI

/// 이름과 읽기 전용 값 한 줄. 고칠 수 있는 값은 `InputField`로 둔다.
/// `action`이 있으면 값 뒤에 펼침 화살표를 붙이고 행 전체를 누르는 영역으로 둔다. 행 사이 선은 마지막 행에서 끈다.
struct InfoRow: View {
  let name: String
  let value: String
  var isAmount = false
  var showsDivider = true
  var action: (() -> Void)?

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    VStack(spacing: 0) {
      if let action {
        Button(action: action) { content.contentShape(.rect) }.buttonStyle(.plain)
      } else {
        content
      }
      if showsDivider { Palette.line.frame(height: 1) }
    }
  }

  private var content: some View {
    let large = dynamicTypeSize.isAccessibilitySize
    let layout =
      large
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs)) : AnyLayout(HStackLayout(spacing: Spacing.s))
    return layout {
      Text(name).textRole(.body).foregroundStyle(Palette.contentSecondary)
      if !large { Spacer(minLength: Spacing.s) }
      HStack(spacing: Spacing.xs) {
        (isAmount ? Text(value).monospacedDigit() : Text(value))
          .textRole(.bodyStrong)
          .foregroundStyle(Palette.content)
          .multilineTextAlignment(large ? .leading : .trailing)
        if action != nil {
          Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Palette.contentSecondary)
            .accessibilityHidden(true)
        }
      }
    }
    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

#if DEBUG
  struct InfoRowSamples: View {
    var body: some View {
      VStack(spacing: 0) {
        InfoRow(name: "일행", value: "가나 · 다라 · 마바 (3명)")
        InfoRow(name: "함께 쓴 돈", value: "412,000원", isAmount: true)
        InfoRow(name: "이 중 예상 금액(기준환율)", value: "11,551원", isAmount: true)
        InfoRow(name: "제외된 지출", value: "1건", showsDivider: false, action: {})
      }
      .padding(.horizontal, Spacing.m)
    }
  }

  #Preview("라이트") { InfoRowSamples() }
  #Preview("다크") { InfoRowSamples().background(Palette.background).preferredColorScheme(.dark) }
  #Preview("큰 글자") { InfoRowSamples().dynamicTypeSize(.accessibility3) }
#endif
