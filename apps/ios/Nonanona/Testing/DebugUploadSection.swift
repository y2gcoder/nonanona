#if DEBUG
  import SwiftUI

  /// 개발용 올리기: 참여한 여행방을 올릴 곳으로 보여 주고, 최종 확인을 받은 뒤에만 확인한 영수증을 올린다.
  /// 디자인이 정해지기 전의 검증용 화면이며 release 빌드에는 없다.
  /// 올릴 곳·장수 최종 확인. 화면 맨 위(`RootView`)에서 한 번만 띄운다(Android AlertDialog와 같음).
  /// 예전처럼 목록 행 안 버튼의 확인 시트로 두면 넓은 창에서 그 버튼을 가리키는 팝오버가 되는데, 열린 채 돌려 크기 종류가
  /// 바뀌면 다시 뜨지 못하고 멈췄다(시뮬레이터에서 재현). 알림은 기준 뷰가 없고, 초안이 어느 열에 있든 한 번만 뜨며,
  /// 시스템이 가운데(접힘을 피해) 둔다.
  struct DebugUploadConfirmation: ViewModifier {
    let confirmation: UploadConfirmation?
    let onConfirm: (UploadConfirmation) -> Void
    let onCancel: () -> Void

    func body(content: Content) -> some View {
      content.alert(
        confirmation.map { "‘\($0.tripName)’에 영수증 \($0.count)장을 올릴까요?" } ?? "",
        isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { onCancel() } }),
        presenting: confirmation
      ) { confirmation in
        Button("올리기") { onConfirm(confirmation) }.accessibilityIdentifier("upload-final")
        Button("취소", role: .cancel, action: onCancel)
      } message: { _ in
        Text("가림을 확인한 사본과 날짜·금액·통화·가게만 올라가요.")
      }
    }
  }

  struct DebugUploadSection: View {
    let context: DraftUploadContext
    var manualEntryCount = 0

    var body: some View {
      Section {
        if let destination = context.destination {
          Text("올릴 곳: \(destination.name)").textRole(.body).accessibilityIdentifier("upload-destination")
          Text("확인한 영수증 \(context.confirmedCount)장").textRole(.supporting)
          if manualEntryCount > 0 {
            Text("직접 입력 \(manualEntryCount)건은 사진이 없어 이번에는 올리지 않아요(기기에만 있어요).")
              .textRole(.supporting).accessibilityIdentifier("upload-manual-excluded")
          }
          statusView
          if !context.signedIn {
            Button("다시 로그인하기", action: context.onLogin).accessibilityIdentifier("upload-login")
          }
          Button("여행방에 올리기(개발용)", action: context.onRequest)
            .disabled(context.confirmedCount == 0 || context.state == .uploading || !context.signedIn)
            .accessibilityIdentifier("upload-start")
        } else {
          Text("참여한 여행방이 없어요. 초대 링크로 참여한 뒤 올릴 수 있어요.").textRole(.supporting)
        }
      } header: {
        Text("여행방에 올리기(개발용)").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      }
    }

    @ViewBuilder private var statusView: some View {
      switch context.state {
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
