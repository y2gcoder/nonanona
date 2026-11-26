import ReceiptImport
import UIKit
import UniformTypeIdentifiers

/// 사진 앱의 공유 메뉴에서 영수증을 받아 App Group의 초안 폴더에 담는다.
/// 로그인과 네트워크 없이 끝난다. 사진 처리는 앱에서 한다.
final class ShareViewController: UIViewController {
  private static let appGroup = "group.app.nonanona"
  private let status = UILabel()
  private lazy var save = UIButton(
    configuration: .filled(),
    primaryAction: UIAction(title: "초안에 담기") { [weak self] _ in self?.saveDraft() })

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let heading = UILabel()
    heading.text = "영수증 초안에 담기"
    heading.font = .preferredFont(forTextStyle: .headline)
    heading.adjustsFontForContentSizeCategory = true
    status.text = "사진 \(providers().count)장을 이 기기의 초안에 저장해요. 로그인하지 않아도 돼요."
    status.font = .preferredFont(forTextStyle: .body)
    status.adjustsFontForContentSizeCategory = true
    status.numberOfLines = 0
    status.accessibilityIdentifier = "share-status"
    save.accessibilityIdentifier = "share-save"
    save.configuration?.baseBackgroundColor = .label
    save.configuration?.baseForegroundColor = .systemBackground
    let cancel = UIButton(
      configuration: .plain(),
      primaryAction: UIAction(title: "취소") { [weak self] _ in
        self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
      })
    cancel.configuration?.baseForegroundColor = .label
    let stack = UIStackView(arrangedSubviews: [heading, status, save, cancel])
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
    ])
  }

  private func providers() -> [NSItemProvider] {
    (extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [])
      .flatMap { $0.attachments ?? [] }
      .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
  }

  private func saveDraft() {
    let providers = providers()
    guard (1...ReceiptDraftStore.maxPhotos).contains(providers.count) else {
      status.text = "사진은 한 번에 \(ReceiptDraftStore.maxPhotos)장까지 담을 수 있어요."
      return
    }
    save.isEnabled = false
    status.text = "사진 \(providers.count)장을 담는 중…"
    Task {
      do {
        var photos: [IncomingPhoto] = []
        for provider in providers { photos.append(try await Self.load(provider)) }
        try ReceiptDraftStore.inAppGroup(Self.appGroup).create(source: .share, photos: photos)
        extensionContext?.completeRequest(returningItems: nil)
      } catch {
        status.text = "사진을 초안에 담지 못했어요. 다시 시도해 주세요."
        save.isEnabled = true
      }
    }
  }

  /// 공유 확장의 메모리 한도 안에서 사진 바이트를 읽는다.
  private static func load(_ provider: NSItemProvider) async throws -> IncomingPhoto {
    let type =
      provider.registeredContentTypes.first { $0.conforms(to: .image) } ?? .image
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadDataRepresentation(for: type) { data, error in
        if let data {
          continuation.resume(returning: data)
        } else {
          continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
        }
      }
    }
    return IncomingPhoto(fileExtension: type.preferredFilenameExtension ?? "img", content: .data(data))
  }
}
