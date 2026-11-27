import Foundation

// 영수증 품목 후보와 품목별 나누기 계획(기기 안). OCR 줄 글자·품목 이름을 담으므로 여기 타입은 기기 밖으로 나가지 않는다.
// 규칙은 Android `ReceiptItems.kt`와 같고, 공통 예제(apps/fixtures/items/examples.json)로 두 앱이 같은 답을 내는지 본다.

/// 품목 후보를 그대로 믿기 어려운 이유. 하나라도 있으면 사용자가 "확인함"을 누르거나 값을 고쳐야 나눌 수 있다.
public enum ItemFlag: String, Codable, Sendable, CaseIterable {
  /// 금액만 있고 품목 이름으로 읽을 글자가 없다.
  case nameMissing
  /// 금액 표시(¥·円)는 있지만 숫자를 읽지 못했다(자릿수 쉼표가 어긋나거나 글자가 섞임).
  case amountUnreadable
  /// 수량 표시(2個, ×2, @300 등)가 있다. 금액이 한 개 값인지 줄 합계인지 확인해야 한다.
  case quantity
  /// 금액이 영수증 합계보다 크다.
  case exceedsTotal
  /// 둘 이상의 행에서 가져올 수 있거나 위치가 어긋난 금액이다.
  case amountLinkUncertain
}

/// 품목이 아닌 영수증 요약 줄. 나누기에 자동으로 넣지 않고 보여 주기만 한다.
public enum SummaryKind: String, Codable, Sendable {
  case subtotal
  case tax
  case total
  case payment
  case discount
}

public struct ItemSummaryLine: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let kind: SummaryKind
  public let sourceLineIDs: [Int]
  public let originalText: String
  public let amountMinor: Int?
}

public struct ItemCandidate: Codable, Equatable, Identifiable, Sendable {
  /// 안정 ID: 그 행의 가장 작은 OCR 줄 ID(`ocr-3`). 같은 제안에서 언제나 같다.
  public let id: String
  public let sourceLineIDs: [Int]
  /// 행 글자 그대로(여러 OCR 상자면 왼쪽부터 공백으로 잇는다).
  public let originalText: String
  /// 금액 앞의 이름 부분(번역 입력). 없으면 빈 글자.
  public let originalName: String
  public let amountMinor: Int?
  public let flags: [ItemFlag]
}

public struct ItemExtraction: Codable, Equatable, Sendable {
  public let candidates: [ItemCandidate]
  public let summary: [ItemSummaryLine]
  /// OCR이 읽은 첫 합계 줄의 금액(없으면 nil).
  public let ocrTotalMinor: Int?
}

/// OCR 위치(행)와 글자로 품목 후보를 보수적으로 뽑는다. 확실하지 않으면 품목으로 만들지 않거나 표시(`ItemFlag`)를 붙인다.
public enum ItemExtractor {
  public static let version = "receipt-items-v2"

  static let sensitive = ProposalBuilder.sensitivePattern
  static let discount = #"値引|割引|クーポン|discount"#
  static let subtotal = #"小計|subtotal"#
  static let total = #"合計|お会計|総計|total"#
  static let tax = #"消費税|内税|外税|税額|税等|[0-9]+%対象|tax"#
  static let payment = #"お預り|お預かり|預り|お釣|釣銭|おつり|現金|クレジット|支払|ポイント|電子マネー|交通系|残高"#
  /// 행 끝의 가격: [부호] [¥] 숫자 [円] [세금 표시] [닫는 괄호].
  static let price = #"^(.*?)[\s:：]*(-|▲|△)?\s*(¥)?\s*([0-9][0-9,.]*)\s*(円)?\s*(?:※|\*|軽|外|内)?\s*[)）]?$"#
  static let quantity = #"[0-9]+\s*(?:個|点|本|杯|枚|皿|人前|コ)|[x×X]\s*[0-9]+|@\s*[0-9]+"#
  static let number = #"[0-9][0-9,.]*"#
  static let priceBox = #"^[¥]?\s*[0-9][0-9,.]*\s*円?$"#

  static let priceSuffixBox = #"^(?:[※*軽外内]\s*\)?|\))$"#

  struct Row {
    let lineIDs: [Int]
    let text: String
    /// 가격 열이 따로 읽혔다. 오른쪽 끝의 별도 세금 표시는 건너뛴다.
    let separatePriceBox: Bool
    let uncertainLink: Bool
  }

  static func rows(_ ocr: OCRResult) -> [Row] {
    let (boxes, corrected) = ItemRowGeometry.boxes(ocr)
    let sorted = boxes.sorted { ($0.centerY, $0.line.id) < ($1.centerY, $1.line.id) }
    var groups: [[ItemRowGeometry.Box]] = []
    for box in sorted {
      if let anchor = groups.last?.first,
        box.centerY - anchor.centerY < (corrected ? max(box.height, anchor.height) : anchor.height) / 2
      {
        groups[groups.count - 1].append(box)
      } else {
        groups.append([box])
      }
    }
    return groups.map { group in
      let ordered = group.sorted { ($0.line.x, $0.line.id) < ($1.line.x, $1.line.id) }
      let lines = ordered.map(\.line)
      let amountIndex = ordered.lastIndex { !matches(priceSuffixBox, normalize($0.line.text)) }
      let amountText = amountIndex.map { normalize(ordered[$0].line.text) } ?? ""
      let separate = (amountIndex ?? 0) > 0 && matches(priceBox, amountText)
      let uncertain =
        if let amountIndex, amountIndex > 0, isAmountBox(amountText) {
          uncertainLink(
            amount: ordered[amountIndex], row: ordered[..<amountIndex], boxes: sorted, corrected: corrected)
        } else {
          false
        }
      return Row(
        lineIDs: lines.map(\.id).sorted(),
        text: lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " "),
        separatePriceBox: separate,
        uncertainLink: uncertain)
    }
  }

  private static func isAmountBox(_ text: String) -> Bool {
    captures(price, text)?[1].isEmpty == true
  }

  private static func uncertainLink(
    amount: ItemRowGeometry.Box, row: ArraySlice<ItemRowGeometry.Box>, boxes: [ItemRowGeometry.Box], corrected: Bool
  ) -> Bool {
    func nameBox(_ box: ItemRowGeometry.Box) -> Bool {
      let text = normalize(box.line.text)
      return box.centerX < amount.centerX && matches(#"\p{L}"#, text)
        && !matches(priceSuffixBox, text) && !isAmountBox(text)
    }
    guard let name = row.first(where: nameBox) else { return false }
    let distance = amount.distance(to: name)
    if (corrected && amount.needsCorrectionToJoin(name)) || distance > 0.35 || amount.disagreesWithDirection(of: name) {
      return true
    }
    if row.contains(where: { isAmountBox(normalize($0.line.text)) }) { return true }
    return boxes.contains { box in
      let alternative = amount.distance(to: box)
      guard alternative < 0.65, alternative <= distance + 0.22, box.line.id != name.line.id else { return false }
      // 같은 묶음에 들어온 두 이름도 가로 범위가 겹치면 서로 다른 행의 후보로 본다.
      let separateRow = !row.contains(where: { $0.line.id == box.line.id })
      let overlapsName = box.line.x < name.line.x + name.line.width && name.line.x < box.line.x + box.line.width
      return (separateRow || overlapsName) && nameBox(box)
    }
  }

  public static func extract(_ ocr: OCRResult, receiptTotal: Int) -> ItemExtraction {
    var candidates: [ItemCandidate] = []
    var summary: [ItemSummaryLine] = []
    var afterSummary = false
    for row in rows(ocr) {
      let text = normalize(row.text)
      let id = "ocr-\(row.lineIDs.first ?? 0)"
      if matches(sensitive, text) || ProposalBuilder.isoDate(text) != nil { continue }
      let kind: SummaryKind? =
        if matches(discount, text) {
          .discount
        } else if matches(subtotal, text) {
          .subtotal
        } else if matches(total, text) {
          .total
        } else if matches(tax, text) {
          .tax
        } else if matches(payment, text) {
          .payment
        } else {
          nil
        }
      if let kind {
        summary.append(
          ItemSummaryLine(
            id: id, kind: kind, sourceLineIDs: row.lineIDs, originalText: row.text, amountMinor: lastAmount(text)))
        if kind == .subtotal || kind == .total { afterSummary = true }
        continue
      }
      guard !afterSummary else { continue }
      if let groups = captures(price, text) {
        let marked = !groups[3].isEmpty || !groups[5].isEmpty || row.separatePriceBox
        guard marked else { continue }
        let name = trimName(groups[1])
        let amount = groupedNumber(groups[4])
        if !groups[2].isEmpty {
          // 부호가 붙은 금액은 할인으로 보고 품목에 넣지 않는다.
          summary.append(
            ItemSummaryLine(
              id: id, kind: .discount, sourceLineIDs: row.lineIDs, originalText: row.text, amountMinor: amount))
          continue
        }
        candidates.append(
          candidate(id: id, row: row, name: name, amount: amount, receiptTotal: receiptTotal))
      } else if text.hasSuffix("円") || text.contains("¥") {
        // 가격 표시는 있는데 숫자로 읽지 못한 행.
        let name = trimName(text.components(separatedBy: "¥").first ?? text)
        let head = text.split(separator: " ").dropLast().joined(separator: " ")
        candidates.append(
          candidate(
            id: id, row: row, name: text.contains("¥") ? name : trimName(head), amount: nil,
            receiptTotal: receiptTotal))
      }
    }
    let ocrTotal = summary.first { $0.kind == .total }?.amountMinor
    return ItemExtraction(candidates: candidates, summary: summary, ocrTotalMinor: ocrTotal)
  }

  private static func candidate(id: String, row: Row, name: String, amount: Int?, receiptTotal: Int) -> ItemCandidate {
    var flags: [ItemFlag] = []
    if !matches(#"\p{L}"#, name) { flags.append(.nameMissing) }
    if amount == nil { flags.append(.amountUnreadable) }
    if matches(quantity, name) { flags.append(.quantity) }
    if let amount, amount > receiptTotal { flags.append(.exceedsTotal) }
    if row.uncertainLink { flags.append(.amountLinkUncertain) }
    return ItemCandidate(
      id: id, sourceLineIDs: row.lineIDs, originalText: row.text, originalName: name, amountMinor: amount, flags: flags)
  }

  /// 전각 숫자·기호·공백을 반각으로(NFKC). Android는 `Normalizer.Form.NFKC`.
  static func normalize(_ text: String) -> String {
    text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces)
  }

  static func trimName(_ raw: String) -> String {
    raw.trimmingCharacters(in: CharacterSet(charactersIn: " :：・.…\t"))
  }

  /// "1,280" → 1280, "980" → 980. 자릿수 구분(쉼표·마침표)이 세 자리씩이 아니면 nil.
  static func groupedNumber(_ raw: String) -> Int? {
    let parts = raw.split(omittingEmptySubsequences: false) { $0 == "," || $0 == "." }.map(String.init)
    guard let first = parts.first, !first.isEmpty, first.count <= 9 else { return nil }
    if parts.count > 1 {
      guard first.count <= 3, parts.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
    }
    let digits = parts.joined()
    guard digits.count <= 9, let value = Int(digits), value > 0 else { return nil }
    return value
  }

  static func lastAmount(_ text: String) -> Int? {
    guard let regex = try? NSRegularExpression(pattern: number) else { return nil }
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    guard let last = matches.last, let range = Range(last.range, in: text) else { return nil }
    return groupedNumber(String(text[range]))
  }

  static func matches(_ pattern: String, _ text: String) -> Bool {
    text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// 모든 묶음을 글자로(없는 묶음은 빈 글자). 0번은 전체.
  static func captures(_ pattern: String, _ text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
  }
}

// MARK: - 품목별 나누기 계획

/// 나누기 계획의 한 줄. OCR 후보(`ocr-N`) 또는 사용자가 더한 줄(`manual-N`)이다.
public struct ItemPlanLine: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable {
    /// 품목(양수 금액).
    case item
    /// 세금·수수료·할인처럼 사용자가 직접 더한 조정 줄. 할인은 음수 금액이다. 누구에게 붙일지는 사용자가 정한다.
    case adjustment
  }

  /// 한국어 이름을 어디서 얻었는지. 화면은 이 값으로 "기기 번역"·"미리보기 대역"을 따로 표시한다.
  public enum NameSource: String, Codable, Sendable {
    case none
    /// 기기 안 번역 제공자(iOS Translation, Android 기기 번역 서비스).
    case onDevice
    /// debug 미리보기 대역(정해 둔 사전). 실제 번역이 아니다.
    case preview
    case user
  }

  public let id: String
  public let kind: Kind
  public let sourceLineIDs: [Int]
  /// OCR 행 글자 그대로(사용자가 더한 줄은 빈 글자).
  public let originalText: String
  /// 번역 입력(일본어 이름). 사용자가 더한 줄은 빈 글자.
  public let originalName: String
  public var name: String
  public var nameSource: NameSource
  /// 금액 글자 그대로(고치던 값도 남는다). 영수증 통화의 최소 단위(엔·원).
  public var amountText: String
  public let flags: [ItemFlag]
  /// 표시가 있는 줄을 사용자가 확인했거나 값을 고쳤다.
  public var checked: Bool
  /// OCR 후보를 "품목 아님"으로 뺐다(ID를 지키려고 지우지 않는다).
  public var excluded: Bool
  /// 이 줄을 나눠 낼 사람(여행방 구성원 ID). 여럿이면 똑같이 나눈다(정확한 분수로 계산).
  public var assignees: [String]

  /// 재번역 제안을 "이 이름 사용"으로 적용한 직후의 줄(이름만 바뀌고 사용자가 정한 이름이 된다).
  public func applyingRetranslation(_ name: String) -> ItemPlanLine {
    var line = self
    line.name = name
    line.nameSource = .user
    return line
  }

  public var needsCheck: Bool { !flags.isEmpty && !checked }
  public var isManual: Bool { id.hasPrefix("manual-") }

  /// 금액(최소 단위). 품목은 양수, 조정은 0이 아닌 정수. 읽지 못하면 nil.
  public var amountMinor: Int? { ItemPlan.parseAmount(amountText, allowNegative: kind == .adjustment) }
}

/// 영수증 한 장의 품목별 나누기 계획. 초안 폴더 `items/<사진>.json`에만 있고, 고칠 때마다 쓴다.
public struct ItemPlan: Codable, Equatable, Sendable {
  public static let supportedCurrencies: Set<String> = ["JPY", "KRW"]

  public let extractor: String
  public let currency: String
  public let receiptTotalMinor: Int
  public let ocrTotalMinor: Int?
  public let summary: [ItemSummaryLine]
  public private(set) var lines: [ItemPlanLine]
  public private(set) var nextManualNumber: Int

  /// 확인한 영수증과 그 제안으로 처음 계획을 만든다. 소수 자릿수가 있는 통화는 아직 받지 않는다(nil).
  public static func seed(fields: AllowedReceiptFields, ocr: OCRResult) -> ItemPlan? {
    guard supportedCurrencies.contains(fields.currency) else { return nil }
    let extraction = ItemExtractor.extract(ocr, receiptTotal: fields.amountMinor)
    return ItemPlan(
      extractor: ItemExtractor.version, currency: fields.currency, receiptTotalMinor: fields.amountMinor,
      ocrTotalMinor: extraction.ocrTotalMinor, summary: extraction.summary,
      lines: extraction.candidates.map {
        ItemPlanLine(
          id: $0.id, kind: .item, sourceLineIDs: $0.sourceLineIDs, originalText: $0.originalText,
          originalName: $0.originalName, name: "", nameSource: .none, amountText: $0.amountMinor.map(String.init) ?? "",
          flags: $0.flags, checked: false, excluded: false, assignees: [])
      },
      nextManualNumber: 1)
  }

  public var activeLines: [ItemPlanLine] { lines.filter { !$0.excluded } }
  /// 줄 금액의 합(읽은 것만).
  public var linesTotal: Int { activeLines.compactMap(\.amountMinor).reduce(0, +) }
  /// 영수증 합계 − 줄 합계. 0이어야 나눌 수 있다. 세금·할인 차이는 조정 줄을 더해 맞춘다(저절로 나누지 않는다).
  public var difference: Int { receiptTotalMinor - linesTotal }

  public func line(_ id: String) -> ItemPlanLine? { lines.first { $0.id == id } }
  /// 다시 번역할 수 있는 줄(원문이 있고 빼지 않은 줄).
  public var retranslatableLines: [ItemPlanLine] { lines.filter { !$0.originalName.isEmpty && !$0.excluded } }

  public mutating func setName(_ id: String, _ text: String) {
    update(id) {
      $0.name = text
      $0.nameSource = .user
      if !$0.flags.contains(.amountLinkUncertain) { $0.checked = true }
    }
  }

  /// 제안을 사용자가 골라도 이름만 바꾸고 금액·수량 확인 상태는 보존한다.
  public mutating func acceptRetranslation(_ name: String, matching snapshot: ItemPlanLine) -> Bool {
    guard !name.isEmpty, !snapshot.originalName.isEmpty, !snapshot.excluded,
      let index = lines.firstIndex(where: { $0.id == snapshot.id }), lines[index] == snapshot
    else { return false }
    lines[index] = snapshot.applyingRetranslation(name)
    return true
  }

  public mutating func setAmount(_ id: String, _ text: String) {
    update(id) {
      $0.amountText = text
      $0.checked = true
    }
  }

  public mutating func markChecked(_ id: String) { update(id) { $0.checked = true } }

  public mutating func setExcluded(_ id: String, _ excluded: Bool) {
    update(id) { $0.excluded = excluded }
  }

  public mutating func setAssignee(_ id: String, member: String, on: Bool) {
    update(id) { line in
      line.assignees.removeAll { $0 == member }
      if on { line.assignees.append(member) }
    }
  }

  /// 번역 결과를 이름이 없거나 기계가 채운 줄에만 넣는다. 사용자가 적은 이름은 덮지 않는다.
  /// `originals`를 주면 번역한 원문이 지금 줄의 원문과 같은 줄에만 넣는다(늦게 도착한 결과가 다른 계획에 들어가지 않게).
  public mutating func applyTranslations(
    _ names: [String: String], source: ItemPlanLine.NameSource, originals: [String: String]? = nil
  ) {
    for index in lines.indices {
      guard lines[index].nameSource != .user, let name = names[lines[index].id], !name.isEmpty else { continue }
      if let originals, originals[lines[index].id] != lines[index].originalName { continue }
      lines[index].name = name
      lines[index].nameSource = source
    }
  }

  /// 사용자가 품목이나 조정 줄을 더한다. ID는 계획 안에서 다시 쓰지 않는 번호다.
  @discardableResult
  public mutating func addLine(kind: ItemPlanLine.Kind, name: String, amountText: String) -> String {
    let id = "manual-\(nextManualNumber)"
    nextManualNumber += 1
    lines.append(
      ItemPlanLine(
        id: id, kind: kind, sourceLineIDs: [], originalText: "", originalName: "", name: name,
        nameSource: .user, amountText: amountText, flags: [], checked: true, excluded: false, assignees: []))
    return id
  }

  /// 사용자가 더한 줄만 지운다(OCR 후보는 `setExcluded`).
  public mutating func removeManual(_ id: String) {
    lines.removeAll { $0.id == id && $0.isManual }
  }

  private mutating func update(_ id: String, _ change: (inout ItemPlanLine) -> Void) {
    guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
    change(&lines[index])
  }

  /// 원 단위·엔 단위 정수 글자. 전각 숫자·자릿수 쉼표·공백을 받는다. 조정 줄은 앞의 "-"(또는 ▲·△·−)로 음수.
  public static func parseAmount(_ raw: String, allowNegative: Bool) -> Int? {
    var text = ItemExtractor.normalize(raw).filter { $0 != "," && $0 != " " }
    var sign = 1
    if let first = text.first, ["-", "−", "▲", "△"].contains(first) {
      guard allowNegative else { return nil }
      sign = -1
      text.removeFirst()
    }
    guard !text.isEmpty, text.count <= 9, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text),
      value > 0
    else { return nil }
    return sign * value
  }
}

// MARK: - 사람마다 원화 몫

public struct ItemMemberShare: Equatable, Sendable {
  public let member: String
  public let krw: Int

  public init(member: String, krw: Int) {
    self.member = member
    self.krw = krw
  }
}

/// 품목별 나누기 결과. 어느 경우든 몫은 "직접 나누기" 입력으로만 들어가고, 방장이 "포함하기"를 눌러야 서버에 간다.
public enum ItemAllocation: Equatable, Sendable {
  /// 사람마다 정확한 원 단위 몫(분수 없이 나눠떨어짐). 합은 승인한 원화와 같다.
  case exact([ItemMemberShare])
  /// 두 사람이 똑같이 나누는 몫인데 홀수 원화라 ADR-0007(결제자가 1원 더)을 적용했다.
  case pairRule([ItemMemberShare])
  /// 정확히 나눠떨어지지 않는다. 내림한 몫과 남은 원을 보이고, 남은 원은 방장이 직접 정한다(정책을 만들지 않는다).
  case remainder(floors: [ItemMemberShare], remaining: Int)
}

public enum ItemAllocationProblem: Error, Equatable, Sendable {
  case noLines
  /// 이 영수증 통화는 품목 나누기를 아직 받지 않는다.
  case unsupportedCurrency
  case amountInvalid(lineID: String)
  case needsCheck(lineID: String)
  case unassigned(lineID: String)
  /// 영수증 합계 − 줄 합계(엔·원). 조정 줄을 더하거나 금액을 고쳐야 한다.
  case totalMismatch(difference: Int)
  /// 정산에 쓸 원화가 아직 없다(방장이 지출 원화를 먼저 정한다).
  case krwMissing
  /// 할인 등으로 한 사람의 몫이 0 이하다.
  case nonPositiveShare(member: String)
  case tooLarge
}

public enum ItemAllocator {
  /// - Parameters:
  ///   - krw: 방장이 지출에 정한 원화(KRW 영수증은 금액 그대로). 엔화는 이 원화를 줄 몫의 비율로 나눈다.
  ///   - members: 여행방 구성원 순서(몫 순서와 두 사람 판단에 쓴다).
  public static func allocate(plan: ItemPlan, krw: Int?, payer: String?, members: [String]) -> Result<
    ItemAllocation, ItemAllocationProblem
  > {
    guard ItemPlan.supportedCurrencies.contains(plan.currency) else { return .failure(.unsupportedCurrency) }
    let lines = plan.activeLines
    guard !lines.isEmpty else { return .failure(.noLines) }
    var amounts: [(line: ItemPlanLine, amount: Int, people: [String])] = []
    for line in lines {
      guard let amount = line.amountMinor else { return .failure(.amountInvalid(lineID: line.id)) }
      guard !line.needsCheck else { return .failure(.needsCheck(lineID: line.id)) }
      let people = members.filter(line.assignees.contains)
      guard !people.isEmpty else { return .failure(.unassigned(lineID: line.id)) }
      amounts.append((line, amount, people))
    }
    let sum = amounts.reduce(0) { $0 + $1.amount }
    guard sum == plan.receiptTotalMinor else {
      return .failure(.totalMismatch(difference: plan.receiptTotalMinor - sum))
    }
    let total = plan.receiptTotalMinor
    let krw = plan.currency == "KRW" ? total : krw
    guard let krw, krw > 0 else { return .failure(.krwMissing) }

    // 한 줄을 k명이 나누면 1/k씩. 공통 분모 D = lcm(k)로 사람마다 분자를 정수로 둔다(Σ분자 = 합계 × D).
    var denominator = 1
    for entry in amounts {
      denominator = lcm(denominator, entry.people.count)
      guard denominator <= 1_000_000 else { return .failure(.tooLarge) }
    }
    var numerators: [String: Int] = [:]
    for entry in amounts {
      let (part, overflow) = entry.amount.multipliedReportingOverflow(by: denominator / entry.people.count)
      guard !overflow else { return .failure(.tooLarge) }
      for person in entry.people { numerators[person, default: 0] += part }
    }
    let people = members.filter { numerators[$0] != nil }
    if let bad = people.first(where: { numerators[$0, default: 0] <= 0 }) {
      return .failure(.nonPositiveShare(member: bad))
    }
    let (divisor, overflow) = total.multipliedReportingOverflow(by: denominator)
    guard !overflow else { return .failure(.tooLarge) }
    // 원화 몫 = 분자 × 원화 ÷ (합계 × D). 두 배 너비로 곱하고 나눠 넘치지 않는다.
    var floors: [ItemMemberShare] = []
    var exact = true
    for person in people {
      let product = numerators[person, default: 0].multipliedFullWidth(by: krw)
      let (quotient, remainder) = divisor.dividingFullWidth(product)
      if remainder != 0 { exact = false }
      floors.append(ItemMemberShare(member: person, krw: quotient))
    }
    if exact { return .success(.exact(floors)) }
    let remaining = krw - floors.reduce(0) { $0 + $1.krw }
    // 두 사람의 몫이 똑같다(둘이 반씩과 같은 나누기). 홀수 원화는 ADR-0007대로 결제자가 1원을 더 부담한다.
    if people.count == 2, numerators[people[0]] == numerators[people[1]], remaining == 1, let payer,
      let payerIndex = people.firstIndex(of: payer), floors.allSatisfy({ $0.krw > 0 })
    {
      var shares = floors
      shares[payerIndex] = ItemMemberShare(member: payer, krw: floors[payerIndex].krw + 1)
      return .success(.pairRule(shares))
    }
    return .success(.remainder(floors: floors, remaining: remaining))
  }

  static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
  static func lcm(_ a: Int, _ b: Int) -> Int { a / gcd(a, b) * b }
}

// MARK: - 품목 재번역 결과(기기 안)

/// 품목 재번역 한 번의 요청과 받은 결과. 사용자가 끝내기(적용·닫기) 전까지 초안 폴더 `retranslations/<사진>.json`에
/// 품목 계획과 같은 방식(원자적·보호 쓰기)으로만 둔다. 기기 밖으로 보내거나 동기화하지 않는다.
/// 영수증(초안·사진)은 파일 위치로, 품목은 줄 ID로, 원문은 요청 때 줄 스냅샷(`requested`)으로 묶는다.
public struct ItemRetranslationRecord: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable {
    /// 보냈고 응답을 기다린다. 앱이 그사이 끝났으면 다시 보내지 않고 받지 못했다고 알린다.
    case requested
    /// 응답을 받았다. 사용자가 적용하거나 닫을 때까지 남긴다.
    case received
  }

  public var state: State
  /// 여러 품목 다시 번역(줄 선택)으로 연 요청인지.
  public let batch: Bool
  /// 요청한 줄(요청 때 품목 계획의 줄 그대로).
  public let requested: [ItemPlanLine]
  /// 줄 ID → 받은 이름 제안. 제안이 없는 줄은 원문 유지(보류)다.
  public var suggestions: [String: String]
  /// 줄 ID → "이 이름 사용"의 결과(적용함/품목이 바뀜). 아직 누르지 않은 줄은 없다.
  public var accepted: [String: Bool]

  public init(
    state: State, batch: Bool, requested: [ItemPlanLine], suggestions: [String: String] = [:],
    accepted: [String: Bool] = [:]
  ) {
    self.state = state
    self.batch = batch
    self.requested = requested
    self.suggestions = suggestions
    self.accepted = accepted
  }

  /// 요청한 줄이 지금 계획에 모두 남아 있고 원문이 같은지. 아니면 결과를 버린다.
  public func matches(_ plan: ItemPlan) -> Bool {
    !requested.isEmpty && requested.allSatisfy { plan.line($0.id)?.originalName == $0.originalName }
  }
}
