// 품목 나누기용 가상 일본어 영수증 생성기(macOS, CoreGraphics + CoreText). 가게·주소·전화는 모두 가상 값이다.
// 사용: swift apps/fixtures/items/make_item_receipts.swift apps/fixtures/items
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Receipt {
  let file: String
  let lines: [(left: String, right: String?, size: CGFloat)]
}

let receipts = [
  Receipt(
    file: "receipt-i01.png",
    lines: [
      ("架空居酒屋 はなび", nil, 30),
      ("架空県ゆめ市あおば町3-4", nil, 20),
      ("TEL 03-5550-0303", nil, 20),
      ("2026年11月5日 19:42", nil, 22),
      ("枝豆", "¥418", 24),
      ("鶏の唐揚げ", "¥748", 24),
      ("生ビール 2杯", "¥1,320", 24),
      ("ウーロン茶", "¥385", 24),
      ("だし巻き玉子", "¥629", 24),
      ("合計", "¥3,500", 28),
      ("(内消費税等", "¥318)", 20),
      ("お預り", "¥5,000", 22),
      ("お釣り", "¥1,500", 22),
      ("SYNTHETIC ITEMS i01", nil, 16),
    ]),
  Receipt(
    file: "receipt-i02.png",
    lines: [
      ("架空マート ほしぞら", nil, 30),
      ("2026年11月6日 10:15", nil, 22),
      ("おにぎり 鮭", "160円", 24),
      ("緑茶ボトル", "140円", 24),
      ("サンドイッチ", "398円", 24),
      ("値引", "-50円", 24),
      ("小計", "648円", 24),
      ("消費税等(8%)", "51円", 22),
      ("合計", "699円", 28),
      ("クレジット", "699円", 22),
      ("SYNTHETIC ITEMS i02", nil, 16),
    ]),
]

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let width = 720
let space = CGColorSpaceCreateDeviceRGB()
for receipt in receipts {
  let height = 80 + receipt.lines.count * 54
  let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  var y = CGFloat(height) - 70
  for line in receipt.lines {
    let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, line.size, nil)
    func draw(_ text: String, rightAligned: Bool) {
      let attributed = NSAttributedString(
        string: text,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.05, alpha: 1),
        ])
      let ctLine = CTLineCreateWithAttributedString(attributed)
      let w = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
      ctx.textPosition = CGPoint(x: rightAligned ? CGFloat(width) - 60 - CGFloat(w) : 56, y: y)
      CTLineDraw(ctLine, ctx)
    }
    draw(line.left, rightAligned: false)
    if let right = line.right { draw(right, rightAligned: true) }
    y -= 54
  }
  let image = ctx.makeImage()!
  let url = out.appending(path: receipt.file)
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  // 사진 앱이 보이는 설명(E2E가 이 글자로 사진을 고른다). 가상 표지만 담는다.
  let ref = String(receipt.file.dropFirst("receipt-".count).prefix(3))
  let description = "SYNTHETIC-ITEMS-METADATA \(ref), 가상 품목 영수증"
  let properties: [CFString: Any] = [
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: description],
    kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: description],
    kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description],
  ]
  CGImageDestinationAddImage(dest, image, properties as CFDictionary)
  CGImageDestinationFinalize(dest)
  print("wrote", url.path)
}
