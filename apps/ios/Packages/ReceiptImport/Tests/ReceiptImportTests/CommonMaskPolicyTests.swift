import CoreGraphics
import Foundation
import Testing

@testable import ReceiptImport

struct CommonMaskPolicyTests {
  private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "fixtures/masking/common-policy.json")

  @Test func sharedContract() throws {
    let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: Self.fixture))
    #expect(table.version == 1)
    let failures = Set(try table.cases.flatMap { try check($0, in: table) })
    #expect(failures.isEmpty, "Failures: \(failures.sorted())")
  }

  private func check(_ entry: MaskCase, in table: Table) throws -> [String] {
    let size = entry.size ?? table.size
    let ocr: OCRResult
    if let tiles = entry.tiles {
      let merged = OCRTile.merge(
        tiles.map { tile in
          OCRTile(top: tile.top, height: tile.height, lines: readLines(tile.lines, size: [size[0], tile.height]).lines)
        }, imageHeight: size[1])
      #expect(merged.count == entry.lines.count, "\(entry.id)")
      let header = readLines(table.header, size: size).lines
      let lines = (header + merged).enumerated().map { id, line in
        OCRLine(
          id: id, text: line.text, x: line.x, y: line.y, width: line.width,
          height: line.height, corners: line.corners, sensitiveCorners: line.sensitiveCorners)
      }
      ocr = OCRResult(pixelWidth: size[0], pixelHeight: size[1], lines: lines)
    } else {
      ocr = readLines(table.header + entry.lines, size: size)
    }
    let proposal = try ProposalBuilder.make(ocr)
    let ids = Set(proposal.suggestedMaskLineIDs)
    // `select`: 검토 화면에서 사용자가 추천 밖에서 더 켠 줄(글자로 찾는다). 사용자 띠는 더하지 않는다.
    let userLines = (entry.select ?? []).map { text in ocr.lines.first { $0.text == text }!.id }
    let plan = proposal.maskPlan(lineIDs: ids.union(userLines), regions: [])
    let polygons = plan.drawn

    var doubts: Set<String> = []
    if proposal.needsMaskReview == true {
      // iOS exposes a combined reason. These inputs isolate an unpaired label or a mixed line.
      let missingRange = ocr.lines.contains {
        ids.contains($0.id) && $0.sensitiveCorners == nil && SensitiveText($0.text).isMixed
      }
      let selection = SensitiveLines(ocr)
      if selection.unmatchedLabel {
        doubts.insert(missingRange ? "mixedLine" : "unpairedLabel")
      }
      if selection.isTilted { doubts.insert("skew") }
    } else if let reread = entry.reread,
      ResidualMaskCheck.hasResidue(
        original: ocr, reread: readLines(reread, size: size), lineIDs: ids, polygons: polygons)
    {
      doubts.insert("reread")
    }

    let expected = entry.expect
    #expect(expected.needsReview == !expected.reasons.isEmpty, "\(entry.id)")
    var failures: [String] = []
    for (kind, regions, masked) in [("masked", expected.masked, true), ("visible", expected.visible, false)] {
      for (name, box) in regions {
        let wrongPixel = (box[1]..<box[3]).contains { y in
          (box[0]..<box[2]).contains { x in
            let point = CGPoint(x: (Double(x) + 0.5) / Double(size[0]), y: (Double(y) + 0.5) / Double(size[1]))
            return plan.covers(point) != masked
          }
        }
        if wrongPixel { failures.append("\(entry.id):\(kind).\(name)") }
      }
    }
    failures += expected.reasons.subtracting(doubts).map { "\(entry.id):missing.\($0)" }
    failures += doubts.subtracting(expected.reasons).map { "\(entry.id):unexpected.\($0)" }
    return failures
  }

  private func readLines(_ lines: [Line], size: [Int]) -> OCRResult {
    func corners(_ box: [Int]) -> [CGPoint] {
      let l = Double(box[0]) / Double(size[0])
      let t = Double(box[1]) / Double(size[1])
      let r = Double(box[2]) / Double(size[0])
      let b = Double(box[3]) / Double(size[1])
      return [CGPoint(x: l, y: t), CGPoint(x: r, y: t), CGPoint(x: r, y: b), CGPoint(x: l, y: b)]
    }
    return OCRResult(
      pixelWidth: size[0], pixelHeight: size[1],
      lines: lines.enumerated().map { id, line in
        let q = corners(line.box)
        return OCRLine(
          id: id, text: line.text, x: q[0].x, y: q[0].y, width: q[2].x - q[0].x, height: q[2].y - q[0].y,
          corners: line.corners?.map { point in
            CGPoint(x: Double(point[0]) / Double(size[0]), y: Double(point[1]) / Double(size[1]))
          } ?? q, sensitiveCorners: line.numberBox.map(corners))
      })
  }

  private struct Table: Decodable {
    let version: Int
    let size: [Int]
    let header: [Line]
    let cases: [MaskCase]
  }

  private struct Line: Decodable {
    let text: String
    let box: [Int]
    let numberBox: [Int]?
    let corners: [[Int]]?
  }

  private struct Expectation: Decodable {
    let masked: [String: [Int]]
    let visible: [String: [Int]]
    let needsReview: Bool
    let reasons: Set<String>
  }

  private struct MaskCase: Decodable {
    let id: String
    let size: [Int]?
    let lines: [Line]
    let reread: [Line]?
    let tiles: [Tile]?
    let select: [String]?
    let expect: Expectation
  }

  private struct Tile: Decodable {
    let top: Int
    let height: Int
    let lines: [Line]
  }
}
