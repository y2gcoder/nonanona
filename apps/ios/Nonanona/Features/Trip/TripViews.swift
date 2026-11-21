import SwiftUI

struct PendingInviteCard: View {
  let onOpen: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.s) {
      StatusLabel("초대 대기 중", role: .attention)
      Text("초대받은 여행방이 있어요").textRole(.sectionTitle)
      Text("로그인하면 바로 참여할 수 있어요.").textRole(.supporting)
      Button("초대 보기", action: onOpen)
        .buttonStyle(.bordered)
        .accessibilityIdentifier("pending-invite-open")
    }
    .padding(.vertical, Spacing.xs)
  }
}

struct InviteView: View {
  let signedIn: Bool
  let join: JoinState
  let onLogin: () -> Void
  let onJoin: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.m) {
        StatusLabel("초대 대기 중", role: .attention)
        Text("여행방에 초대받았어요").font(.title2.bold())
        Text(signedIn ? "참여하면 일행과 지출을 함께 정리할 수 있어요." : "참여하려면 로그인해 주세요. 공유한 영수증 초안은 그대로 남아요.")
          .textRole(.body)
        switch join {
        case .joining:
          HStack(spacing: Spacing.s) {
            ProgressView()
            Text("참여하는 중…").textRole(.supporting)
          }
        case .failed:
          Text("참여하지 못했어요. 다시 시도해 주세요.")
            .textRole(.supporting)
            .foregroundStyle(.red)
            .accessibilityIdentifier("invite-failed")
        case .idle:
          EmptyView()
        }
        Button(signedIn ? "참여하기" : "로그인하고 참여하기", action: signedIn ? onJoin : onLogin)
          .buttonStyle(.primaryAction)
          .disabled(join == .joining)
          .accessibilityIdentifier("invite-primary")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.m)
    }
    .navigationTitle("여행방 초대")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("invite-screen")
  }
}

struct TripRoomView: View {
  let room: TripRoom
  let localDraftCount: Int

  var body: some View {
    List {
      Section {
        StatusLabel("참여함", role: .positive)
          .accessibilityIdentifier("room-status")
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 0, leading: Spacing.m, bottom: 0, trailing: Spacing.m))

      Section {
        ForEach(room.members, id: \.self) { member in
          HStack {
            Text(member.displayName).textRole(.body)
            Spacer()
            if member.isHost {
              StatusLabel("방장", role: .neutral)
            } else if member.isMe {
              StatusLabel("나", role: .neutral)
            }
          }
        }
      } header: {
        Text("일행").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      } footer: {
        if localDraftCount > 0 {
          Text("영수증 초안 \(localDraftCount)장은 아직 이 기기에만 있어요.").textRole(.supporting)
        }
      }
    }
    .navigationTitle(room.name)
    .accessibilityIdentifier("room-screen")
  }
}
