#if DEBUG
  import Foundation
  import os

  /// debug 빌드 전용 여행방 구현체. 가상 여행방 하나로 초대를 수락한다. 로그인 전에는 세션 만료로 거절한다.
  ///
  /// 실패와 복구를 기기에서 확인하기 위한 가상 초대 코드(Android 테스트 구현체와 같다):
  /// - `SYNTHEXPIRED01`: 항상 초대 만료
  /// - `SYNTHOFFLINE01`: 앱 실행마다 첫 시도만 연결 실패, 다시 시도하면 수락
  /// - `SYNTHSESSION01`: 앱 실행마다 첫 시도만 세션 만료, 다시 로그인하면 수락
  final class TestTripGateway: TripGateway, Sendable {
    let auth: any AuthGateway
    private let failedOnce = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    init(auth: any AuthGateway) {
      self.auth = auth
    }

    func acceptInvite(_ code: InviteCode) async throws(InviteAcceptFailure) -> TripRoom {
      guard let session = await auth.restoreSession() else { throw .sessionExpired }
      do {
        try await Task.sleep(for: .milliseconds(400))
      } catch {
        throw .unknown
      }
      if let failure = fixtureFailure(code) { throw failure }
      return TripRoom(
        id: TripID(value: "test-trip-\(code.value.lowercased())"),
        name: "가상 도쿄 여행",
        members: [
          TripMember(displayName: "다라", isHost: true, isMe: false),
          TripMember(displayName: session.displayName, isHost: false, isMe: true),
        ])
    }

    private func fixtureFailure(_ code: InviteCode) -> InviteAcceptFailure? {
      let first = failedOnce.withLock { $0.insert(code.value).inserted }
      switch code.value {
      case "SYNTHEXPIRED01": return .inviteExpired
      case "SYNTHOFFLINE01": return first ? .network : nil
      case "SYNTHSESSION01": return first ? .sessionExpired : nil
      default: return nil
      }
    }
  }
#endif
