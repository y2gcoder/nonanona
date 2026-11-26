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

/// 외화(엔) 지출의 원화를 어디서 가져올지. 고르는 순서가 ADR-0001의 우선순위다.
enum KRWSource: String, CaseIterable, Hashable, Sendable {
  /// 카드·계좌에 찍힌 실제 원화 청구액(우선순위 1).
  case actual
  /// 증빙으로 확인한 환전 원가(우선순위 2, 엔화만).
  case acquisition
  /// 한국은행 기준환율 예상액(우선순위 3, 엔화만, 서버 고시값).
  case estimate
}

/// 몫 계산. 원 단위 정수만 쓰고 몫의 합은 언제나 원화와 같다. 엔화 환산은 정확한 정수 계산 뒤 원 단위로
/// 반올림한다(양수 .5는 올림, ADR-0008). 서버도 같은 계산으로 다시 확인한다.
enum SharePlan {
  /// 1,000억 원 미만만(서버의 원화 한도).
  static let maxKRW = 100_000_000_000

  /// floor(n/d + 1/2) = (2n + d) / (2d), n ≥ 0, d > 0. 넘치면 nil.
  static func halfUpDivide(_ n: Int, _ d: Int) -> Int? {
    guard n >= 0, d > 0 else { return nil }
    let (twice, o1) = n.multipliedReportingOverflow(by: 2)
    let (num, o2) = twice.addingReportingOverflow(d)
    let (den, o3) = d.multipliedReportingOverflow(by: 2)
    guard !o1, !o2, !o3 else { return nil }
    return num / den
  }

  /// 환전 원가로 본 원화: 엔 × 환전에 쓴 원화 ÷ 받은 엔. 0원이 되거나 한도를 넘으면 nil(쓸 수 없다).
  static func acquisitionKRW(amountMinor: Int, krwPaid: Int, foreignMinor: Int) -> Int? {
    guard amountMinor > 0, amountMinor < 100_000_000, krwPaid > 0, krwPaid < 10_000_000_000,
      foreignMinor > 0, foreignMinor < 1_000_000_000
    else { return nil }
    let (n, overflow) = amountMinor.multipliedReportingOverflow(by: krwPaid)
    guard !overflow, let krw = halfUpDivide(n, foreignMinor), krw >= 1, krw < maxKRW else { return nil }
    return krw
  }

  /// 고시 글자("905.25")를 소수 넷째 자리까지의 정수(9052500)로. 형식이 다르면 nil.
  static func scaledRate(_ text: String) -> Int? {
    guard text.range(of: #"^(0|[1-9][0-9]{0,5})(\.[0-9]{1,4})?$"#, options: .regularExpression) != nil else {
      return nil
    }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    let frac = parts.count == 2 ? String(parts[1]) : ""
    guard let whole = Int(parts[0]), let fraction = Int(frac.padding(toLength: 4, withPad: "0", startingAt: 0)) else {
      return nil
    }
    let scaled = whole * 10_000 + fraction
    return scaled > 0 ? scaled : nil
  }

  /// 기준환율 예상액: 엔 × 고시값 ÷ 단위. 0원이 되거나 한도를 넘으면 nil.
  static func referenceKRW(amountMinor: Int, rate: String, quoteUnit: Int) -> Int? {
    guard amountMinor > 0, amountMinor < 100_000_000, quoteUnit > 0, let scaled = scaledRate(rate) else { return nil }
    let (n, o1) = amountMinor.multipliedReportingOverflow(by: scaled)
    let (d, o2) = quoteUnit.multipliedReportingOverflow(by: 10_000)
    guard !o1, !o2, let krw = halfUpDivide(n, d), krw >= 1, krw < maxKRW else { return nil }
    return krw
  }

  /// 서버 제안을 쓸 수 있는가: 고시값이 있고, 앱이 따로 계산한 원화가 서버 원화와 같을 때만(아니면 쓰지 않는다).
  static func usableEstimate(_ proposal: FXProposal?, amountMinor: Int) -> (quote: ReferenceQuote, krw: Int)? {
    guard case .proposed(let quote, let krw) = proposal,
      referenceKRW(amountMinor: amountMinor, rate: quote.rate, quoteUnit: quote.quoteUnit) == krw
    else { return nil }
    return (quote, krw)
  }

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
  /// 환전 원가 입력이 없거나 숫자가 아니거나, 계산한 원화가 0원·한도 밖이다.
  case acquisitionInvalid
  /// 쓸 수 있는 기준환율 고시값이 없다(아직 확인 못 함·고시 없음). 보류하거나 다른 기준을 고른다.
  case estimateUnavailable
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
  /// 외화 지출의 원화를 어디서 가져올지(엔화만 셋 중에서 고른다. 다른 외화는 실제 청구액뿐).
  var krwSource: KRWSource = .actual
  /// 외화 지출의 실제 원화 청구액(글자 그대로).
  var verifiedKRWText = ""
  /// 환전 원가: 환전에 쓴 원화와 받은 엔(글자 그대로).
  var acquisitionKRWText = ""
  var acquisitionForeignText = ""
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
    switch expense.krwBasis {
    case .acquisitionCost:
      krwSource = .acquisition
      if let a = expense.acquisition {
        acquisitionKRWText = String(a.krwPaid)
        acquisitionForeignText = String(a.foreignMinor)
      }
    case .referenceEstimate:
      // 예상액은 실제 청구액 칸에 옮기지 않는다(예상을 실제처럼 보이지 않게).
      krwSource = .estimate
    case .krwOriginal, .verifiedCharge, nil:
      if expense.currency != "KRW", let krw = expense.krwAmount { verifiedKRWText = String(krw) }
    }
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

  /// 이 지출에서 고를 수 있는 원화 기준. 엔화만 환전 원가·기준환율 예상을 쓸 수 있다.
  static func sources(for expense: LedgerExpense) -> [KRWSource] {
    expense.currency == "JPY" ? KRWSource.allCases : expense.currency == "KRW" ? [] : [.actual]
  }

  /// 지금 고른 기준(이 지출에서 쓸 수 없는 기준이면 실제 청구액).
  func source(for expense: LedgerExpense) -> KRWSource {
    Self.sources(for: expense).contains(krwSource) ? krwSource : .actual
  }

  /// 환전 원가 입력(둘 다 원 단위·엔 단위 정수일 때만).
  var acquisitionInput: AcquisitionBasis? {
    guard let paid = SharePlan.parseWon(acquisitionKRWText), let foreign = SharePlan.parseWon(acquisitionForeignText)
    else {
      return nil
    }
    return AcquisitionBasis(krwPaid: paid, foreignMinor: foreign)
  }

  /// 정산에 쓸 원화. KRW 지출은 원래 금액, 외화는 고른 기준의 원화(없으면 nil — 보류하거나 확인 필요로 둔다).
  func krw(for expense: LedgerExpense) -> Int? {
    if expense.currency == "KRW" { return expense.amountMinor }
    switch source(for: expense) {
    case .actual: return SharePlan.parseWon(verifiedKRWText)
    case .acquisition:
      return acquisitionInput.flatMap {
        SharePlan.acquisitionKRW(amountMinor: expense.amountMinor, krwPaid: $0.krwPaid, foreignMinor: $0.foreignMinor)
      }
    case .estimate: return SharePlan.usableEstimate(expense.fxProposal, amountMinor: expense.amountMinor)?.krw
    }
  }

  /// 실제 청구액이 아닌 원화의 근거(서버에 함께 보낸다). KRW 지출과 실제 청구액은 nil.
  func conversion(for expense: LedgerExpense) -> KRWConversion? {
    guard expense.currency != "KRW" else { return nil }
    switch source(for: expense) {
    case .actual: return nil
    case .acquisition: return acquisitionInput.map { .acquisitionCost($0) }
    case .estimate:
      return SharePlan.usableEstimate(expense.fxProposal, amountMinor: expense.amountMinor).map {
        .referenceEstimate(quoteID: $0.quote.quoteID)
      }
    }
  }

  func shares(for expense: LedgerExpense, members: [LedgerMember]) -> Result<[ShareLine], ShareProblem> {
    guard payer != nil else { return .failure(.payerMissing) }
    guard let krw = krw(for: expense) else {
      switch expense.currency == "KRW" ? .actual : source(for: expense) {
      case .actual: return .failure(.krwMissing)
      case .acquisition: return .failure(.acquisitionInvalid)
      case .estimate: return .failure(.estimateUnavailable)
      }
    }
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
