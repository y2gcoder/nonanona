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

struct DraftView: View {
  let draft: ReceiptDraft
  let photoURLs: [URL]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.m) {
        VStack(alignment: .leading, spacing: Spacing.s) {
          Text("사진 \(photoURLs.count)장").textRole(.sectionTitle)
          StatusLabel("기기에만 저장됨", role: .neutral)
          Text("로그인하지 않아도 이 기기에 보관돼요.").textRole(.supporting)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: Spacing.s)], spacing: Spacing.s) {
          ForEach(Array(photoURLs.enumerated()), id: \.offset) { index, url in
            PhotoThumbnail(url: url)
              .aspectRatio(1, contentMode: .fit)
              .accessibilityLabel("영수증 사진 \(index + 1)")
          }
        }
      }
      .padding(Spacing.m)
    }
    .navigationTitle("초안")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("draft-screen")
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
