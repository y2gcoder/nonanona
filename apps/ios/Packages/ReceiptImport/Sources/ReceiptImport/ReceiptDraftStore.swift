import Foundation

public enum DraftSource: String, Codable, Sendable {
  case share
  case picker
}

/// 로그인 전에도 기기에 남는 영수증 초안. 원본 사진은 기기 밖으로 나가지 않는다.
public struct ReceiptDraft: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let createdAt: Date
  public let source: DraftSource
  public let photoFileNames: [String]
}

/// 가져올 사진 한 장.
public struct IncomingPhoto: Sendable {
  public enum Content: Sendable {
    case data(Data)
    case file(URL)
  }

  public let fileExtension: String
  public let content: Content

  public init(fileExtension: String, content: Content) {
    self.fileExtension = fileExtension
    self.content = content
  }
}

public enum ReceiptDraftError: Error, Equatable {
  case photoCount
  case noContainer
}

/// 초안 폴더를 다룬다. 사진과 목록 파일을 숨긴 임시 폴더에 다 쓴 뒤 이름을 바꿔서,
/// 쓰는 도중 프로세스가 끝나도 반쯤 쓴 초안이 목록에 보이지 않게 한다.
/// 앱과 공유 확장이 같은 App Group 폴더를 쓴다.
public struct ReceiptDraftStore: Sendable {
  public static let maxPhotos = 10
  private static let manifestName = "draft.json"

  public let root: URL
  private let now: @Sendable () -> Date

  public init(root: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.root = root
    self.now = now
  }

  /// App Group 컨테이너 안의 저장소.
  public static func inAppGroup(_ identifier: String) throws -> ReceiptDraftStore {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: identifier)
    else { throw ReceiptDraftError.noContainer }
    return ReceiptDraftStore(root: container.appending(path: "receipt-import", directoryHint: .isDirectory))
  }

  private var draftsDirectory: URL { root.appending(path: "drafts", directoryHint: .isDirectory) }

  @discardableResult
  public func create(source: DraftSource, photos: [IncomingPhoto]) throws -> ReceiptDraft {
    guard (1...Self.maxPhotos).contains(photos.count) else { throw ReceiptDraftError.photoCount }
    let fileManager = FileManager.default
    let id = UUID().uuidString.lowercased()
    let staging = draftsDirectory.appending(path: ".\(id).partial", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    do {
      var names: [String] = []
      for (index, photo) in photos.enumerated() {
        let name = String(format: "photo-%02d.%@", index + 1, Self.safeExtension(photo.fileExtension))
        let target = staging.appending(path: name)
        switch photo.content {
        case .data(let data): try writeProtected(data, to: target)
        case .file(let url): try fileManager.copyItem(at: url, to: target)
        }
        names.append(name)
      }
      let draft = ReceiptDraft(id: id, createdAt: now(), source: source, photoFileNames: names)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(draft).write(to: staging.appending(path: Self.manifestName))
      try fileManager.moveItem(at: staging, to: draftsDirectory.appending(path: id, directoryHint: .isDirectory))
      // 영수증 원본은 기기 백업에 넣지 않는다.
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var draftsFolder = draftsDirectory
      try? draftsFolder.setResourceValues(values)
      return draft
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
  }

  /// 다 쓴 초안만 최신순으로 돌려준다.
  public func list() -> [ReceiptDraft] {
    let folders =
      (try? FileManager.default.contentsOfDirectory(
        at: draftsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return
      folders
      .compactMap { folder in
        guard let data = try? Data(contentsOf: folder.appending(path: Self.manifestName)) else { return nil }
        return try? decoder.decode(ReceiptDraft.self, from: data)
      }
      .sorted { $0.createdAt > $1.createdAt }
  }

  public func photoURLs(of draft: ReceiptDraft) -> [URL] {
    let folder = draftsDirectory.appending(path: draft.id, directoryHint: .isDirectory)
    return draft.photoFileNames.map { folder.appending(path: $0) }
  }

  // MARK: - 처리 파일(같은 초안 폴더 안, 기기 밖으로 나가지 않는다)

  func draftURL(_ id: String) -> URL { draftsDirectory.appending(path: id, directoryHint: .isDirectory) }
  func photoURL(_ id: String, _ fileName: String) -> URL { draftURL(id).appending(path: fileName) }
  func proposalURL(_ id: String, _ itemID: String) -> URL { draftURL(id).appending(path: "proposals/\(itemID).json") }
  func reviewURL(_ id: String, _ itemID: String) -> URL { draftURL(id).appending(path: "reviews/\(itemID).json") }
  func artifactURL(_ id: String, _ fileName: String) -> URL { draftURL(id).appending(path: "confirmed/\(fileName)") }
  private func processingURL(_ id: String) -> URL { draftURL(id).appending(path: "processing.json") }

  /// 초안의 처리 상태. 아직 처리를 시작하지 않았으면 nil.
  public func loadProcessing(_ id: String) throws -> ProcessingManifest? {
    guard let data = try? Data(contentsOf: processingURL(id)) else { return nil }
    return try JSONDecoder().decode(ProcessingManifest.self, from: data)
  }

  func saveProcessing(_ manifest: ProcessingManifest) throws {
    try writeProtected(try JSONEncoder().encode(manifest), to: processingURL(manifest.draftID))
  }

  /// 원자적으로 쓰고, iOS에서는 기기 잠금 해제 전에는 읽을 수 없게 보호한다.
  func writeProtected(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    #if os(iOS)
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: url, options: .atomic)
    #endif
  }

  private static func safeExtension(_ raw: String) -> String {
    let cleaned = raw.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    return cleaned.isEmpty ? "img" : cleaned
  }
}
