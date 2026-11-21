#if DEBUG
  import SwiftUI

  /// 개발용 올리기: 참여한 여행방을 올릴 곳으로 보여 주고, 최종 확인을 받은 뒤에만 확인한 영수증을 올린다.
  /// 디자인이 정해지기 전의 검증용 화면이며 release 빌드에는 없다.
  struct DebugUploadSection: View {
    let destination: TripRoom?
    let confirmedCount: Int
    let state: UploadState
    let signedIn: Bool
    let onUpload: () -> Void
    let onLogin: () -> Void
    @State private var confirming = false

    var body: some View {
      Section {
        if let destination {
          Text("올릴 곳: \(destination.name)").textRole(.body).accessibilityIdentifier("upload-destination")
          Text("확인한 영수증 \(confirmedCount)장").textRole(.supporting)
          statusView
          if !signedIn {
            Button("다시 로그인하기", action: onLogin).accessibilityIdentifier("upload-login")
          }
          Button("여행방에 올리기(개발용)") { confirming = true }
            .disabled(confirmedCount == 0 || state == .uploading || !signedIn)
            .accessibilityIdentifier("upload-start")
            .confirmationDialog(
              "‘\(destination.name)’에 영수증 \(confirmedCount)장을 올릴까요?", isPresented: $confirming,
              titleVisibility: .visible
            ) {
              Button("올리기", action: onUpload).accessibilityIdentifier("upload-final")
              Button("취소", role: .cancel) {}
            } message: {
              Text("가림을 확인한 사본과 날짜·금액·통화·가게만 올라가요.")
            }
        } else {
          Text("참여한 여행방이 없어요. 초대 링크로 참여한 뒤 올릴 수 있어요.").textRole(.supporting)
        }
      } header: {
        Text("여행방에 올리기(개발용)").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      }
    }

    @ViewBuilder private var statusView: some View {
      switch state {
      case .idle: EmptyView()
      case .uploading:
        Text("올리는 중…").textRole(.supporting).accessibilityIdentifier("upload-status")
      case .done(let created, let replayed):
        Text("올림 \(created + replayed)장(이미 올린 \(replayed)장 포함)")
          .textRole(.supporting).accessibilityIdentifier("upload-status")
      case .failed(let failure, _):
        Text(message(failure)).textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier("upload-status")
      }
    }

    private func message(_ failure: ReceiptUploadFailure) -> String {
      switch failure {
      case .sessionExpired: "로그인이 만료됐어요. 다시 로그인한 뒤 다시 올려 주세요."
      case .destinationUnavailable: "이 여행방에 올릴 수 없어요. 여행방 구성원인지 확인해 주세요."
      case .network: "인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요."
      case .unavailable: "지금은 올릴 수 없어요. 잠시 후 다시 시도해 주세요."
      case .unknown: "올리지 못했어요. 다시 시도해 주세요."
      }
    }
  }
#endif
