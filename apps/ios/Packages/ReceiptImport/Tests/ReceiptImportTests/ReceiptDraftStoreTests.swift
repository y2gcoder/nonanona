import Foundation
import ReceiptImport
import Testing

struct ReceiptDraftStoreTests {
  private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

  private func photo(_ bytes: [UInt8]) -> IncomingPhoto {
    IncomingPhoto(fileExtension: "png", content: .data(Data(bytes)))
  }

  @Test func draftSurvivesNewStoreInstance() throws {
    let created = try ReceiptDraftStore(root: root, now: { Date(timeIntervalSince1970: 1) })
      .create(source: .share, photos: [photo([1, 2]), photo([3])])

    // 프로세스를 다시 시작한 것처럼 새 인스턴스로 읽는다.
    let reopened = ReceiptDraftStore(root: root)
    let drafts = reopened.list()

    #expect(drafts == [created])
    #expect(try reopened.photoURLs(of: created).map { try Data(contentsOf: $0) } == [Data([1, 2]), Data([3])])
  }

  @Test func interruptedWriteIsNotListed() throws {
    let store = ReceiptDraftStore(root: root)
    let missing = IncomingPhoto(fileExtension: "png", content: .file(root.appending(path: "missing.png")))

    #expect(throws: (any Error).self) { try store.create(source: .share, photos: [photo([1]), missing]) }
    // 이름을 바꾸기 전에 끝난 초안 폴더가 남아 있어도 목록에는 없다.
    try FileManager.default.createDirectory(
      at: root.appending(path: "drafts/.leftover.partial"), withIntermediateDirectories: true)

    #expect(store.list().isEmpty)
  }

  @Test func newestDraftComesFirst() throws {
    let first = try ReceiptDraftStore(root: root, now: { Date(timeIntervalSince1970: 1) })
      .create(source: .share, photos: [photo([1])])
    let second = try ReceiptDraftStore(root: root, now: { Date(timeIntervalSince1970: 2) })
      .create(source: .picker, photos: [photo([2])])

    #expect(ReceiptDraftStore(root: root).list().map(\.id) == [second.id, first.id])
  }

  @Test func rejectsMoreThanTenPhotos() {
    #expect(throws: ReceiptDraftError.photoCount) {
      try ReceiptDraftStore(root: root).create(source: .share, photos: Array(repeating: photo([0]), count: 11))
    }
  }
}
