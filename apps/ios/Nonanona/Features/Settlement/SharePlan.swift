import Foundation

/// 방장이 고르는 부담 방식. 서버에는 어느 방식이든 원 단위 몫만 간다.
enum ShareMode: String, CaseIterable, Hashable, Sendable {
  /// 한 사람이 전부 부담한다.
  case one
  /// 두 사람이 똑같이 나눈다. 정확히 나누어떨어질 때만 쓸 수 있다.
  case even
  /// 사람마다 원 단위 몫을 직접 적는다(남는 원이 생길 때).
  case exact
}

/// 몫 계산. 반올림하거나 남는 원을 누구에게 줄지 고르지 않는다(규칙 미정, ADR-0001). 나누어떨어지지 않으면 nil이다.
enum SharePlan {
  static func evenSplit(krw: Int, people: Int) -> [Int]? {
    guard krw > 0, people > 0, krw % people == 0 else { return nil }
    return Array(repeating: krw / people, count: people)
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
  /// 반으로 나누면 원이 남는다. 직접 나눠야 한다.
  case notDivisible
  case exactInvalid
  /// 직접 적은 몫의 합이 원화와 다르다(양수면 아직 남은 금액).
  case exactMismatch(remaining: Int)
}

/// 방장의 검토 입력. 화면 배치가 바뀌어도 남도록 모델에 둔다.
struct ShareForm: Equatable, Sendable {
  var payer: MemberID?
  /// 외화 지출의 실제 원화 청구액(글자 그대로).
  var verifiedKRWText = ""
  var mode: ShareMode = .even
  var one: MemberID?
  var pair: Set<MemberID> = []
  var exact: [MemberID: String] = [:]

  /// 처음 열 때: 이미 포함한 지출이면 그 값, 아니면 결제자 미정·두 사람(목록 앞 두 명) 반씩.
  init(expense: LedgerExpense, members: [LedgerMember]) {
    payer = expense.payer
    if expense.currency != "KRW", let krw = expense.krwAmount { verifiedKRWText = String(krw) }
    pair = Set(members.prefix(2).map(\.id))
    one = expense.payer
    if !expense.shares.isEmpty {
      if expense.shares.count == 1 {
        mode = .one
        one = expense.shares[0].member
      } else if expense.shares.count == 2, expense.shares[0].krw == expense.shares[1].krw {
        mode = .even
        pair = Set(expense.shares.map(\.member))
      } else {
        mode = .exact
      }
      exact = Dictionary(uniqueKeysWithValues: expense.shares.map { ($0.member, String($0.krw)) })
    }
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
      guard let each = SharePlan.evenSplit(krw: krw, people: 2) else { return .failure(.notDivisible) }
      return .success(zip(people, each).map { ShareLine(member: $0, krw: $1) })
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
