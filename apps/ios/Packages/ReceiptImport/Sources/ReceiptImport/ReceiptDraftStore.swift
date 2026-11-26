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

/// 기기 저장소에 쓰지 못했다(공간 부족, 보호된 파일 등). 화면은 "저장하지 못했어요"로 알리고 이전 상태를 지킨다.
public enum ReceiptStorageError: Error, Equatable {
  case writeFailed
  /// 파일은 있는데 읽지 못했다(보호된 파일, 입출력 오류 등). 없는 파일과 구분한다.
  case readFailed
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
  /// 검증용 쓰기 실패 주입(테스트와 debug 빌드만 넘긴다). true를 돌려주면 그 파일 쓰기가 실패한다.
  private let writeFault: (@Sendable (URL) -> Bool)?
  /// 검증용 읽기 실패 주입(테스트와 debug 빌드만 넘긴다). true를 돌려주면 있는 파일 읽기가 실패한다.
  private let readFault: (@Sendable (URL) -> Bool)?

  public init(
    root: URL, now: @escaping @Sendable () -> Date = { Date() }, writeFault: (@Sendable (URL) -> Bool)? = nil,
    readFault: (@Sendable (URL) -> Bool)? = nil
  ) {
    self.root = root
    self.now = now
    self.writeFault = writeFault
    self.readFault = readFault
  }

  /// App Group 컨테이너 안의 저장소.
  public static func inAppGroup(
    _ identifier: String, writeFault: (@Sendable (URL) -> Bool)? = nil, readFault: (@Sendable (URL) -> Bool)? = nil
  ) throws -> ReceiptDraftStore {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: identifier)
    else { throw ReceiptDraftError.noContainer }
    return ReceiptDraftStore(
      root: container.appending(path: "receipt-import", directoryHint: .isDirectory), writeFault: writeFault,
      readFault: readFault)
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
  func itemPlanURL(_ id: String, _ itemID: String) -> URL { draftURL(id).appending(path: "items/\(itemID).json") }
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

  /// 파일이 없으면 nil. 있는데 읽지 못하면 `readFailed`를 던진다(없는 파일로 여겨 새로 만들어 덮지 않게).
  func readIfPresent(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    if let readFault, readFault(url) { throw ReceiptStorageError.readFailed }
    do {
      return try Data(contentsOf: url)
    } catch {
      throw ReceiptStorageError.readFailed
    }
  }

  /// 원자적으로 쓰고, iOS에서는 기기 잠금 해제 전에는 읽을 수 없게 보호한다.
  func writeProtected(_ data: Data, to url: URL) throws {
    if let writeFault, writeFault(url) { throw ReceiptStorageError.writeFailed }
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
