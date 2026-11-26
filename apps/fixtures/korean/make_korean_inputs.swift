// 한국어 입력용 가상 화면 캡처·영수증 생성기(macOS, CoreGraphics + CoreText). ADR-0013.
// 앱·가게·주소·전화·카드·승인·예약 번호는 모두 가상 값이다. 실제 거래·실존 가게·개인 정보를 쓰지 않는다.
// 사용: swift apps/fixtures/korean/make_korean_inputs.swift apps/fixtures/korean
// 결과: input-k01.png~input-k04.png와 ground-truth.json(receipts/ground-truth.json과 같은 형식 + kind).
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 한 행. 왼쪽 글자와(있으면) 오른쪽 정렬 글자. role: 정답에서의 역할.
struct Row {
  enum Role: String { case plain, sensitive, protected }
  let left: String
  let right: String?
  let size: CGFloat
  let role: Role
  let bold: Bool
  let font: String?
  let gap: CGFloat
  init(
    _ left: String, _ right: String? = nil, size: CGFloat = 26, role: Role = .plain, bold: Bool = false,
    font: String? = nil, gap: CGFloat = 0
  ) {
    self.left = left
    self.right = right
    self.size = size
    self.role = role
    self.bold = bold
    self.font = font
    self.gap = gap
  }
}

struct Input {
  let ref: String
  // date: 지출 날짜 정답. 숙소 화면은 체크인이 아니라 결제일이다.
  let kind: String
  let width: Int
  let height: Int
  /// 화면 캡처는 회색 카드 배경과 위쪽 상태 막대를 그린다.
  let screen: Bool
  let date: String
  let total: Int
  let currency: String
  let merchant: String
  let rows: [Row]
}

let kr = "AppleSDGothicNeo-Regular"
let krBold = "AppleSDGothicNeo-Bold"
let ja = "HiraginoSans-W3"

let inputs = [
  Input(
    ref: "k01", kind: "screen-lodging", width: 720, height: 1560, screen: true, date: "2026-10-20", total: 265_100,
    currency: "KRW", merchant: "가상호텔 미도리 신주쿠",
    rows: [
      Row("가상호텔 미도리 신주쿠", size: 34, bold: true, gap: 10),
      Row("예약 확정 · 가상 여행앱", size: 24),
      Row("체크인", "2026.11.03 (화) 15:00", role: .protected, gap: 30),
      Row("체크아웃", "2026.11.05 (목) 11:00", role: .protected),
      Row("객실", "스탠다드 트윈 · 2박"),
      Row("투숙 인원", "성인 2명"),
      Row("예약번호", "4708215963", role: .sensitive, gap: 30),
      Row("연락처", "010-5550-0147", role: .sensitive),
      Row("객실 요금", "₩241,000", role: .protected, gap: 30),
      Row("세금 및 수수료", "₩24,100", role: .protected),
      Row("총 결제 금액", "₩265,100", size: 30, role: .protected, bold: true),
      Row("결제 카드", "5555-12**-****-4821", role: .sensitive, gap: 30),
      Row("결제일", "2026.10.20", role: .protected),
      Row("무료 취소 2026.11.01 23:59까지", size: 22, gap: 30),
      Row("SYNTHETIC KOREAN k01", size: 18, gap: 40),
    ]),
  Input(
    ref: "k02", kind: "screen-payment", width: 720, height: 1560, screen: true, date: "2026-11-04", total: 38_500,
    currency: "KRW", merchant: "가상식당 하나",
    rows: [
      Row("가상식당 하나", size: 34, bold: true, gap: 10),
      Row("결제 완료 · 가상페이", size: 24),
      Row("38,500원", size: 44, role: .protected, bold: true, gap: 20),
      Row("결제일시", "2026년 11월 4일 19:22", role: .protected, gap: 30),
      Row("결제금액", "38,500원", role: .protected),
      Row("결제수단", "가상카드 일시불"),
      Row("카드번호", "9411-23**-****-0582", role: .sensitive),
      Row("승인번호", "30418827", role: .sensitive),
      Row("가맹점", "가상식당 하나"),
      Row("적립 예정", "385원", role: .protected, gap: 30),
      Row("SYNTHETIC KOREAN k02", size: 18, gap: 40),
    ]),
  Input(
    ref: "k03", kind: "receipt", width: 640, height: 980, screen: false, date: "2026-11-02", total: 6_900,
    currency: "KRW", merchant: "가상편의점 하늘공항점",
    rows: [
      Row("가상편의점 하늘공항점", size: 30, bold: true),
      Row("주소 가상시 구름구 별빛로 12", size: 20),
      Row("전화 02-555-0186", size: 20, role: .sensitive),
      Row("2026-11-02 08:15", size: 22, role: .protected),
      Row("생수 500ml", "1,200", size: 24, role: .protected, gap: 10),
      Row("삼각김밥", "1,500", size: 24, role: .protected),
      Row("커피 우유", "4,200", size: 24, role: .protected),
      Row("과세물품", "6,273", size: 22, role: .protected, gap: 10),
      Row("부가세", "627", size: 22, role: .protected),
      Row("합계", "6,900원", size: 28, role: .protected, bold: true),
      Row("카드번호 4521-87**-****-3310", size: 22, role: .sensitive, gap: 10),
      Row("승인번호 52906634", size: 22, role: .sensitive),
      Row("SYNTHETIC KOREAN k03", size: 16, gap: 10),
    ]),
  Input(
    ref: "k04", kind: "screen-mixed", width: 720, height: 1400, screen: true, date: "2026-11-06", total: 2_480,
    currency: "JPY", merchant: "해외 결제 상세",
    rows: [
      Row("해외 결제 상세", size: 34, bold: true, gap: 10),
      Row("みどり書店 しぶや店", size: 28, font: ja),
      Row("결제일시", "2026.11.06 13:05", role: .protected, gap: 30),
      Row("결제금액", "¥2,480", size: 30, role: .protected, bold: true),
      Row("원화 환산", "22,940원", role: .protected),
      Row("카드번호", "6011-55**-****-7204", role: .sensitive),
      Row("승인번호", "87120456", role: .sensitive),
      Row("상품", "ガイドブック", font: ja),
      Row("SYNTHETIC KOREAN k04", size: 18, gap: 40),
    ]),
]

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let space = CGColorSpaceCreateDeviceRGB()
var truths: [[String: Any]] = []

func attributed(_ text: String, font: CTFont, gray: CGFloat) -> CTLine {
  CTLineCreateWithAttributedString(
    NSAttributedString(
      string: text,
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
      ]))
}

for input in inputs {
  let width = input.width
  let height = input.height
  let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  let background: CGFloat = input.screen ? 0.96 : 1
  ctx.setFillColor(CGColor(gray: background, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  // 좌표는 CoreGraphics(왼쪽 아래 원점). 정답은 왼쪽 위 원점으로 바꿔 적는다.
  var top: CGFloat = input.screen ? 165 : 50
  if input.screen {
    // 상태 막대(글자 없음)와 흰 카드 영역.
    ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: CGFloat(height) - 60, width: CGFloat(width), height: 60))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 24, y: 80, width: CGFloat(width) - 48, height: CGFloat(height) - 220))
  }
  var lines: [[String: Any]] = []
  var sensitive: [[String: Any]] = []
  var protected: [[String: Any]] = []
  let margin: CGFloat = input.screen ? 56 : 48
  for row in input.rows {
    top += row.gap
    let fontName = row.font ?? (row.bold ? krBold : kr)
    let font = CTFontCreateWithName(fontName as CFString, row.size, nil)
    let ascent = CTFontGetAscent(font)
    let baseline = top + ascent
    var rect: [Int]? = nil
    var valueRect: [Int]? = nil
    func draw(_ text: String, rightAligned: Bool, gray: CGFloat, valueFrom: Int? = nil) {
      let line = attributed(text, font: font, gray: gray)
      let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
      let x = rightAligned ? CGFloat(width) - margin - w : margin
      ctx.textPosition = CGPoint(x: x, y: CGFloat(height) - baseline)
      // 그리기 전에 잰다(CTLineDraw가 글자 위치를 줄 너비만큼 옮긴다).
      let ink = CTLineGetImageBounds(line, ctx)
      CTLineDraw(line, ctx)
      // 잉크 경계(왼쪽 위 원점, 오른쪽·아래 제외)에 2px 여백.
      let box = [
        Int((ink.minX).rounded(.down)) - 2, Int((CGFloat(height) - ink.maxY).rounded(.down)) - 2,
        Int((ink.maxX).rounded(.up)) + 2, Int((CGFloat(height) - ink.minY).rounded(.up)) + 2,
      ]
      lines.append(["rect": box, "text": text])
      if rightAligned { valueRect = box }
      if let valueFrom {
        // 한 줄에 라벨과 번호가 있으면 번호가 시작하는 글자부터 오른쪽 잉크 끝까지가 가릴 대상이다.
        let offset = CTLineGetOffsetForStringIndex(line, valueFrom, nil)
        valueRect = [Int((x + offset).rounded(.down)) - 1, box[1], box[2], box[3]]
      }
      rect =
        rect.map { [min($0[0], box[0]), min($0[1], box[1]), max($0[2], box[2]), max($0[3], box[3])] } ?? box
    }
    // 화면의 라벨 칸은 회색, 값은 검정(실제 앱 화면처럼 대비가 다르다).
    let labelGray: CGFloat = input.screen && row.right != nil ? 0.42 : 0.08
    // 영수증형 한 줄 민감 행("카드번호 4521-…")은 첫 공백 뒤가 번호다.
    let valueFrom =
      row.role == .sensitive && row.right == nil
      ? row.left.firstIndex(of: " ").map { (row.left.utf16.distance(from: row.left.utf16.startIndex, to: $0.samePosition(in: row.left.utf16)!)) + 1 }
      : nil
    draw(row.left, rightAligned: false, gray: labelGray, valueFrom: valueFrom)
    if let right = row.right { draw(right, rightAligned: true, gray: 0.08) }
    let text = row.right.map { "\(row.left) \($0)" } ?? row.left
    switch row.role {
    // 라벨·값 행은 값(번호)만 가릴 대상이다. 라벨은 가려도 되지만 식별 정보가 아니다.
    case .sensitive:
      let value = row.right ?? String(row.left.split(separator: " ", maxSplits: 1).last ?? "")
      sensitive.append(["rect": valueRect ?? rect!, "text": value])
    case .protected: protected.append(["rect": rect!, "text": text])
    case .plain: break
    }
    top += row.size * 1.9
  }
  precondition(top < CGFloat(height) - 40, "\(input.ref) rows overflow")
  let image = ctx.makeImage()!
  let file = "input-\(input.ref).png"
  let url = out.appending(path: file)
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  // 가상 표지(사본에 남으면 안 된다). check_artifact.py가 이 문자열을 찾는다.
  let description = "SYNTHETIC-ORIGINAL-METADATA \(input.ref), 가상 한국어 입력"
  let properties: [CFString: Any] = [
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: description],
    kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: description],
    kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description],
  ]
  CGImageDestinationAddImage(dest, image, properties as CFDictionary)
  CGImageDestinationFinalize(dest)
  truths.append([
    "ref": input.ref, "kind": input.kind, "file": file, "width": width, "height": height, "date": input.date,
    "total": input.total, "currency": input.currency, "merchant": input.merchant, "unreadable": false,
    "lines": lines, "sensitive": sensitive, "protected": protected,
  ])
  print("wrote", url.path)
}

let json = try JSONSerialization.data(withJSONObject: truths, options: [.prettyPrinted, .sortedKeys])
try (String(decoding: json, as: UTF8.self) + "\n").write(
  to: out.appending(path: "ground-truth.json"), atomically: true, encoding: .utf8)
