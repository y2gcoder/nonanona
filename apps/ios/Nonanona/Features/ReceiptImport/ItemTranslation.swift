import Foundation
import ReceiptImport

#if canImport(Translation)
  import Translation
#endif

/// 일본어→한국어 기기 번역을 지금 쓸 수 있는가. 화면은 이 값으로 버튼과 안내를 정한다.
enum ItemTranslationAvailability: Equatable, Sendable {
  /// 언어가 기기에 있다. 번역할 수 있다.
  case ready
  /// 지원하지만 언어를 받아야 한다(사용자가 시스템 창에서 받는다).
  case needsDownload
  /// 이 기기·OS에서는 쓸 수 없다. 이름을 직접 적는다.
  case unsupported
}

/// 품목 이름 번역 제공자. 품목 글자는 기기 밖으로 보내지 않는다: 실제 구현은 기기 안 번역(Apple Translation)뿐이고,
/// debug 미리보기 대역은 정해 둔 사전이다. 결과는 사용자가 고칠 수 있는 제안일 뿐이다.
protocol ItemNameTranslator: Sendable {
  /// 계획에 남길 이름 출처(`.onDevice` 또는 `.preview`). 화면이 "미리보기 대역"을 따로 표시한다.
  var source: ItemPlanLine.NameSource { get }
  /// 화면에 보일 제공자 이름.
  var label: String { get }
  func availability() async -> ItemTranslationAvailability
  /// 들어온 순서대로 번역을 돌려준다. 하나라도 실패하면 던진다(부분 결과를 쓰지 않는다).
  func translate(_ texts: [String]) async throws -> [String]
}

enum ItemTranslationError: Error, Equatable {
  /// 언어가 없다고 하거나(설치 상태와 다르게) 번역이 실패했다. 다시 시도하거나 직접 적는다.
  case failed
  case unsupported
}

/// Apple Translation 기기 번역(일본어→한국어). 언어가 이미 기기에 있을 때만 번역한다(`installedSource`, iOS 26.4+).
/// 언어 받기는 화면의 `.translationTask`에서 시스템 창으로 사용자의 허락을 받는다(`prepareTranslation`).
/// 시뮬레이터는 번역하지 않는다(Apple 문서: "doesn't translate text in iOS or iPadOS simulators").
struct AppleItemTranslator: ItemNameTranslator {
  let source: ItemPlanLine.NameSource = .onDevice
  let label = "기기 번역(Apple Translation)"

  static let sourceLanguage = Locale.Language(identifier: "ja")
  static let targetLanguage = Locale.Language(identifier: "ko")

  func availability() async -> ItemTranslationAvailability {
    #if canImport(Translation)
      guard #available(iOS 18.0, *) else { return .unsupported }
      switch await LanguageAvailability().status(from: Self.sourceLanguage, to: Self.targetLanguage) {
      case .installed:
        guard #available(iOS 26.4, *) else { return .unsupported }
        return .ready
      case .supported: return .needsDownload
      case .unsupported: return .unsupported
      @unknown default: return .unsupported
      }
    #else
      return .unsupported
    #endif
  }

  func translate(_ texts: [String]) async throws -> [String] {
    #if canImport(Translation)
      guard #available(iOS 26.4, *) else { throw ItemTranslationError.unsupported }
      // 기기에 있는 언어만 쓴다. 높은 품질 전략은 기기 안 Apple Intelligence 모델이 있으면 그것을, 없으면 기존 기기 모델을 쓴다.
      let session = TranslationSession(
        installedSource: Self.sourceLanguage, target: Self.targetLanguage, preferredStrategy: .highFidelity)
      do {
        let responses = try await session.translations(
          from: texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) })
        var out = Array(repeating: "", count: texts.count)
        for response in responses {
          guard let index = response.clientIdentifier.flatMap(Int.init), out.indices.contains(index) else {
            throw ItemTranslationError.failed
          }
          out[index] = response.targetText
        }
        return out
      } catch let error as ItemTranslationError {
        throw error
      } catch {
        throw ItemTranslationError.failed
      }
    #else
      throw ItemTranslationError.unsupported
    #endif
  }
}

/// 번역을 쓸 수 없는 빌드(지금은 쓰지 않는다; 화면 테스트용).
struct UnavailableItemTranslator: ItemNameTranslator {
  let source: ItemPlanLine.NameSource = .onDevice
  let label = "기기 번역"
  func availability() async -> ItemTranslationAvailability { .unsupported }
  func translate(_ texts: [String]) async throws -> [String] { throw ItemTranslationError.unsupported }
}
