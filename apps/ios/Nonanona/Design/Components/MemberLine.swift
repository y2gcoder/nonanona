import SwiftUI

/// 장부의 일행 줄: "일행" 뒤에 이름을 가로로 잇고 넘치면 다음 줄로. 역할은 이름 바로 뒤 글자 라벨("방장", "나")이다.
/// 아직 참여하지 않은 사람은 넣지 않는다. 사진·아바타는 쓰지 않는다.
struct MemberLine: View {
  struct Member: Identifiable {
    /// 여행방 구성원 ID. 이름이 같은 일행도 따로 그린다.
    let id: String
    let name: String
    var isHost = false
    var isMe = false
  }

  let members: [Member]

  var body: some View {
    FlowLayout(spacing: Spacing.m, lineSpacing: Spacing.s) {
      Text("일행").bold().textRole(.supporting).foregroundStyle(Palette.contentSecondary)
      ForEach(members) { member in
        HStack(spacing: Spacing.xs) {
          Text(member.name).textRole(.rowTitle).foregroundStyle(Palette.content)
          if member.isHost { StatusLabel("방장", role: .neutral) }
          if member.isMe { StatusLabel("나", role: .neutral) }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

#if DEBUG
  struct MemberLineSamples: View {
    var body: some View {
      MemberLine(members: [
        .init(id: "m1", name: "가나", isHost: true), .init(id: "m2", name: "다라", isMe: true),
        .init(id: "m3", name: "마바"), .init(id: "m4", name: "사아"),
      ])
      .padding(Spacing.m)
    }
  }

  #Preview("라이트") { MemberLineSamples() }
  #Preview("다크") { MemberLineSamples().background(Palette.background).preferredColorScheme(.dark) }
  #Preview("큰 글자") { MemberLineSamples().dynamicTypeSize(.accessibility3) }
#endif
