import SwiftUI

/// 송금 한 건의 "보내기" 단추. 내가 보낼 송금 행에만 붙인다. 화면 읽기 이름에 누가 누구에게 얼마인지 모두 담는다.
struct SendButton: View {
  let sender: String
  let recipient: String
  let amountKRW: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text("보내기")
        .textRole(.chip)
        .foregroundStyle(Palette.onPress)
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: Size.touchMin)
        .background(Palette.press, in: .capsule)
        .overlay { Capsule().strokeBorder(Palette.pressEdge, lineWidth: 1) }
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Self.accessibilityText(sender: sender, recipient: recipient, amountKRW: amountKRW))
  }

  /// "가나가 다라에게 136,030원 보내기".
  nonisolated static func accessibilityText(sender: String, recipient: String, amountKRW: Int) -> String {
    "\(sender)\(Korean.subjectParticle(after: sender)) \(recipient)에게 \(Won.text(amountKRW)) 보내기"
  }
}

enum Korean {
  /// 이름 뒤 주격 조사. 받침이 있으면 "이", 없으면 "가", 한글로 끝나지 않으면 "이(가)".
  /// 분해형(NFD)으로 들어온 이름도 같게 판정하도록 완성형(NFC)으로 바꿔 마지막 글자를 본다.
  static func subjectParticle(after word: String) -> String {
    guard let last = word.precomposedStringWithCanonicalMapping.unicodeScalars.last,
      (0xAC00...0xD7A3).contains(last.value)
    else { return "이(가)" }
    return (last.value - 0xAC00) % 28 == 0 ? "가" : "이"
  }
}

#if DEBUG
  struct SendButtonSamples: View {
    var body: some View {
      HStack(spacing: Spacing.m) {
        VStack(alignment: .leading, spacing: 0) {
          Text("다라에게").textRole(.rowTitle).foregroundStyle(Palette.content)
          Text("136,030원").textRole(.amount).foregroundStyle(Palette.content)
        }
        Spacer(minLength: Spacing.s)
        SendButton(sender: "가나", recipient: "다라", amountKRW: 136_030) {}
      }
      .padding(Spacing.m)
    }
  }

  #Preview("라이트") { SendButtonSamples() }
  #Preview("다크") { SendButtonSamples().background(Palette.background).preferredColorScheme(.dark) }
  #Preview("큰 글자") { SendButtonSamples().dynamicTypeSize(.accessibility3) }
#endif
