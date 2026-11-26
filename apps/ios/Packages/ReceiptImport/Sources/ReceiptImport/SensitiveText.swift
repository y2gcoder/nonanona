import Foundation

/// 가림 전용 문자 판정. 품목 추출의 OCR 전문과 문자열은 바꾸지 않는다.
struct SensitiveText {
  private static let labels = expression(
    #"(?<![A-Z])(?:TEL|phone|card|reservation|booking|PIN|approval|authori[sz]ation|member(?:ship)?|AUTH|APPR)(?![A-Z])|電話|カ[ー一\-]ド|会員|承認|予約\s*(?:番号|ID|コード|No)|お客様\s*番号|會員\s*(?:號碼|编号)|카드\s*번호|승인\s*번호|회원\s*번호|예약\s*번호|전화(?:\s*번호)?|연락처"#
  )
  /// "번호" 없이 읽힌 한국어 라벨 낱말(OCR이 "번호"를 빠뜨렸거나 따로 읽은 경우, ADR-0013, Android와 같다).
  /// - 바로 뒤에 번호 값(숫자 2자리 이상이 든 영문·숫자)이 붙으면 라벨이다(`승인 4938`, `승인 46`, `예약: AB12`).
  /// - 줄이 그 낱말로 끝나면(`승인`, `결제 카드`) 값이 따로 읽힌 독립 라벨이다. `SensitiveLines`가 강한 라벨처럼 같은 행·다음 행에서
  ///   값을 찾고, 못 찾으면 확인을 안내한다.
  /// - 문구 속 낱말(`예약 확정`, `가상카드 일시불`, `예약 2명`)은 라벨이 아니다.
  /// 사업자(등록)·등록·가맹점 번호는 가게 정보라 띄어쓰기와 상관없이 뺀다.
  private static let weakLabels = expression(#"카드|승인|회원|예약|번호"#)
  private static let storeNumber = expression(#"(?:사업자\s*(?:등록\s*)?|등록\s*|가맹점\s*)번호"#)
  private static let weakEnding = expression(#"^\s*[:：.#\-]?\s*$"#)
  private static let weakValue = expression(
    #"^\s*[:：.#\-]?\s*(?:번호\s*[:：.#\-]?\s*)?([A-Z0-9*●•#×][A-Z0-9*●•#×\-‐–−|_]*)"#)
  private static let qualifiers = expression(#"^\s*(?:番号|號碼|번호|CODE|NO\.?|ID)?[\s:：.#\-]*"#)
  private static let masked =
    #"(?:\d{4}[\s\p{Pd}|/_−]+)?\d{0,3}(?:[*●•X×#][\s\p{Pd}|/_−]*){2,}\d(?:[\s\p{Pd}|/_−]*\d){1,3}(?!\d)"#
  private static let maskedCard = expression(masked)
  private static let phone = #"(?<!\d)\d{2,4}\s*[-‐–−(]\s*\d{2,4}\s*[-‐–−)]\s*\d{3,4}(?!\d)"#
  private static let numbers = expression(phone + #"|(?:\d{4}[\s-]){2,3}\d{4}|\d{6,}"#)
  private static let bookingCode = expression(#"(?<![A-Z0-9])([A-Z]+)\s*[-‐–−]\s*([0-9]+)(?![A-Z0-9])"#)
  // 앞 숫자 조각이 금액인 경우에도 뒤의 겹치는 조각부터 다시 판정한다.
  private static let splitNumber = expression(#"(?<!\d)(?=(\d{3,4}\s+\d{3,4}(?!\d)))"#)
  private static let labelledValue = expression(
    "^(?:" + masked + "|" + phone + #"|[A-Z0-9*●•#×]+(?:[-‐–−|_][A-Z0-9*●•#×]+|\s+\d{2,})*)"#)
  // Vision은 날짜의 월·일 두 자리 사이에도 가끔 공백을 넣는다.
  private static let dates = expression(#"(?<!\d)\d{4}\s*[-/.年년]\s*\d(?:\s*\d)?\s*[-/.月월]\s*\d(?:\s*\d)?(?!\d)"#)
  private static let amounts = expression(
    #"[¥$€£₩]\s*\d[\d,.]*|\d[\d,.]*\s*(?:円|원|JPY\b|USD\b|KRW\b|EUR\b)|(?:合計|お会計|支払額|決済金額|小計|税|割引|釣銭|お預り|total)\s*\d[\d,.]*"#
  )
  private static let business = expression(#"住所|登録番号|レジ(?:\s|ID|NO|番号)|\b(?:register|terminal)\s*(?:ID|NO|#)"#)
  private static let itemCode = expression(#"\bJAN\s*(?:コード\s*)?[:：]?\s*(?:\d{13}|\d{8})(?!\d)"#)
  private static let fragments = expression(#"^[\s:：#※*●•X×()|\p{Pd}A-Z0-9]+$"#)
  private static let firstPassField = expression(
    #"合計|お会計|支払額|決済金額|小計|税|割引|釣銭|お預り|total|[¥$€£₩]"#)
  private static let identifierToken = expression(#"[\p{L}\p{N}]+(?:[\p{Pd}|_/()][\p{L}\p{N}]+)*"#)

  let text: String
  /// 값이 따로 읽힌 독립 약한 라벨(줄이 약한 라벨 낱말로 끝난다). 강한 라벨 줄은 아니다.
  let isWeakStandaloneLabel: Bool
  let labelRanges: [NSRange]
  let valueRanges: [NSRange]
  private let strongNumberRanges: [NSRange]
  private let bookingRanges: [NSRange]
  private let containsBookingForm: Bool
  let isProtected: Bool
  let protectsCommercialRow: Bool

  init(_ original: String) {
    let normalized = Self.normalize(original)
    text = normalized
    let units = normalized as NSString
    let range = NSRange(location: 0, length: units.length)
    let strongLabels = Self.labels.matches(in: normalized, range: range).map(\.range)
    let amounts = Self.amounts.matches(in: normalized, range: range)
    let boundaries = (Self.dates.matches(in: normalized, range: range) + amounts).map(\.range)
    let stores = Self.storeNumber.matches(in: normalized, range: range).map(\.range)
    let weakWords = Self.weakLabels.matches(in: normalized, range: range).map(\.range).filter { weak in
      !(strongLabels + stores).contains { NSIntersectionRange($0, weak).length > 0 }
    }
    let weakLabels = weakWords.filter { weak in
      let start = NSMaxRange(weak)
      let tail = units.substring(from: start)
      guard let hit = Self.weakValue.firstMatch(in: tail, range: NSRange(location: 0, length: tail.utf16.count))
      else { return false }
      let token = hit.range(at: 1)
      let value = (tail as NSString).substring(with: token)
      let shifted = NSRange(location: start + token.location, length: token.length)
      return value.filter(\.isNumber).count >= 2
        && !boundaries.contains { NSIntersectionRange($0, shifted).length > 0 }
    }
    let labelRanges = (strongLabels + weakLabels).sorted { $0.location < $1.location }
    isWeakStandaloneLabel =
      labelRanges.isEmpty
      && weakWords.last.map { last in
        let tail = units.substring(from: NSMaxRange(last))
        return Self.weakEnding.firstMatch(in: tail, range: NSRange(location: 0, length: tail.utf16.count)) != nil
      } == true
    let item = Self.itemCode.firstMatch(in: normalized, range: range) != nil
    let businessField = item || Self.business.firstMatch(in: normalized, range: range) != nil
    let commercial = item || !amounts.isEmpty || Self.firstPassField.firstMatch(in: normalized, range: range) != nil
    protectsCommercialRow = commercial
    isProtected = businessField || commercial || !boundaries.isEmpty
    self.labelRanges = labelRanges
    let codes = Self.bookingCode.matches(in: normalized, range: range)
    containsBookingForm = !codes.isEmpty
    bookingRanges = codes.filter {
      !businessField && !commercial && $0.range(at: 1).length <= 4 && $0.range(at: 2).length >= 5
    }.map(\.range)
    let splitNumbers = Self.splitNumber.matches(in: normalized, range: range).map { $0.range(at: 1) }
    let bareNumbers = (Self.numbers.matches(in: normalized, range: range).map(\.range) + splitNumbers).filter {
      number in
      !codes.contains { NSIntersectionRange($0.range, number).length > 0 }
    }
    let cards = Self.maskedCard.matches(in: normalized, range: range).map(\.range)
    strongNumberRanges = (cards + bareNumbers).filter { number in
      (!businessField || !labelRanges.isEmpty) && !boundaries.contains { NSIntersectionRange($0, number).length > 0 }
    }
    valueRanges = labelRanges.enumerated().compactMap { index, label in
      let start = NSMaxRange(label)
      let nextLabel = index + 1 < labelRanges.count ? labelRanges[index + 1].location : range.length
      let end = boundaries.lazy.map(\.location).filter { $0 >= start }.min().map { min($0, nextLabel) } ?? nextLabel
      guard start < end else { return nil }
      let tail = units.substring(with: NSRange(location: start, length: end - start))
      let tailRange = NSRange(location: 0, length: tail.utf16.count)
      let prefix = Self.qualifiers.firstMatch(in: tail, range: tailRange)?.range.length ?? 0
      let value = String(tail.dropFirst(prefix))
      guard let hit = Self.labelledValue.firstMatch(in: value, range: NSRange(location: 0, length: value.utf16.count)),
        (value as NSString).substring(with: hit.range).contains(where: \.isNumber)
      else { return nil }
      return NSRange(location: start + prefix, length: hit.range.length)
    }
  }

  var hasLabel: Bool { !labelRanges.isEmpty }
  private static let fieldNames = expression(
    #"수량|数量|個数|(?<![A-Z])QTY(?![A-Z])|금액|金額|단가|単価|가격|価格|小計|소계|합계|合計|お会計|결제\s*수단|상태|状態"#)

  /// 값을 가진 다른 필드의 이름(수량·금액·소계·합계·결제수단·상태 등, 숫자 없음). 같은 행·다음 행 값의 소유자다(Android와 같다).
  var isFieldName: Bool {
    !hasLabel && !text.contains { $0.isNumber }
      && Self.fieldNames.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
  }

  private static let storeInfo = expression(#"(?:사업자\s*(?:등록\s*)?|등록\s*|가맹점\s*)번호|레지"#)

  /// 한국어 가게 정보(가맹점·사업자·등록 번호, 레지). 가림 여백이 닿지 않게 지킨다(ADR-0005·0013).
  var isStoreInfo: Bool {
    !hasLabel && Self.storeInfo.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
  }

  /// 숫자 없이 글자(한글·한자·가나·영문)만 든 필드명 상자. 다음 행 값이 그 행의 다른 필드 것인지 볼 때 쓴다.
  var hasFieldName: Bool { text.contains { $0.isLetter } && !text.contains { $0.isNumber } }

  /// "번호 4938"처럼 약한 라벨 뒤에 따로 읽힌 "번호…" 조각.
  var startsWithNumberWord: Bool { text.drop { $0.isWhitespace }.hasPrefix("번호") }
  var hasStrongNumber: Bool { !strongNumberRanges.isEmpty || (!containsBookingForm && isFragment(minDigits: 6)) }
  var hasBookingCode: Bool { !bookingRanges.isEmpty }
  var hasNumber: Bool { hasStrongNumber || hasBookingCode }
  var isMixed: Bool { isProtected && (hasLabel || hasNumber) }
  private var numberRanges: [NSRange] { strongNumberRanges + bookingRanges }

  /// 숫자가 속한 범위를 먼저 사용한다. 분리할 수 없는 혼합 행은 호출자가 전부 가리고 안내한다.
  var maskRange: NSRange? {
    (valueRanges + numberRanges).reduce(nil as NSRange?) { result, range in
      result.map { NSUnionRange($0, range) } ?? range
    }
  }

  var identifierValues: [String] {
    let ranges =
      valueRanges
      + numberRanges.filter { number in
        !valueRanges.contains { NSIntersectionRange($0, number).length > 0 }
      }
    var values = canonicalIdentifiers(in: ranges)
    if ranges.isEmpty && hasNumber { values.append(Self.canonical(text)) }
    return values.filter { $0.count >= 4 }
  }

  var identifierLabels: [String] { isMixed ? [] : canonicalIdentifiers(in: labelRanges) }
  var identifiers: [String] { identifierValues + identifierLabels }

  private func canonicalIdentifiers(in ranges: [NSRange]) -> [String] {
    let units = text as NSString
    return ranges.map { Self.canonical(units.substring(with: $0)) }.filter { $0.count >= 4 }
  }

  var tokens: [String] {
    canonicalIdentifiers(
      in: Self.identifierToken.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
        .map(\.range))
  }

  func isFragment(minDigits: Int) -> Bool {
    !isProtected && text.filter(\.isNumber).count >= minDigits
      && Self.fragments.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
  }

  static func normalize(_ text: String) -> String {
    text.precomposedStringWithCompatibilityMapping
  }

  static func canonical(_ text: String) -> String {
    String(normalize(text).lowercased().filter { $0.isLetter || $0.isNumber })
  }

  static func hasMaskedCard(_ raw: String) -> Bool {
    let text = normalize(raw)
    return maskedCard.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
  }

  static func originalRange(_ range: NSRange, in original: String) -> Range<String.Index>? {
    if normalize(original) == original { return Range(range, in: original) }
    var offset = 0
    var start: String.Index?
    var index = original.startIndex
    while index < original.endIndex {
      let next = original.index(after: index)
      let end = offset + normalize(String(original[index..<next])).utf16.count
      if start == nil, range.location < end { start = index }
      if let start, NSMaxRange(range) <= end { return start..<next }
      index = next
      offset = end
    }
    return nil
  }

  private static func expression(_ pattern: String) -> NSRegularExpression {
    // 고정 패턴은 한 번만 컴파일한다.
    try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
  }
}
