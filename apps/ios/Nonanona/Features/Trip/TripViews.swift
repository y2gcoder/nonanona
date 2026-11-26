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
        if failure == .inviteExpired {
          StatusLabel("초대 만료됨", role: .error)
        } else if failure == .inviteInvalid {
          StatusLabel("쓸 수 없는 초대", role: .error)
        } else if failure == .roomFinalized {
          StatusLabel("정산 확정된 여행방", role: .error)
        } else {
          StatusLabel("초대 대기 중", role: .attention)
        }
        Text("여행방에 초대받았어요").font(.title2.bold())
        Text(signedIn ? "참여하면 일행과 지출을 함께 정리할 수 있어요." : "참여하려면 로그인해 주세요. 공유한 영수증 초안은 그대로 남아요.")
          .textRole(.body)
        switch join {
        case .joining:
          HStack(spacing: Spacing.s) {
            ProgressView()
            Text("참여하는 중…").textRole(.supporting)
          }
        case .failed(let failure):
          Text(failure.message)
            .textRole(.supporting)
            .foregroundStyle(.red)
            .accessibilityIdentifier("invite-failed")
        case .idle:
          EmptyView()
        }
        // 만료되거나 쓸 수 없는 초대는 다시 시도해도 소용없으므로 버튼을 두지 않는다.
        if let action = primaryAction {
          Button(action.label, action: action.run)
            .buttonStyle(.primaryAction)
            .disabled(join == .joining)
            .accessibilityIdentifier("invite-primary")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.m)
    }
    .adaptiveContentMargins()
    .navigationTitle("여행방 초대")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("invite-screen")
  }

  private var failure: InviteAcceptFailure? {
    if case .failed(let failure) = join { failure } else { nil }
  }

  private var primaryAction: (label: String, run: () -> Void)? {
    switch (signedIn, failure) {
    case (_, .inviteExpired), (_, .inviteInvalid), (_, .roomFinalized): nil
    case (false, .sessionExpired): ("다시 로그인하기", onLogin)
    case (false, _): ("로그인하고 참여하기", onLogin)
    case (true, .some): ("다시 시도", onJoin)
    case (true, nil): ("참여하기", onJoin)
    }
  }
}

extension InviteAcceptFailure {
  fileprivate var message: String {
    switch self {
    case .sessionExpired: "로그인이 만료됐어요. 다시 로그인하면 이어서 참여해요."
    case .inviteExpired: "초대 링크가 만료됐어요. 방장에게 새 링크를 요청해 주세요."
    case .inviteInvalid: "이 초대 링크는 쓸 수 없어요. 방장에게 새 링크를 요청해 주세요."
    case .roomFinalized: "정산이 이미 확정된 여행방이라 새로 참여할 수 없어요. 방장에게 확인해 주세요."
    case .network: "인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요."
    case .unavailable: "지금은 여행방에 참여할 수 없어요. 잠시 후 다시 시도해 주세요."
    case .unknown: "참여하지 못했어요. 다시 시도해 주세요."
    }
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
    .adaptiveContentMargins()
    .navigationTitle(room.name)
    .accessibilityIdentifier("room-screen")
  }
}
