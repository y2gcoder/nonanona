import ImageIO
import ReceiptImport
import SwiftUI

struct DraftRow: View {
  let draft: ReceiptDraft
  let firstPhoto: URL?

  var body: some View {
    HStack(spacing: Spacing.m) {
      PhotoThumbnail(url: firstPhoto)
        .frame(width: 56, height: 56)
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("사진 \(draft.photoFileNames.count)장").textRole(.body)
        Text("\(draft.createdAt.formatted(Self.dateFormat)) · \(sourceText)")
          .textRole(.supporting)
          .foregroundStyle(.secondary)
        StatusLabel("기기에만 저장됨", role: .neutral)
      }
    }
    .padding(.vertical, Spacing.xs)
  }

  private var sourceText: String {
    switch draft.source {
    case .share: "공유로 받음"
    case .picker: "직접 고름"
    }
  }

  /// Android와 같은 "11월 21일 18:20" 형식.
  private static let dateFormat = Date.VerbatimFormatStyle(
    format:
      "\(month: .defaultDigits)월 \(day: .defaultDigits)일 \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
    timeZone: .current, calendar: Calendar(identifier: .gregorian))
}

struct DraftsEmptyView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("아직 초안이 없어요").textRole(.body)
      Text("사진 앱에서 영수증을 공유하거나 사진을 골라 주세요. 로그인하지 않아도 이 기기에 보관돼요.")
        .textRole(.supporting)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("drafts-empty")
  }
}

/// 초안의 영수증 목록(검토 대기열). 처리 중·읽지 못함·확인 필요·확인함을 글자로 보이고, 행을 누르면 그 영수증의 검토 화면을 연다.
/// 확인할 영수증은 "확인할 영수증 검토"로 목록 순서대로 이어서 본다.
struct DraftView: View {
  let draft: ReceiptDraft
  let photoURLs: [URL]
  let processing: ProcessingManifest?
  /// 확인 필요한 사진의 한 줄 요약(가게 · 날짜 · 금액 · 가림). 아직 불러오지 않았으면 nil.
  let rowSummary: (String) -> String?
  /// 확인할 사진을 다 보고 목록으로 돌아왔는지.
  let reviewFinished: Bool
  let manualEntryCount: Int
  let onOpen: (String) -> Void
  let onStartReview: () -> Void
  let onRetry: (String) -> Void
  /// debug 빌드에서만 값이 있다.
  let onDebugConfirm: ((String) -> Void)?
  /// 개발용 올리기 화면에 넘길 값. debug 빌드에서만 그린다.
  var upload: DraftUploadContext?

  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: Spacing.s) {
          StatusLabel("기기에만 저장됨", role: .neutral)
          Text("로그인하지 않아도 이 기기에 보관돼요. 사진은 이 기기 안에서만 읽어요.").textRole(.supporting)
          if let processing {
            Text("읽음 \(processing.processedCount)/\(processing.items.count)")
              .textRole(.sectionTitle)
              .accessibilityIdentifier("processing-summary")
            Text("확인 \(processing.count(.confirmed))/\(processing.items.count)")
              .textRole(.sectionTitle)
              .accessibilityIdentifier("review-summary")
            Text(breakdown(processing))
              .textRole(.supporting)
              .accessibilityIdentifier("queue-breakdown")
            if processing.recoveredCount > 0 {
              Text("앱이 중간에 닫혀 이어서 읽은 사진 \(processing.recoveredCount)장")
                .textRole(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("processing-recovered")
            }
          }
        }
        if let processing {
          if reviewFinished, processing.count(.ready) == 0 {
            Text(finishedText(processing))
              .textRole(.body)
              .accessibilityIdentifier("review-finished")
          }
          if let failed = processing.items.sorted(by: { $0.position < $1.position }).first(where: {
            $0.state == .failed
          }) {
            VStack(alignment: .leading, spacing: Spacing.s) {
              Text("읽지 못한 사진 \(processing.count(.failed))장이 있어요. 다시 읽거나 값을 직접 입력해 주세요.")
                .textRole(.body)
              Button("사진 \(failed.position) 열기") { onOpen(failed.id) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("open-first-failed")
            }
          }
          Button("확인할 영수증 검토 (\(processing.count(.ready)))", action: onStartReview)
            .buttonStyle(.primaryAction)
            .disabled(processing.count(.ready) == 0)
            .accessibilityIdentifier("review-start")
          if processing.count(.ready) == 0, processing.hasPendingWork {
            Text("다 읽으면 확인할 수 있어요. 나머지는 이 기기에서 계속 읽어요.").textRole(.caption).foregroundStyle(.secondary)
          }
        }
      }
      #if DEBUG
        if let upload {
          DebugUploadSection(context: upload, manualEntryCount: manualEntryCount)
        }
      #endif
      Section {
        ForEach(Array(photoURLs.enumerated()), id: \.offset) { index, url in
          PhotoRow(
            position: index + 1, url: url, item: processing?.items.first { $0.position == index + 1 },
            summary: processing?.items.first { $0.position == index + 1 }.flatMap { rowSummary($0.id) },
            onOpen: onOpen, onRetry: onRetry, onDebugConfirm: onDebugConfirm)
        }
      } header: {
        Text("영수증 \(photoURLs.count)장").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      }
    }
    .adaptiveContentMargins()
    .navigationTitle("초안")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("draft-screen")
  }

  /// "읽는 중 2 · 대기 4 · 확인 필요 3 · 읽지 못함 1 · 확인함 0" 중 0이 아닌 것. 읽는 중과 대기를 나눠 보인다.
  private func breakdown(_ m: ProcessingManifest) -> String {
    let parts: [(String, Int)] = [
      ("읽는 중", m.count(.processing)), ("대기", m.count(.queued)), ("확인 필요", m.count(.ready)),
      ("읽지 못함", m.count(.failed)), ("확인함", m.count(.confirmed)),
    ]
    return parts.filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
  }

  private func finishedText(_ m: ProcessingManifest) -> String {
    var remaining: [String] = []
    if m.count(.failed) > 0 { remaining.append("읽지 못함 \(m.count(.failed))장") }
    if m.hasPendingWork { remaining.append("읽는 중·대기 \(m.count(.processing) + m.count(.queued))장") }
    return remaining.isEmpty
      ? "모든 영수증을 확인했어요."
      : "지금 확인할 수 있는 영수증을 모두 확인했어요. 남은 것: " + remaining.joined(separator: ", ")
  }
}

/// 초안 화면이 개발용 올리기 화면에 넘기는 값. 최종 확인은 모델이 가지고 `RootView`가 띄운다(화면 배치가 바뀌어도 남는다).
struct DraftUploadContext {
  let destination: TripRoom?
  let confirmedCount: Int
  let state: UploadState
  let signedIn: Bool
  let onRequest: () -> Void
  let onLogin: () -> Void
  /// 직접 입력(사진 없음) 올리기 상태와 요청. 사본 올리기와 따로 묻고 따로 보낸다.
  var manualState: UploadState = .idle
  var onRequestManual: () -> Void = {}
}

private struct PhotoRow: View {
  let position: Int
  let url: URL
  let item: ProcessingItem?
  let summary: String?
  let onOpen: (String) -> Void
  let onRetry: (String) -> Void
  let onDebugConfirm: ((String) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.s) {
      // 행의 주 동작(검토 화면 열기)은 사진과 번호를 감싼 버튼이다. 상태 라벨·설명은 버튼 밖의 글자로 두어
      // 화면 읽기에서 따로 읽히고, 눌러도 같은 화면을 연다.
      Button {
        if let item { onOpen(item.id) }
      } label: {
        HStack(spacing: Spacing.m) {
          PhotoThumbnail(url: url)
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
          Text("사진 \(position)").textRole(.body).foregroundStyle(.primary)
          Spacer(minLength: 0)
          Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .contentShape(.rect)
      }
      // 목록 행 안의 버튼은 borderless여야 각자 눌린다(행 전체가 한 버튼처럼 동작하지 않게).
      .buttonStyle(.borderless)
      .disabled(item == nil)
      .accessibilityHint("검토 화면을 열어요")
      .accessibilityIdentifier("item-\(position)-open")
      if let item {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          StatusLabel(item.statusText, role: item.statusRole)
            .accessibilityIdentifier("item-\(position)-status")
          if let detail = item.detailText(summary: summary) {
            Text(detail).textRole(.supporting).foregroundStyle(.secondary)
              .accessibilityIdentifier("item-\(position)-detail")
          }
        }
        .contentShape(.rect)
        .onTapGesture { onOpen(item.id) }
      }
      if let item {
        HStack(spacing: Spacing.m) {
          if item.state == .failed {
            Button("다시 읽기") { onRetry(item.id) }
              .buttonStyle(.borderless)
              .accessibilityLabel("사진 \(position) 다시 읽기")
              .accessibilityIdentifier("item-\(position)-retry")
            Button("직접 입력") { onOpen(item.id) }
              .buttonStyle(.borderless)
              .accessibilityLabel("사진 \(position) 직접 입력")
              .accessibilityIdentifier("item-\(position)-manual")
          }
          #if DEBUG
            if item.state == .ready, let onDebugConfirm {
              Button("확인(개발용)") { onDebugConfirm(item.id) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("item-\(position)-debug-confirm")
            }
          #endif
        }
      }
    }
    .padding(.vertical, Spacing.xs)
  }
}

extension ProcessingItem {
  fileprivate var statusText: String {
    switch state {
    case .queued: "대기 중"
    case .processing: "읽는 중"
    case .ready: "확인 필요"
    case .failed: "읽지 못함"
    case .confirmed: "확인함"
    }
  }

  fileprivate var statusRole: StatusRole {
    switch state {
    case .queued, .processing: .neutral
    case .ready: .attention
    case .failed: .error
    case .confirmed: .positive
    }
  }

  fileprivate func detailText(summary: String?) -> String? {
    if let fields = confirmed?.fields {
      let amount = "\(fields.date) · \(fields.amountMinor.formatted()) \(fields.currency)"
      return confirmed?.isManualEntry == true ? "\(amount) · 직접 입력(사진은 올리지 않아요)" : amount
    }
    switch state {
    case .ready: return summary
    case .processing where attempts > 1: return "다시 읽는 중이에요."
    case .failed:
      return switch failure {
      case .unreadable: "글자를 읽지 못했어요. 다시 읽거나 직접 입력해 주세요."
      case .missingTotal: "합계 금액을 찾지 못했어요."
      case .missingDate: "날짜를 찾지 못했어요."
      case .invalidImage: "이미지를 열 수 없어요."
      case .recognitionError, nil: "읽는 중 문제가 생겼어요. 다시 읽어 주세요."
      }
    default: return nil
    }
  }
}

/// 파일에서 작은 미리보기를 만든다. 원본 크기로 디코딩하지 않는다.
struct PhotoThumbnail: View {
  let url: URL?
  @State private var image: UIImage?

  var body: some View {
    Color(uiColor: .tertiarySystemFill)
      .overlay {
        if let image {
          Image(uiImage: image).resizable().scaledToFill()
        }
      }
      .clipShape(.rect(cornerRadius: 8))
      .task(id: url) { image = await Self.thumbnail(url) }
  }

  private static func thumbnail(_ url: URL?) async -> UIImage? {
    guard let url else { return nil }
    return await Task.detached(priority: .utility) {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 320,
      ]
      return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
    }.value
  }
}
