#if DEBUG
  import Foundation
  import ReceiptImport

  /// debug 미리보기 대역: 가상 영수증 품목 이름만 아는 정해 둔 사전이다. 실제 기계 번역이 아니며, 화면은 언제나
  /// "미리보기 대역 · 실제 번역 아님"으로 표시한다(`NameSource.preview`). 시뮬레이터는 Apple Translation이 번역하지 않아
  /// 화면 흐름(번역 → 고치기 → 다시 열기)을 보려고 둔다. 실행 환경 변수 `NONANONA_ITEM_TRANSLATION=preview`일 때만 쓴다.
  /// `NONANONA_ITEM_TRANSLATION=preview-fail-once`면 첫 번역을 실패시켜 다시 시도 경로를 본다.
  final class PreviewItemTranslator: ItemNameTranslator, @unchecked Sendable {
    let source: ItemPlanLine.NameSource = .preview
    let label = "미리보기 대역 · 실제 번역 아님"
    private let lock = NSLock()
    private var failuresLeft: Int

    static let dictionary: [String: String] = [
      "枝豆": "풋콩(미리보기)",
      "鶏の唐揚げ": "닭튀김(미리보기)",
      "生ビール 2杯": "생맥주 2잔(미리보기)",
      "ウーロン茶": "우롱차(미리보기)",
      "だし巻き玉子": "달걀말이(미리보기)",
      "おにぎり鮭": "연어 주먹밥(미리보기)",
      "緑茶ボトル": "녹차 병(미리보기)",
      "サンドイッチ": "샌드위치(미리보기)",
    ]

    init(failOnce: Bool) { failuresLeft = failOnce ? 1 : 0 }

    func availability() async -> ItemTranslationAvailability { .ready }

    func translate(_ texts: [String]) async throws -> [String] {
      let fail = lock.withLock {
        guard failuresLeft > 0 else { return false }
        failuresLeft -= 1
        return true
      }
      if fail { throw ItemTranslationError.failed }
      // 사전에 없는 이름은 빈 글자(번역하지 않음)로 둔다.
      return texts.map { Self.dictionary[$0] ?? "" }
    }
  }
#endif
