import SwiftUI

/// 라벨이 위에 붙는 입력 칸. 라벨은 언제나 보이고(자리표시 글자로 대신하지 않는다), 상자는 높이 52.
/// 초점이면 `ink` 테두리, 오류면 `error` 테두리와 칸 아래 오류 문장. 오류는 문장으로 알리므로 색만으로 구분하지 않는다.
/// 날짜·통화 고르기는 플랫폼 선택기를 쓰고, 칸 모양만 이 부품으로 맞춘다.
struct InputField: View {
  enum Kind {
    case text
    /// 오른쪽 정렬, 숫자 표 정렬, 숫자 키보드.
    case amount
  }

  let label: String
  @Binding var text: String
  var kind = Kind.text
  /// 무엇이 틀렸는지와 예시: "예: 2026-11-03 또는 20261103".
  var error: String?

  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label).textRole(.supporting).foregroundStyle(Palette.contentSecondary).accessibilityHidden(true)
      TextField(label, text: $text, axis: .horizontal)
        .font(kind == .amount ? TextRole.rowTitle.font.monospacedDigit() : TextRole.rowTitle.font)
        .foregroundStyle(Palette.content)
        .multilineTextAlignment(kind == .amount ? .trailing : .leading)
        .keyboardType(kind == .amount ? .decimalPad : .default)
        .focused($focused)
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: Size.inputHeight)
        .background(Palette.container, in: .rect(cornerRadius: Radius.radiusM))
        .overlay { RoundedRectangle(cornerRadius: Radius.radiusM).strokeBorder(border, lineWidth: 1) }
        .contentShape(.rect)
        .onTapGesture { focused = true }
      if let error {
        Text(error).textRole(.supporting).foregroundStyle(Palette.error)
      }
    }
  }

  private var border: Color {
    if error != nil { return Palette.error }
    return focused ? Palette.ink : .clear
  }
}

#if DEBUG
  struct InputFieldSamples: View {
    @State private var merchant = "이치란 라멘"
    @State private var date = "2026-11-3"
    @State private var amount = "1840"

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        InputField(label: "가게", text: $merchant)
        InputField(label: "날짜", text: $date, error: "날짜를 알아볼 수 없어요. 예: 2026-11-03 또는 20261103")
        InputField(label: "금액", text: $amount, kind: .amount)
      }
      .padding(Spacing.m)
    }
  }

  #Preview("라이트") { InputFieldSamples() }
  #Preview("다크") { InputFieldSamples().background(Palette.background).preferredColorScheme(.dark) }
  #Preview("큰 글자") { InputFieldSamples().dynamicTypeSize(.accessibility3) }
#endif
