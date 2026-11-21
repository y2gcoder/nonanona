import SwiftUI

struct LoginSheet: View {
  let state: LoginState
  let providers: [SignInProvider]
  let testOnlyNotice: String?
  let onSignIn: (SignInProvider) -> Void
  let onCancel: () -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.m) {
          Text("여행방을 만들거나 초대를 수락하려면 로그인해요.").textRole(.body)
          if let testOnlyNotice {
            StatusLabel(testOnlyNotice, role: .neutral)
              .accessibilityIdentifier("login-test-notice")
          }
          if providers.isEmpty {
            Text("지금은 로그인할 수 없어요.")
              .textRole(.body)
              .accessibilityIdentifier("login-unavailable")
          }
          ForEach(providers, id: \.self) { provider in
            providerButton(provider)
          }
          switch state {
          case .signingIn:
            HStack(spacing: Spacing.s) {
              ProgressView()
              Text("로그인하는 중…").textRole(.supporting)
            }
          // 다시 시도는 같은 제공자 버튼으로 한다. 제공자 원문은 보여 주지 않는다.
          case .failed(let failure):
            Text(failure.message)
              .textRole(.supporting)
              .foregroundStyle(.red)
              .accessibilityIdentifier("login-failed")
          case .hidden, .choosing:
            EmptyView()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
      }
      .navigationTitle("로그인")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("취소", action: onCancel).disabled(state == .signingIn)
        }
      }
    }
    // 시트는 루트의 tint를 물려받지 않으므로 중립 팔레트를 다시 지정한다.
    .tint(.primary)
    .presentationDetents([.medium, .large])
    .interactiveDismissDisabled(state == .signingIn)
  }

  /// Apple 버튼은 HIG의 검정/흰색 스타일을 따른다. 실제 연결 때 `SignInWithAppleButton`으로 바꾼다.
  @ViewBuilder
  private func providerButton(_ provider: SignInProvider) -> some View {
    switch provider {
    case .apple:
      Button(action: { onSignIn(.apple) }) {
        Label("Apple로 계속하기", systemImage: "apple.logo")
      }
      .buttonStyle(.primaryAction)
      .disabled(state == .signingIn)
      .accessibilityIdentifier("login-apple")
    case .google:
      Button(action: { onSignIn(.google) }) {
        Text("Google로 계속하기").font(.headline).frame(maxWidth: .infinity, minHeight: 42)
      }
      .buttonStyle(.bordered)
      .disabled(state == .signingIn)
      .accessibilityIdentifier("login-google")
    }
  }
}

extension SignInFailure {
  fileprivate var message: String {
    switch self {
    case .network: "인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요."
    case .unavailable: "지금은 로그인할 수 없어요. 잠시 후 다시 시도해 주세요."
    case .cancelled, .unknown: "로그인하지 못했어요. 다시 시도해 주세요."
    }
  }
}
