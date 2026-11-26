import Foundation
import Observation
import ReceiptImport

/// 품목명 다시 번역 한 번(영수증마다). 시트가 아니라 이 값이 요청과 결과를 가진다.
struct ItemRetranslationSession: Equatable {
  enum Phase: Equatable {
    case consent, requesting, results, unavailable, changed
  }

  /// 기기 저장에 실패한 일. 시트는 같은 안내를 보이고, 단추(‘다시 저장’, 기록 삭제면 ‘다시 시도’)는 그 일을 다시 한다.
  enum Failure: Equatable {
    /// 보내기 전 기록을 쓰지 못해 보내지 않았다(다시 확인하면 그때 보낸다).
    case marker
    /// 받은 결과(또는 줄 상태)를 기록에 쓰지 못했다. 결과는 메모리에 있다.
    case save
    /// ‘이 이름 사용’의 품목 계획을 기기에 쓰지 못했다. 제안은 그대로 남아 다시 적용할 수 있다.
    case apply(lineID: String, name: String)
    /// 기록을 지우지 못했다. `ending`이면 지운 뒤 시트를 닫는다(‘닫기’·적용으로 끝남).
    case clear(ending: Bool)
  }

  static let maximumSelection = 32

  /// 이 세션의 식별자. 늦게 온 완료·닫힘 알림이 다른(새) 세션을 건드리지 않게 한다.
  let id = UUID()
  /// 시트를 열 때 고를 수 있던 줄(여러 품목이면 줄 선택 목록).
  let candidates: [ItemPlanLine]
  let isBatch: Bool
  var selection: Set<String> = []
  var phase = Phase.consent
  /// 보낸 줄(보낼 때의 스냅샷). "이 이름 사용"은 이 스냅샷이 지금 줄과 같을 때만 적용된다.
  var requested: [ItemPlanLine] = []
  var suggestions: [String: String] = [:]
  /// 줄 ID → 적용함(true) 또는 품목이 바뀌어 적용하지 않음(false).
  var accepted: [String: Bool] = [:]
  var failure: Failure?
  /// 기기에 쓰거나 지우는 중(첫 결과 저장·적용·닫기·다시 저장). 그동안 단추와 쓸기를 막는다.
  private(set) var saving = false
  fileprivate var operation: UUID?
  fileprivate var request: UUID?
  /// 이 세션이 기기의 기록을 만들었거나 복원했다. 아니면 닫아도 파일을 건드리지 않는다.
  fileprivate var ownsRecord = false

  init(candidates: [ItemPlanLine], isBatch: Bool? = nil) {
    self.candidates = candidates
    self.isBatch = isBatch ?? (candidates.count > 1)
  }

  var selectedLines: [ItemPlanLine] { isBatch ? candidates.filter { selection.contains($0.id) } : candidates }
  /// 동의 단계가 아니면 보낸 줄을 보인다.
  var shownLines: [ItemPlanLine] { phase == .consent || requested.isEmpty ? selectedLines : requested }
  /// 요청 중·결과 단계·저장 중이면 바깥 터치·아래로 쓸기로 닫지 않는다(‘닫기’로만). 기록 삭제 실패가 남아 있어도 막는다
  /// (‘다시 시도’나 ‘닫기’로만 끝낸다. Android와 같다). 동의·줄 선택·실패·변경 안내는 쉽게 닫힌다.
  var blocksDismissal: Bool { phase == .requesting || phase == .results || saving || retriesClear }
  var saveFailed: Bool { failure != nil }
  /// 요청 중에는 ‘닫기’를 쓸 수 없다(응답 뒤에만 ‘닫기’로 마친다).
  var canClose: Bool { phase != .requesting && !saving }
  /// 저장 실패의 다시 하기 단추를 보일지. 보내기 전 기록 실패는 ‘확인하고 다시 번역’이 다시 하는 일이다.
  var canRetrySave: Bool { failure != nil && failure != .marker }
  /// 실패한 일이 기록 삭제다. 단추 이름이 ‘다시 시도’다(‘다시 저장’은 결과 저장과 적용 실패에만 쓴다).
  var retriesClear: Bool {
    if case .clear = failure { return true }
    return false
  }
  /// 적용으로 끝난 한 줄 결과. 남길 것이 없다.
  fileprivate var isFinished: Bool { !isBatch && phase == .results && accepted.values.contains(true) }
  /// 기기에 남길 기록. 결과 단계에서 아직 끝나지 않았을 때만이다.
  fileprivate var record: ItemRetranslationRecord? {
    guard phase == .results, !isFinished else { return nil }
    return ItemRetranslationRecord(
      state: .received, batch: isBatch, requested: requested, suggestions: suggestions, accepted: accepted)
  }

  fileprivate mutating func startOperation() -> UUID {
    let operation = UUID()
    self.operation = operation
    saving = true
    return operation
  }

  fileprivate mutating func endOperation(_ failure: Failure?) {
    operation = nil
    saving = false
    self.failure = failure
  }
}

/// 품목 재번역의 요청과 결과를 시트보다 오래 가진다(앱 모델이 하나 둔다). 시트가 뷰 계층에서 빠졌다 다시 붙어도 요청은
/// 이어지고 다시 보내지 않는다. 받았지만 끝내지 않은 결과와 기다리던 요청은 초안 폴더(`retranslations/`)에 남겨, 앱을 다시
/// 열어 그 영수증의 품목 화면에 들어오면 다시 보인다. 기다리던 요청은 다시 보내지 않고 받지 못했다고 알린다.
/// 비동기 완료는 자기가 시작한 세션(`id`)과 작업(`operation`·`request`)이 그대로일 때만 반영한다.
@MainActor @Observable
final class ItemRetranslationModel {
  typealias Translate = @Sendable ([String]) async throws -> [String?]

  /// 영수증마다 남긴 기록을 읽은 상태. 다 읽기 전에는 새 재번역을 시작하지 않는다(기존 결과를 지우거나 덮지 않게).
  enum Restore: Equatable {
    case restoring
    /// 기록이 있는데 읽지 못했다. 파일은 그대로이고 다시 읽을 수 있다.
    case failed
    case done
  }

  /// "이 이름 사용"의 결과. `applied`는 품목 계획이 기기에 남은 뒤에만이다.
  enum ApplyOutcome: Equatable {
    case applied
    /// 스냅샷이 지금 줄과 달라 적용하지 않았다.
    case rejected
    /// 계획을 바꿨지만 기기에 쓰지 못했다.
    case saveFailed
  }

  /// 번역 응답을 기다리는 상한. 넘기면 받지 못한 것으로 본다(두 앱 공통 40초).
  static let defaultTimeout: Duration = .seconds(40)

  private(set) var sessions: [ReviewTarget: ItemRetranslationSession] = [:]
  private(set) var restores: [ReviewTarget: Restore] = [:]
  @ObservationIgnored let translate: Translate?
  @ObservationIgnored let timeout: Duration
  /// 지금 품목 계획(앱 모델의 화면 값).
  @ObservationIgnored var plan: (ReviewTarget) -> ItemPlan? = { _ in nil }
  /// 결과를 남길 처리기(그 영수증의 초안).
  @ObservationIgnored var processor: (ReviewTarget) -> ReceiptProcessor? = { _ in nil }
  /// "이 이름 사용": 스냅샷이 지금 줄과 같으면 계획에 쓰고, 기기에 남았는지 알려 준다.
  @ObservationIgnored var applyName: (ReviewTarget, ItemPlanLine, String) async -> ApplyOutcome = { _, _, _ in
    .rejected
  }
  @ObservationIgnored private var revision = 0

  init(translate: Translate?, timeout: Duration = ItemRetranslationModel.defaultTimeout) {
    self.translate = translate
    self.timeout = timeout
  }

  /// 새 재번역을 시작할 수 있는지(번역기가 있고, 그 영수증의 기록을 다 읽었고, 열린 재번역이 없다).
  func canBegin(_ target: ReviewTarget) -> Bool {
    translate != nil && restores[target] == .done && sessions[target] == nil
  }

  /// 시트를 연다(동의 단계).
  func begin(_ target: ReviewTarget, lines: [ItemPlanLine]) {
    guard canBegin(target), !lines.isEmpty else { return }
    sessions[target] = ItemRetranslationSession(candidates: lines)
  }

  func toggle(_ target: ReviewTarget, _ lineID: String) {
    guard var session = sessions[target], session.isBatch, session.phase == .consent else { return }
    if session.selection.contains(lineID) {
      session.selection.remove(lineID)
    } else if session.selection.count < ItemRetranslationSession.maximumSelection {
      session.selection.insert(lineID)
    }
    sessions[target] = session
  }

  /// 사용자가 동의한 줄만 보낸다. 보내기 전에 보낸다는 기록을 먼저 남기고(못 남기면 보내지 않는다), 남긴 뒤 줄을 다시
  /// 확인한다. 응답은 상한(`timeout`) 안에 와야 하고, 오지 않거나 실패·취소되면 받지 못한 것으로 본다. 받은 결과는 기록에
  /// 쓰는 동안 저장 중으로 두어 적용·닫기를 막는다.
  func confirm(_ target: ReviewTarget) {
    guard var session = sessions[target], session.phase == .consent, !session.saving else { return }
    let lines = session.selectedLines
    guard !lines.isEmpty else { return }
    guard matchesPlan(target, lines) else {
      session.phase = .changed
      sessions[target] = session
      return
    }
    guard let translate else {
      session.phase = .unavailable
      sessions[target] = session
      return
    }
    let request = UUID()
    session.request = request
    session.requested = lines
    session.suggestions = [:]
    session.accepted = [:]
    session.failure = nil
    session.phase = .requesting
    sessions[target] = session
    let id = session.id
    let pending = ItemRetranslationRecord(state: .requested, batch: session.isBatch, requested: lines)
    let timeout = timeout
    Task {
      let marked = await write(target, pending)
      guard var current = requesting(target, id, request) else { return }
      guard marked else {
        current.request = nil
        current.phase = .consent
        current.failure = .marker
        sessions[target] = current
        return
      }
      current.ownsRecord = true
      guard matchesPlan(target, lines) else {
        // 기록을 쓰는 동안 줄이 바뀌었다. 보내지 않는다.
        current.request = nil
        current.phase = .changed
        let operation = current.startOperation()
        sessions[target] = current
        await clear(target, id, operation, ending: false)
        return
      }
      sessions[target] = current
      let names = await Self.limited(timeout) { try await translate(lines.map(\.originalName)) }
      guard var answered = requesting(target, id, request) else { return }
      answered.request = nil
      if let names, names.count == lines.count {
        answered.suggestions = Dictionary(
          uniqueKeysWithValues: zip(lines, names).compactMap { line, name in
            guard let name, !name.isEmpty else { return nil }
            return (line.id, name)
          })
        answered.phase = answered.isBatch || !answered.suggestions.isEmpty ? .results : .unavailable
      } else {
        answered.phase = .unavailable
      }
      let operation = answered.startOperation()
      sessions[target] = answered
      if answered.phase == .results {
        await saveRecord(target, id, operation)
      } else {
        await clear(target, id, operation, ending: false)
      }
    }
  }

  /// 실패 안내에서 다시 동의 단계로 돌아간다(보내지 않는다). 저장 실패가 남아 있으면 그 일을 먼저 다시 한다.
  func retry(_ target: ReviewTarget) {
    guard var session = sessions[target], session.phase == .unavailable, !session.saving, session.failure == nil
    else { return }
    session.phase = .consent
    session.failure = nil
    sessions[target] = session
  }

  /// "이 이름 사용"을 누른 줄만 적용한다. 품목 계획이 기기에 남은 것을 확인한 뒤에만 기록을 바꾸거나 지운다. 계획을 쓰지
  /// 못하면 제안을 그대로 두고 ‘다시 저장’으로 다시 적용한다. 스냅샷이 달라 적용하지 않으면 그 줄에 변경 안내를 두고
  /// 결과를 남긴다(‘닫기’ 전까지).
  func accept(_ target: ReviewTarget, _ line: ItemPlanLine, _ name: String) {
    guard var session = sessions[target], session.phase == .results, !session.saving,
      session.suggestions[line.id] == name, session.accepted[line.id] == nil,
      session.requested.contains(line)
    else { return }
    let operation = session.startOperation()
    sessions[target] = session
    let id = session.id
    Task { await apply(target, id, operation, line, name) }
  }

  /// 실패한 저장을 그 종류대로 다시 한다(결과 쓰기, 적용, 지우기).
  func retrySave(_ target: ReviewTarget) {
    guard var session = sessions[target], !session.saving, let failure = session.failure, failure != .marker else {
      return
    }
    let operation = session.startOperation()
    sessions[target] = session
    let id = session.id
    Task {
      switch failure {
      case .save:
        await saveRecord(target, id, operation)
      case .apply(let lineID, let name):
        guard let line = sessions[target]?.requested.first(where: { $0.id == lineID }) else { return }
        await apply(target, id, operation, line, name)
      case .clear(let ending):
        await clear(target, id, operation, ending: ending)
      case .marker:
        break
      }
    }
  }

  /// ‘닫기’. 요청 중이나 저장 중에는 쓸 수 없다. 이 세션의 기록을 지운 뒤 닫고, 지우지 못하면 시트를 두고 안내를 보인다.
  func close(_ target: ReviewTarget) {
    guard var session = sessions[target], session.canClose else { return }
    let operation = session.startOperation()
    sessions[target] = session
    let id = session.id
    Task { await clear(target, id, operation, ending: true) }
  }

  /// 시트가 ‘닫기’가 아닌 길로 닫혔다(그 시트가 그리던 세션 `sessionID`). 요청 중·결과·저장 중·삭제 실패가 남은 때는 아래로
  /// 쓸기를 막았으므로 화면이 빠진 것이다. 그대로 둔다. 동의·줄 선택·실패·변경 안내는 쉽게 닫히므로 끝내고 이 세션의 기록을
  /// 지운다. 닫힌 시트는 다시 띄우지 않는다. 지우지 못하면 파일이 남아 다음에 품목 화면에 들어올 때 다시 보인다.
  func dismissed(_ target: ReviewTarget, _ sessionID: UUID) {
    guard let session = sessions[target], session.id == sessionID, !session.blocksDismissal else { return }
    sessions[target] = nil
    guard session.ownsRecord else { return }
    Task { _ = await write(target, nil) }
  }

  /// 품목 화면에 들어올 때 부른다(영수증마다 한 번 끝까지 읽는다). 받은 결과는 결과 단계로, 기다리던 요청과 풀 수 없는
  /// (손상된) 기록은 실패 안내(다시 시도)로 보인다. 원문이 바뀌었으면 버린다. 계획에 이미 적용된 줄(계획은 남고 기록 정리 전에 끝났다)은 적용함으로 정리한다.
  /// 읽지 못하면 파일을 그대로 두고 `failed`로 둬 다시 읽을 수 있다.
  func restore(_ target: ReviewTarget) async {
    guard sessions[target] == nil, restores[target] != .restoring, restores[target] != .done,
      let processor = processor(target), plan(target) != nil
    else { return }
    restores[target] = .restoring
    let stored: ItemRetranslationRecord?
    do {
      stored = try await processor.itemRetranslation(target.itemID)
    } catch ProcessorError.itemRetranslationInvalid {
      // 풀 수 없는 기록은 받지 못한 것과 같다(Android와 같다). 파일은 이 세션이 가지고, ‘닫기’로 지우거나 ‘다시 시도’ 뒤
      // 새 요청 표시가 덮을 때까지 남긴다. 고를 수 있는 줄은 지금 계획의 다시 번역할 수 있는 줄 전체다.
      guard let current = plan(target) else {
        restores[target] = .failed
        return
      }
      var session = ItemRetranslationSession(candidates: current.retranslatableLines)
      session.phase = .unavailable
      session.ownsRecord = true
      restores[target] = .done
      sessions[target] = session
      return
    } catch {
      restores[target] = .failed
      return
    }
    guard let stored else {
      restores[target] = .done
      return
    }
    guard let current = plan(target), stored.matches(current) else {
      // 원문이 바뀌어 쓸 수 없는 결과다. 지우지 못하면 다음에 들어올 때 다시 버린다.
      _ = await write(target, nil)
      restores[target] = .done
      return
    }
    var session = ItemRetranslationSession(
      candidates: stored.batch ? current.retranslatableLines : stored.requested, isBatch: stored.batch)
    session.selection = Set(stored.requested.map(\.id))
    session.requested = stored.requested
    session.suggestions = stored.suggestions
    session.accepted = stored.accepted
    session.phase = stored.state == .received ? .results : .unavailable
    session.ownsRecord = true
    var reconciled = false
    if session.phase == .results {
      for line in stored.requested where stored.accepted[line.id] == nil {
        guard let name = stored.suggestions[line.id], current.line(line.id) == line.applyingRetranslation(name)
        else { continue }
        session.accepted[line.id] = true
        reconciled = true
      }
    }
    restores[target] = .done
    guard reconciled else {
      sessions[target] = session
      return
    }
    let operation = session.startOperation()
    sessions[target] = session
    if session.isFinished {
      await clear(target, session.id, operation, ending: true)
    } else {
      await saveRecord(target, session.id, operation)
    }
  }

  // MARK: - 완료

  private func apply(_ target: ReviewTarget, _ id: UUID, _ operation: UUID, _ line: ItemPlanLine, _ name: String)
    async
  {
    let outcome = await applyName(target, line, name)
    guard var session = live(target, id, operation) else { return }
    switch outcome {
    case .saveFailed:
      session.endOperation(.apply(lineID: line.id, name: name))
      sessions[target] = session
      return
    case .rejected:
      session.accepted[line.id] = false
    case .applied:
      session.accepted[line.id] = true
    }
    sessions[target] = session
    if session.isFinished {
      await clear(target, id, operation, ending: true)
    } else {
      await saveRecord(target, id, operation)
    }
  }

  private func saveRecord(_ target: ReviewTarget, _ id: UUID, _ operation: UUID) async {
    guard let record = live(target, id, operation)?.record else { return }
    let ok = await write(target, record)
    guard var session = live(target, id, operation) else { return }
    session.endOperation(ok ? nil : .save)
    sessions[target] = session
  }

  /// 이 세션의 기록을 지운다. `ending`이면 지운 뒤 세션을 끝낸다. 세션이 기록을 만들지 않았으면 파일을 건드리지 않는다.
  private func clear(_ target: ReviewTarget, _ id: UUID, _ operation: UUID, ending: Bool) async {
    guard let owned = live(target, id, operation)?.ownsRecord else { return }
    let ok = owned ? await write(target, nil) : true
    guard var session = live(target, id, operation) else { return }
    if ok, ending {
      sessions[target] = nil
      return
    }
    if ok { session.ownsRecord = false }
    session.endOperation(ok ? nil : .clear(ending: ending))
    sessions[target] = session
  }

  private func live(_ target: ReviewTarget, _ id: UUID, _ operation: UUID) -> ItemRetranslationSession? {
    guard let session = sessions[target], session.id == id, session.operation == operation else { return nil }
    return session
  }

  private func requesting(_ target: ReviewTarget, _ id: UUID, _ request: UUID) -> ItemRetranslationSession? {
    guard let session = sessions[target], session.id == id, session.request == request,
      session.phase == .requesting
    else { return nil }
    return session
  }

  private func matchesPlan(_ target: ReviewTarget, _ lines: [ItemPlanLine]) -> Bool {
    let current = plan(target)
    return lines.allSatisfy { current?.line($0.id) == $0 }
  }

  /// 기록을 쓴다(`nil`이면 지운다). 순번을 붙여 늦게 도착한 옛 저장이 새 저장을 덮지 않게 한다.
  private func write(_ target: ReviewTarget, _ record: ItemRetranslationRecord?) async -> Bool {
    guard let processor = processor(target) else { return false }
    revision += 1
    let revision = revision
    do {
      try await processor.saveItemRetranslation(target.itemID, record, revision: revision)
      return true
    } catch {
      return false
    }
  }

  /// 번역을 상한 안에서 기다린다. 넘기거나 실패·취소되면 nil(받지 못함). 넘기면 번역 작업을 취소한다. 번역 작업이 취소를
  /// 따르지 않아도 상한에서 돌아온다.
  nonisolated static func limited(_ limit: Duration, _ work: @escaping @Sendable () async throws -> [String?]) async
    -> [String?]?
  {
    await withCheckedContinuation { continuation in
      let once = Once(continuation)
      let task = Task {
        let names = try? await work()
        once.finish(names)
      }
      let timer = Task {
        try? await Task.sleep(for: limit)
        task.cancel()
        once.finish(nil)
      }
      once.onFinish { timer.cancel() }
    }
  }

  private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String?]?, Never>?
    private var finished = false
    private var cleanup: (@Sendable () -> Void)?

    init(_ continuation: CheckedContinuation<[String?]?, Never>) { self.continuation = continuation }

    func finish(_ value: [String?]?) {
      let (continuation, cleanup) = lock.withLock {
        defer {
          self.continuation = nil
          self.cleanup = nil
          finished = true
        }
        return (self.continuation, self.cleanup)
      }
      continuation?.resume(returning: value)
      cleanup?()
    }

    /// 끝나면 부를 정리. 이미 끝났으면 바로 부른다.
    func onFinish(_ action: @escaping @Sendable () -> Void) {
      let now = lock.withLock {
        if finished { return true }
        cleanup = action
        return false
      }
      if now { action() }
    }
  }
}
