#if DEBUG
  import SwiftUI
  import UIKit
  import os

  /// iPhone Duo 자세 E2E(`scripts/e2e-posture.sh`)가 모으는 DEBUG 로그. release 빌드에는 없다.
  let debugLayoutLog = Logger(subsystem: "app.nonanona", category: "layout")

  /// 시스템이 알려 주는 hinge 상태를 남겨 Device Hub 자세 버튼이 어떤 자세인지 확인한다.
  /// Apple 문서(UIHinge)대로 hinge 값은 배치에 쓰지 않는다. 배치는 `ReservedRegion`만 본다.
  struct DebugHingeLog: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
      let view = UIView()
      view.isUserInteractionEnabled = false
      if #available(iOS 27.1, *) {
        view.addInteraction(
          UIHingeInteraction { _, update in
            guard let hinge = update.hinge else { return debugLayoutLog.debug("hinge none") }
            let degrees = Double(hinge.angle) * 180 / .pi
            debugLayoutLog.debug(
              "hinge status=\(hinge.status.debugName, privacy: .public) angle=\(degrees, format: .fixed(precision: 1), privacy: .public)"
            )
          })
      }
      return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
  }

  @available(iOS 27.1, *)
  extension UIHinge.Status {
    fileprivate var debugName: String {
      switch self {
      case .unknown: "unknown"
      case .closed: "closed"
      case .partiallyOpen: "partiallyOpen"
      case .fullyOpen: "fullyOpen"
      @unknown default: "raw\(rawValue)"
      }
    }
  }
#endif
