import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ReceiptImport

struct MaskCrossReviewTests {
  private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures")

  @Test(arguments: [
    "承認番号 0123456 2026/11/08", "予約番号 RSV-12345 2026-11-08 19:00",
    "カード ************1234 ¥3,280", "会員番号 12345678 ポイント対象 ¥3,000",
    "VISA ****-****-****-1234", "VISA ****｜********-1234", "####-####-####-12",
    "카드번호 1234-56**-****-7890", "승인번호 12345", "カ一ド番号", "ｶｰﾄﾞ番号 ****1234",
    "AUTH CODE 0A12B3", "APPR 0A12B3", "會員號碼 A12345", "お客様番号 A-12345",
  ])
  func sensitiveTextSurvivesProtectionAndRecognitionVariants(_ text: String) {
    #expect(SensitiveLines(Self.ocr([Self.box(0, text, x: 0.05, width: 0.89)])).ids == [0])
  }

  @Test func priceBoxDoesNotSuppressDifferentCardBoxOnSameRow() {
    let card = Self.box(1, "************1234", x: 0.20, width: 0.30)
    let price = Self.box(2, "¥3,280", x: 0.52, width: 0.15)
    #expect(SensitiveLines(Self.ocr([Self.box(0, "VISA", x: 0.05, width: 0.08), card, price])).ids == [1])
  }

  @Test func singleDigitsImmediatelyAfterAnApprovalNumberAreCovered() {
    let lines = [
      Self.box(0, "承認番号 01234", x: 0.05, width: 0.30),
      Self.box(1, "5", x: 0.37, width: 0.02), Self.box(2, "6", x: 0.40, width: 0.02),
    ]
    #expect(SensitiveLines(Self.ocr(lines)).ids == [0, 1, 2])
  }

  @Test func visionPhotoWithMergedFieldsAndUnlabelledCardHasAutomaticMasks() throws {
    let input = Self.fixtures.appending(path: "mask-mixed-fields.png")
    let ocr = try VisionReceiptRecognizer().recognize(input)
    let proposal = try ProposalBuilder.make(ocr)
    let masked = ocr.lines.filter { proposal.suggestedMaskLineIDs.contains($0.id) }
    #expect(masked.count >= 4)
    #expect(masked.contains { $0.text.contains("承認") })
    #expect(masked.contains { $0.sensitiveCorners != nil }, "Vision이 반환한 번호 글자 범위를 쓴다")
  }

  @Test func visionReadsAllFourSectionsOfLongReceipt() throws {
    let input = Self.fixtures.appending(path: "mask-long.png")
    let result = try VisionReceiptRecognizer().recognize(input)
    for section in 0..<4 {
      let lines = result.lines.filter { Int(($0.y + $0.height / 2) * 4) == section }
      #expect(lines.contains { $0.text.localizedCaseInsensitiveContains("TEL") }, "구간 \(section + 1)")
      #expect(lines.contains { SensitiveText($0.text).identifiers.contains { $0.contains("083912") } })
    }
  }

  @Test func visionFindsKoreanApprovalBesideReceiptDate() throws {
    let input = Self.fixtures.appending(path: "mask-korean-fields.png")
    let ocr = try VisionReceiptRecognizer().recognize(input)
    let proposal = try ProposalBuilder.make(ocr)
    let approval = try #require(ocr.lines.first { $0.text.contains("승인번호") })
    #expect(proposal.suggestedMaskLineIDs.contains(approval.id))
    #expect(approval.sensitiveCorners != nil)
  }

  @Test func rereadFindsShortResidueNearMaskAndIgnoresDistantPrice() {
    let original = Self.ocr([Self.box(0, "承認番号 0123456", x: 0.05, width: 0.30)])
    let mask = [original.lines[0].maskCorners]
    let digits = Self.box(0, "456", x: 0.25, width: 0.06)
    let price = Self.box(1, "¥3,280", x: 0.65, width: 0.15)
    #expect(
      ResidualMaskCheck.hasResidue(original: original, reread: Self.ocr([digits, price]), lineIDs: [0], polygons: mask))
    #expect(!ResidualMaskCheck.hasResidue(original: original, reread: Self.ocr([price]), lineIDs: [0], polygons: mask))
    let merged = Self.box(1, "承認番号 0123456 ¥3,280", x: 0.05, width: 0.60)
    #expect(ResidualMaskCheck.hasResidue(original: original, reread: Self.ocr([merged]), lineIDs: [0], polygons: []))
  }

  @Test func textBoxQualityFindsBlurAfterCompressionAndIgnoresDarkTable() throws {
    let file = Self.fixtures.appending(path: "mask-blur-r03.png")
    let image = try ImageLoading.cgImage(file)
    let ocr = try VisionReceiptRecognizer().recognize(file)
    let jpeg = NSMutableData()
    let encoder = try #require(CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
    #expect(CGImageDestinationFinalize(encoder))
    let encoded = try #require(CGImageSourceCreateWithData(jpeg, nil))
    let compressed = try #require(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
    #expect(MaskImageQuality(compressed, ocr: ocr)?.needsReview == true)

    let lowContrast = CIImage(cgImage: image).applyingFilter("CIColorControls", parameters: ["inputContrast": 0.14])
    let lowImage = try #require(CIContext().createCGImage(lowContrast, from: lowContrast.extent))
    let width = image.width + 480
    let height = image.height + 300
    let table = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    table.setFillColor(CGColor(gray: 0.15, alpha: 1))
    table.fill(CGRect(x: 0, y: 0, width: width, height: height))
    table.draw(lowImage, in: CGRect(x: 240, y: 150, width: image.width, height: image.height))
    let photo = try #require(table.makeImage())
    let placed = OCRResult(
      pixelWidth: width, pixelHeight: height,
      lines: ocr.lines.map { line in
        OCRLine(
          id: line.id, text: line.text, x: (240 + line.x * Double(image.width)) / Double(width),
          y: (150 + line.y * Double(image.height)) / Double(height),
          width: line.width * Double(image.width) / Double(width),
          height: line.height * Double(image.height) / Double(height))
      })
    #expect(MaskImageQuality(photo, ocr: placed)?.needsReview == true)
  }

  @Test func oldDraftDecodesAndKeepsFullWidthStripe() throws {
    let old =
      #"{"ocr":{"pixelWidth":100,"pixelHeight":200,"lines":[{"id":0,"text":"TEL 03-1234-5678","x":0.1,"y":0.1,"width":0.5,"height":0.05}]},"fields":{"date":"2026-11-08","amountMinor":100,"currency":"JPY","merchant":"a"},"suggestedMaskLineIDs":[0]}"#
    let proposal = try JSONDecoder().decode(OCRProposal.self, from: Data(old.utf8))
    #expect(proposal.needsMaskReview == nil)
    #expect(proposal.maskPolygons(lineIDs: [0], regions: []).first?.map(\.x) == [0, 1, 1, 0])
  }

  @Test func tiltedMaskHasOpaqueEdges() throws {
    let size = 24
    let canvas = try #require(
      CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    canvas.setFillColor(gray: 1, alpha: 1)
    canvas.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let image = try #require(canvas.makeImage())
    let corners = [
      CGPoint(x: 0.12, y: 0.23), CGPoint(x: 0.88, y: 0.52),
      CGPoint(x: 0.88, y: 0.73), CGPoint(x: 0.12, y: 0.44),
    ]
    let rendered = try Masking.render(image, polygons: [corners])
    let pixels = try #require(rendered.dataProvider?.data) as Data
    var rowsWithEdge = 0
    for y in 0..<size {
      let values = (0..<size).map { x in pixels[y * rendered.bytesPerRow + x * 4] }
      #expect(values.allSatisfy { $0 == 0 || $0 == 255 })
      if values.contains(0), values.contains(255) { rowsWithEdge += 1 }
    }
    #expect(rowsWithEdge > 3)
  }

  private static func ocr(_ lines: [OCRLine]) -> OCRResult {
    OCRResult(pixelWidth: 800, pixelHeight: 1200, lines: lines)
  }

  private static func box(_ id: Int, _ text: String, x: Double, width: Double) -> OCRLine {
    OCRLine(
      id: id, text: text, x: x, y: 0.5, width: width, height: 0.03,
      corners: [
        CGPoint(x: x, y: 0.5), CGPoint(x: x + width, y: 0.5),
        CGPoint(x: x + width, y: 0.53), CGPoint(x: x, y: 0.53),
      ])
  }
}
