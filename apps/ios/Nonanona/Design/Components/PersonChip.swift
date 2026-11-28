import SwiftUI

/// 낼 사람을 고르는 알약 칩. 고르면 네이비 바탕에 체크를 붙여, 색만으로 고름을 알리지 않는다.
/// 여러 칩은 `FlowLayout`으로 잇고, 묶음에 "○○을 낼 사람" 이름을 붙인다.
struct PersonChip: View {
  let name: String
  let isSelected: Bool
  let action: () -> Void

  init(_ name: String, isSelected: Bool, action: @escaping () -> Void) {
    self.name = name
    self.isSelected = isSelected
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.xs) {
        if isSelected {
          Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).accessibilityHidden(true)
        }
        Text(name).textRole(.chip)
      }
      .foregroundStyle(isSelected ? Palette.onInk : Palette.content)
      .padding(.horizontal, Spacing.m)
      .frame(minHeight: Size.touchMin)
      .background(isSelected ? Palette.ink : Palette.container, in: .capsule)
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

#if DEBUG
  struct PersonChipSamples: View {
    @State private var selected: Set<String> = ["다라"]

    var body: some View {
      VStack(alignment: .leading, spacing: Spacing.s) {
        Text("명란 우동을 낼 사람").textRole(.supporting).foregroundStyle(Palette.contentSecondary)
        FlowLayout {
          ForEach(["가나", "다라", "마바", "사아"], id: \.self) { name in
            PersonChip(name, isSelected: selected.contains(name)) {
              if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
            }
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("명란 우동을 낼 사람")
      }
      .padding(Spacing.m)
    }
  }

  #Preview("라이트") { PersonChipSamples() }
  #Preview("다크") { PersonChipSamples().background(Palette.background).preferredColorScheme(.dark) }
  #Preview("큰 글자") { PersonChipSamples().dynamicTypeSize(.accessibility3) }
#endif
