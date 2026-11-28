import SwiftUI

/// 입력 칸의 틀: 위 라벨, 높이 52 상자, 테두리, 아래 오류 문장. 라벨은 언제나 보인다(자리표시 글자로 대신하지 않는다).
/// 안에는 글자 입력(`InputField`), 시스템 날짜 선택기(`DateInputField`), 메뉴(`CurrencyInputField`)처럼 무엇이든 넣고
/// 칸 모양만 이 틀로 맞춘다. 오류는 문장으로 알리므로 색만으로 구분하지 않는다.
struct InputFrame<Content: View>: View {
  let label: String
  var error: String?
  /// 입력 중(글자 칸 초점, 선택기가 열림)이면 `ink` 테두리.
  var isActive = false
  /// 좁은 통화 칸은 12.
  var horizontalPadding = Spacing.m
  @ViewBuilder var content: Content

  var body: some View {
    let border = InputBorder(isActive: isActive, hasError: error != nil)
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label).textRole(.supporting).foregroundStyle(Palette.contentSecondary).accessibilityHidden(true)
      content
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: Size.inputHeight)
        .background(Palette.container, in: .rect(cornerRadius: Radius.radiusM))
        .overlay {
          RoundedRectangle(cornerRadius: Radius.radiusM).strokeBorder(border.color, lineWidth: InputBorder.width)
        }
      if let error {
        Text(error).textRole(.supporting).foregroundStyle(Palette.error)
      }
    }
  }
}

/// 입력 칸 테두리. 오류가 초점보다 앞선다. 키보드 탐색의 초점 고리는 시스템(전체 키보드 접근)이 그린다.
enum InputBorder: Equatable {
  case none
  case active
  case error

  static let width: CGFloat = 1

  init(isActive: Bool, hasError: Bool) {
    self = hasError ? .error : isActive ? .active : .none
  }

  var color: Color {
    switch self {
    case .none: .clear
    case .active: Palette.ink
    case .error: Palette.error
    }
  }
}

/// 글자·금액 입력 칸.
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
    InputFrame(label: label, error: error, isActive: focused) {
      TextField(label, text: $text)
        .font(kind == .amount ? TextRole.rowTitle.font.monospacedDigit() : TextRole.rowTitle.font)
        .foregroundStyle(Palette.content)
        .multilineTextAlignment(kind == .amount ? .trailing : .leading)
        .keyboardType(kind == .amount ? .decimalPad : .default)
        .focused($focused)
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
        .onTapGesture { focused = true }
    }
  }
}

/// 날짜 칸. 누르면 시스템 날짜 선택기(달력)를 띄우고, 날짜를 고르면 닫는다.
struct DateInputField: View {
  let label: String
  @Binding var date: Date
  var error: String?

  @State private var picking = false

  var body: some View {
    InputFrame(label: label, error: error, isActive: picking) {
      Button {
        picking = true
      } label: {
        HStack(spacing: Spacing.s) {
          Text(Self.text(for: date)).textRole(.rowTitle).monospacedDigit().foregroundStyle(Palette.content)
          Spacer(minLength: 0)
          Image(systemName: "calendar").foregroundStyle(Palette.contentSecondary).accessibilityHidden(true)
        }
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(label)
      .accessibilityValue(Self.text(for: date))
      .popover(isPresented: $picking) {
        DatePicker(label, selection: $date, displayedComponents: .date)
          .datePickerStyle(.graphical)
          .labelsHidden()
          .tint(Palette.ink)
          .padding(Spacing.m)
          .frame(minWidth: 320)
          .presentationCompactAdaptation(.popover)
          .onChange(of: date) { picking = false }
      }
    }
  }

  /// 영수증 날짜와 같은 모양(`2026-11-03`). 기기 시간대의 그레고리력 날짜다.
  nonisolated static func text(for date: Date, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }
}

/// 통화 칸. 누르면 시스템 메뉴에서 고른다.
struct CurrencyInputField: View {
  let label: String
  @Binding var code: String
  let codes: [String]
  var error: String?

  var body: some View {
    InputFrame(label: label, error: error, horizontalPadding: 12) {
      Menu {
        Picker(label, selection: $code) {
          ForEach(codes, id: \.self) { Text($0).tag($0) }
        }
      } label: {
        HStack(spacing: Spacing.xs) {
          Text(code).textRole(.rowTitle).foregroundStyle(Palette.content)
          Spacer(minLength: 0)
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.contentSecondary)
            .accessibilityHidden(true)
        }
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
      }
      .accessibilityLabel(label)
      .accessibilityValue(code)
    }
  }
}

#if DEBUG
  struct InputFieldSamples: View {
    @State private var merchant = "이치란 라멘"
    @State private var amount = "1840"
    @State private var date = DateComponents(calendar: .init(identifier: .gregorian), year: 2026, month: 11, day: 3)
      .date!
    @State private var currency = "JPY"

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        InputField(label: "가게", text: $merchant)
        InputField(label: "날짜(글자 입력)", text: .constant("2026-11-3"), error: "날짜를 알아볼 수 없어요. 예: 2026-11-03 또는 20261103")
        DateInputField(label: "날짜", date: $date)
        HStack(alignment: .top, spacing: Spacing.s) {
          InputField(label: "금액", text: $amount, kind: .amount)
          CurrencyInputField(label: "통화", code: $currency, codes: ["JPY", "KRW", "USD"]).frame(width: 104)
        }
      }
      .padding(Spacing.m)
    }
  }

  #Preview("라이트") { InputFieldSamples() }
  #Preview("다크") { InputFieldSamples().background(Palette.background).preferredColorScheme(.dark) }
  #Preview("큰 글자") { InputFieldSamples().dynamicTypeSize(.accessibility3) }
#endif
