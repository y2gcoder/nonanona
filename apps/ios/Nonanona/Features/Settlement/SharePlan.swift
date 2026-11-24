import Foundation

/// 방장이 고르는 부담 방식. 서버에는 어느 방식이든 원 단위 몫만 간다.
enum ShareMode: String, CaseIterable, Hashable, Sendable {
  /// 한 사람이 전부 부담한다.
  case one
  /// 두 사람이 똑같이 나눈다. 홀수 금액이면 결제자가 남는 1원을 더 부담한다(결제자가 두 사람 중 하나일 때만).
  case even
  /// 사람마다 원 단위 몫을 직접 적는다(남는 원이 생길 때).
  case exact
}

/// 몫 계산. 원 단위 정수만 쓰고 몫의 합은 언제나 원화와 같다. 환율 환산·반올림은 하지 않는다(ADR-0001).
enum SharePlan {
  /// 두 사람 균등 몫(ADR-0007). `payerIndex`는 두 사람 중 결제자의 자리(0·1), 결제자가 두 사람 밖이면 nil.
  /// 짝수 금액은 똑같이 나눈다. 홀수 금액은 결제자가 floor(원화/2)+1, 다른 사람이 floor(원화/2)를 부담한다.
  /// 결제자가 두 사람 밖인 홀수 금액은 남는 1원을 받을 사람이 없어 nil(직접 나눈다). 한 사람 몫이 0원이 되는 1원도
  /// nil이다(서버는 0원 몫을 받지 않는다 — 한 사람 부담으로 정한다).
  static func pairSplit(krw: Int, payerIndex: Int?) -> [Int]? {
    guard krw >= 2 else { return nil }
    let half = krw / 2
    if krw % 2 == 0 { return [half, half] }
    switch payerIndex {
    case 0: return [half + 1, half]
    case 1: return [half, half + 1]
    default: return nil
    }
  }

  /// 원 단위 정수 입력. 전각 등 유니코드 숫자와 자릿수 쉼표·공백을 받고, 그 밖의 글자가 있으면 nil.
  static func parseWon(_ text: String) -> Int? {
    var digits = ""
    for ch in text {
      if ch == "," || ch == " " || ch == "，" { continue }
      guard let v = ch.wholeNumberValue, ch.isNumber else { return nil }
      digits.append(String(v))
    }
    guard !digits.isEmpty, digits.count <= 11, let value = Int(digits), value > 0 else { return nil }
    return value
  }
}

enum ShareProblem: Error, Equatable, Sendable {
  case payerMissing
  case krwMissing
  case personMissing
  case pairRequired
  /// 홀수 금액인데 결제자가 두 사람 밖이라 남는 1원을 줄 사람이 없다. 직접 나눠야 한다.
  case notDivisible
  /// 1원은 두 사람이 나눌 수 없다(한 사람 몫이 0원). 한 사람 부담으로 정해야 한다.
  case tooSmallToSplit
  case exactInvalid
  /// 직접 적은 몫의 합이 원화와 다르다(양수면 아직 남은 금액).
  case exactMismatch(remaining: Int)
}

/// 방장의 검토 입력. 화면 배치가 바뀌어도 남도록 모델에 둔다.
struct ShareForm: Equatable, Sendable {
  /// 이 입력을 연 지출 버전. 보낼 때 이 버전을 기대 버전으로 쓴다(그사이 바뀌었으면 서버가 거절한다).
  let baseVersion: Int
  var payer: MemberID?
  /// 외화 지출의 실제 원화 청구액(글자 그대로).
  var verifiedKRWText = ""
  var mode: ShareMode = .even
  var one: MemberID?
  var pair: Set<MemberID> = []
  var exact: [MemberID: String] = [:]

  /// 처음 열 때: 이미 포함한 지출이면 그 값, 아니면 결제자 미정·두 사람(목록 앞 두 명) 반씩.
  /// 저장된 두 사람 몫이 반씩 규칙과 같을 때만 "둘이 반씩"으로 열고, 그 밖의 몫(예전에 직접 적은 홀수 몫 포함)은
  /// "직접 나누기"로 그대로 연다.
  init(expense: LedgerExpense, members: [LedgerMember]) {
    baseVersion = expense.version
    payer = expense.payer
    if expense.currency != "KRW", let krw = expense.krwAmount { verifiedKRWText = String(krw) }
    pair = Set(members.prefix(2).map(\.id))
    one = expense.payer
    if !expense.shares.isEmpty {
      if expense.shares.count == 1 {
        mode = .one
        one = expense.shares[0].member
      } else if expense.shares.count == 2, Self.isPairSplit(expense.shares, payer: expense.payer, members: members) {
        mode = .even
        pair = Set(expense.shares.map(\.member))
      } else {
        mode = .exact
      }
      exact = Dictionary(uniqueKeysWithValues: expense.shares.map { ($0.member, String($0.krw)) })
    }
  }

  private static func isPairSplit(_ shares: [ShareLine], payer: MemberID?, members: [LedgerMember]) -> Bool {
    let people = members.map(\.id).filter { id in shares.contains { $0.member == id } }
    guard people.count == 2 else { return false }
    let stored = people.compactMap { id in shares.first { $0.member == id }?.krw }
    return SharePlan.pairSplit(krw: stored[0] + stored[1], payerIndex: payer.flatMap(people.firstIndex(of:))) == stored
  }

  /// 정산에 쓸 원화. KRW 지출은 원래 금액, 외화는 확인한 청구액(없으면 nil — 보류하거나 확인 필요로 둔다).
  func krw(for expense: LedgerExpense) -> Int? {
    expense.currency == "KRW" ? expense.amountMinor : SharePlan.parseWon(verifiedKRWText)
  }

  func shares(for expense: LedgerExpense, members: [LedgerMember]) -> Result<[ShareLine], ShareProblem> {
    guard payer != nil else { return .failure(.payerMissing) }
    guard let krw = krw(for: expense) else { return .failure(.krwMissing) }
    switch mode {
    case .one:
      guard let one else { return .failure(.personMissing) }
      return .success([ShareLine(member: one, krw: krw)])
    case .even:
      let people = members.map(\.id).filter(pair.contains)
      guard people.count == 2 else { return .failure(.pairRequired) }
      guard krw >= 2 else { return .failure(.tooSmallToSplit) }
      let payerIndex = payer.flatMap(people.firstIndex(of:))
      guard let split = SharePlan.pairSplit(krw: krw, payerIndex: payerIndex) else { return .failure(.notDivisible) }
      return .success(zip(people, split).map { ShareLine(member: $0, krw: $1) })
    case .exact:
      var lines: [ShareLine] = []
      for member in members {
        let text = exact[member.id, default: ""].trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text == "0" { continue }
        guard let value = SharePlan.parseWon(text) else { return .failure(.exactInvalid) }
        lines.append(ShareLine(member: member.id, krw: value))
      }
      guard !lines.isEmpty else { return .failure(.exactInvalid) }
      let total = lines.reduce(0) { $0 + $1.krw }
      guard total == krw else { return .failure(.exactMismatch(remaining: krw - total)) }
      return .success(lines)
    }
  }
}
