#if DEBUG
  import Foundation

  /// debug 빌드 전용 여행방 구현체. 어떤 초대든 가상 여행방 하나로 수락한다. 로그인 전에는 거절한다.
  struct TestTripGateway: TripGateway {
    let auth: any AuthGateway

    func acceptInvite(_ code: InviteCode) async throws -> TripRoom {
      guard let session = await auth.restoreSession() else { throw TripError(reason: "sign in first") }
      try await Task.sleep(for: .milliseconds(400))
      return TripRoom(
        id: TripID(value: "test-trip-\(code.value.lowercased())"),
        name: "가상 도쿄 여행",
        members: [
          TripMember(displayName: "다라", isHost: true, isMe: false),
          TripMember(displayName: session.displayName, isHost: false, isMe: true),
        ])
    }
  }
#endif
