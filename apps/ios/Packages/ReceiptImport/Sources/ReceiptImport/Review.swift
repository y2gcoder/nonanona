import Foundation

/// 사용자가 직접 더한 가림 띠. OCR이 줄을 찾지 못했거나 제안이 빠뜨린 곳(미탐지)을 가린다.
/// 위치는 사진 높이에 대한 정수 퍼센트(위 기준)이고 가로 전체를 덮는다. 정수라서 두 플랫폼이 같은 픽셀을 굽는다.
public struct MaskRegion: Codable, Equatable, Hashable, Identifiable, Sendable {
  public static let moveStep = 2
  public static let resizeStep = 1
  public static let minHeight = 2
  public static let defaultTop = 47
  public static let defaultHeight = 6

  public let id: String
  public private(set) var topPercent: Int
  public private(set) var heightPercent: Int

  public init(id: String, topPercent: Int = MaskRegion.defaultTop, heightPercent: Int = MaskRegion.defaultHeight) {
    self.id = id
    let height = min(100, max(Self.minHeight, heightPercent))
    self.heightPercent = height
    self.topPercent = min(100 - height, max(0, topPercent))
  }

  public var bottomPercent: Int { topPercent + heightPercent }

  /// 위(음수)·아래(양수)로 옮긴다. 사진 밖으로 나가지 않는다.
  public func moved(by delta: Int) -> MaskRegion {
    MaskRegion(id: id, topPercent: topPercent + delta, heightPercent: heightPercent)
  }

  /// 아래쪽 가장자리를 늘리거나 줄인다. 바닥에 닿으면 위로 넓힌다.
  public func resized(by delta: Int) -> MaskRegion {
    let height = min(100, max(Self.minHeight, heightPercent + delta))
    return MaskRegion(id: id, topPercent: min(topPercent, 100 - height), heightPercent: height)
  }
}

/// 검토 중인 사진 한 장의 저장된 입력. 기기 안 초안 폴더(`reviews/`)에만 있고, 고칠 때마다 쓴다.
/// nil인 값은 OCR 제안(읽지 못한 사진은 빈 값)을 그대로 쓴다는 뜻이다. 그래서 다시 읽기가 성공해도 사용자가 친 값은 남는다.
public struct ReviewDraft: Codable, Equatable, Sendable {
  public var date: String?
  public var amount: String?
  public var currency: String?
  public var merchant: String?
  /// 가릴 OCR 줄. nil이면 제안 그대로다.
  public var maskLineIDs: [Int]?
  public var regions: [MaskRegion]

  public init(
    date: String? = nil, amount: String? = nil, currency: String? = nil, merchant: String? = nil,
    maskLineIDs: [Int]? = nil, regions: [MaskRegion] = []
  ) {
    self.date = date
    self.amount = amount
    self.currency = currency
    self.merchant = merchant
    self.maskLineIDs = maskLineIDs
    self.regions = regions
  }

  /// 제안과 합친, 화면에 보이고 확인에 쓰는 값.
  public func resolved(with proposal: OCRProposal?) -> ResolvedReview {
    let fields = proposal?.fields
    return ResolvedReview(
      date: date ?? fields?.date ?? "",
      amount: amount ?? fields.map { ReviewForm.amountText(minor: $0.amountMinor, currency: $0.currency) } ?? "",
      currency: currency ?? fields?.currency ?? ReviewForm.defaultCurrency,
      merchant: merchant ?? fields?.merchant ?? "",
      maskLineIDs: Set(maskLineIDs ?? proposal?.suggestedMaskLineIDs ?? []),
      regions: regions)
  }
}

public struct ResolvedReview: Equatable, Sendable {
  public let date: String
  public let amount: String
  public let currency: String
  public let merchant: String
  public let maskLineIDs: Set<Int>
  public let regions: [MaskRegion]

  public var maskCount: Int { maskLineIDs.count + regions.count }
}

/// 검토 화면 입력이 왜 확인할 수 없는지. 화면 문구는 앱이 정한다.
public enum FieldProblem: String, Codable, Sendable, CaseIterable {
  case date
  case amount
  case currency
  case merchant
}

/// 입력 칸의 글자를 기기 밖으로 나갈 수 있는 필드로 바꾼다. 서버(`expenses`)의 제약과 같은 범위만 받는다.
public enum ReviewForm {
  public static let defaultCurrency = "JPY"
  /// 고를 수 있는 통화와 소수 자릿수(ISO 4217).
  public static let currencies: [(code: String, minorDigits: Int)] = [("JPY", 0), ("KRW", 0), ("USD", 2), ("EUR", 2)]
  public static let maxMerchantLength = 80
  static let maxAmountMinor = 100_000_000

  public static func validate(date: String, amount: String, currency: String, merchant: String) -> Result<
    AllowedReceiptFields, Problems
  > {
    var problems: Set<FieldProblem> = []
    let isoDate = validDate(date)
    if isoDate == nil { problems.insert(.date) }
    let digits = currencies.first { $0.code == currency }?.minorDigits
    if digits == nil { problems.insert(.currency) }
    let minor = digits.flatMap { amountMinor(amount, minorDigits: $0) }
    if digits != nil, minor == nil { problems.insert(.amount) }
    let name = merchant.trimmingCharacters(in: .whitespaces)
    if name.count > maxMerchantLength || name.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
      problems.insert(.merchant)
    }
    guard problems.isEmpty, let isoDate, let minor else { return .failure(Problems(problems)) }
    return .success(
      AllowedReceiptFields(date: isoDate, amountMinor: minor, currency: currency, merchant: name.isEmpty ? nil : name))
  }

  public struct Problems: Error, Equatable {
    public let fields: Set<FieldProblem>
    init(_ fields: Set<FieldProblem>) { self.fields = fields }
  }

  /// yyyy-MM-dd이고 달력에 있는 날짜만.
  static func validDate(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespaces)
    guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
    let parts = text.split(separator: "-").compactMap { Int($0) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
    guard (2000...2100).contains(parts[0]), components.isValidDate(in: calendar) else { return nil }
    return text
  }

  /// "1,408" → 1408, USD "12.5" → 1250. 쉼표·공백은 무시한다. 소수 자릿수가 통화보다 많거나 0 이하면 nil.
  static func amountMinor(_ raw: String, minorDigits: Int) -> Int? {
    let text = raw.filter { $0 != "," && $0 != " " }
    let pattern = minorDigits == 0 ? #"^\d{1,9}$"# : #"^\d{1,9}(\.\d{1,\#(minorDigits)})?$"#
    guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    let whole = Int(parts[0]) ?? 0
    var fraction = parts.count > 1 ? String(parts[1]) : ""
    while fraction.count < minorDigits { fraction += "0" }
    var scale = 1
    for _ in 0..<minorDigits { scale *= 10 }
    let value = whole * scale + (Int(fraction) ?? 0)
    guard value > 0, value < maxAmountMinor else { return nil }
    return value
  }

  /// 입력 칸에 처음 보일 금액(쉼표 없이). 1408 JPY → "1408", 1250 USD → "12.50".
  public static func amountText(minor: Int, currency: String) -> String {
    let digits = currencies.first { $0.code == currency }?.minorDigits ?? 0
    guard digits > 0 else { return String(minor) }
    var scale = 1
    for _ in 0..<digits { scale *= 10 }
    let fraction = String(minor % scale)
    return "\(minor / scale)." + String(repeating: "0", count: digits - fraction.count) + fraction
  }
}

/// 검토 화면에서만 보여 주는 가린 사본 미리보기. 확인할 때와 같은 굽기 함수로 만들지만 디스크에 쓰지 않고,
/// 기기 밖으로 보내는 타입(`OutboundReceipt`)으로 바꿀 수 없다.
public struct MaskPreview: Equatable, Sendable {
  public let pngData: Data
  public let maskCount: Int
}

extension ProcessingManifest {
  /// "확인하고 다음"이 열 다음 사진: 목록 순서(사진 번호)로 지금 사진 뒤의 첫 `ready`, 없으면 앞쪽의 첫 `ready`.
  /// 읽는 중·실패·확인한 사진은 고르지 않는다(확인을 건너뛰지 않는다). 없으면 nil(목록으로 돌아간다).
  public func nextToReview(after itemID: String?) -> ProcessingItem? {
    let ordered = items.sorted { $0.position < $1.position }
    let current = ordered.first { $0.id == itemID }?.position ?? 0
    let ready = ordered.filter { $0.state == .ready && $0.id != itemID }
    return ready.first { $0.position > current } ?? ready.first
  }

  public func count(_ state: ProcessingItem.State) -> Int { items.filter { $0.state == state }.count }
}
