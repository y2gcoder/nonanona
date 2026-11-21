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

/// 초안의 사진과 사진별 처리 상태. 검토·확인 화면은 디자인이 정해진 뒤 붙인다(지금은 상태만 보인다).
struct DraftView: View {
  let draft: ReceiptDraft
  let photoURLs: [URL]
  let processing: ProcessingManifest?
  let onRetry: (String) -> Void
  /// debug 빌드에서만 값이 있다.
  let onDebugConfirm: ((String) -> Void)?

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
            if processing.recoveredCount > 0 {
              Text("앱이 중간에 닫혀 이어서 읽은 사진 \(processing.recoveredCount)장")
                .textRole(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("processing-recovered")
            }
          }
        }
      }
      Section {
        ForEach(Array(photoURLs.enumerated()), id: \.offset) { index, url in
          PhotoRow(
            position: index + 1, url: url, item: processing?.items.first { $0.position == index + 1 },
            onRetry: onRetry, onDebugConfirm: onDebugConfirm)
        }
      } header: {
        Text("사진 \(photoURLs.count)장").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      }
    }
    .navigationTitle("초안")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("draft-screen")
  }
}

private struct PhotoRow: View {
  let position: Int
  let url: URL
  let item: ProcessingItem?
  let onRetry: (String) -> Void
  let onDebugConfirm: ((String) -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.m) {
      PhotoThumbnail(url: url)
        .frame(width: 56, height: 56)
        .accessibilityLabel("영수증 사진 \(position)")
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("사진 \(position)").textRole(.body)
        if let item {
          StatusLabel(item.statusText, role: item.statusRole)
            .accessibilityIdentifier("item-\(position)-status")
          if let detail = item.detailText {
            Text(detail).textRole(.supporting).foregroundStyle(.secondary)
          }
          HStack(spacing: Spacing.s) {
            if item.state == .failed {
              // 목록 행 안의 버튼은 borderless여야 각자 눌린다(행 전체가 한 버튼처럼 동작하지 않게).
              Button("다시 읽기") { onRetry(item.id) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("item-\(position)-retry")
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

  fileprivate var detailText: String? {
    if let fields = confirmed?.fields {
      return "\(fields.date) · \(fields.amountMinor.formatted()) \(fields.currency)"
    }
    guard state == .failed, let failure else { return nil }
    return switch failure {
    case .unreadable: "글자를 읽지 못했어요. 다시 읽거나 다른 사진을 골라 주세요."
    case .missingTotal: "합계 금액을 찾지 못했어요."
    case .missingDate: "날짜를 찾지 못했어요."
    case .invalidImage: "이미지를 열 수 없어요."
    case .recognitionError: "읽는 중 문제가 생겼어요. 다시 읽어 주세요."
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
