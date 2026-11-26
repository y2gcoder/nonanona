import CoreGraphics

/// 글자 영역의 휘도로 가림 확인이 필요한 흐림과 저대비를 추정한다.
struct MaskImageQuality {
  let contrast: Int
  let edgeDetail: Double

  var needsReview: Bool { contrast < 35 || edgeDetail < 0.31 }

  init?(_ image: CGImage, ocr: OCRResult) {
    let scale = min(1, 1000 / Double(image.width))
    let width = max(1, Int(Double(image.width) * scale))
    let height = max(1, Int(Double(image.height) * scale))
    guard width > 6, height > 6,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
      let data = context.data
    else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(bounds)
    context.interpolationQuality = .medium
    context.draw(image, in: bounds)
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    let stride = context.bytesPerRow

    // 먼저 작은 가우시안 커널을 적용해 센서 잡음과 압축의 한 픽셀 경계를 줄인다.
    func smoothed(_ i: Int) -> Int {
      let top = Int(pixels[i - stride - 1]) + 2 * Int(pixels[i - stride]) + Int(pixels[i - stride + 1])
      let mid = Int(pixels[i - 1]) + 2 * Int(pixels[i]) + Int(pixels[i + 1])
      let bottom = Int(pixels[i + stride - 1]) + 2 * Int(pixels[i + stride]) + Int(pixels[i + stride + 1])
      return top + 2 * mid + bottom
    }

    var local: [(contrast: Int, edge: Double, sensitive: Bool)] = []
    for line in ocr.lines {
      let top = max(2, Int(floor(line.y * Double(height))))
      let bottom = min(height - 2, Int(ceil((line.y + line.height) * Double(height))))
      let left = max(2, Int(floor(line.x * Double(width))))
      let right = min(width - 2, Int(ceil((line.x + line.width) * Double(width))))
      guard bottom - top >= 9, right - left >= 16 else { continue }
      var histogram = Array(repeating: 0, count: 256)
      var gradient = 0
      var laplacian = 0
      for y in top..<bottom {
        for x in left..<right {
          let i = y * stride + x
          let center = smoothed(i)
          histogram[center / 16] += 1
          let east = smoothed(i + 1)
          let south = smoothed(i + stride)
          let magnitude = abs(east - center) + abs(south - center)
          guard magnitude >= 4 * 16 else { continue }
          gradient += magnitude
          laplacian += abs(east + south + smoothed(i - 1) + smoothed(i - stride) - 4 * center)
        }
      }
      let count = (bottom - top) * (right - left)
      let contrast =
        Self.percentile(histogram, rank: count * 9 / 10)
        - Self.percentile(histogram, rank: count / 10)
      let text = SensitiveText(line.text)
      local.append((contrast, Double(laplacian) / Double(max(1, gradient)), text.hasLabel || text.hasNumber))
    }
    guard !local.isEmpty else { return nil }
    let sensitive = local.filter(\.sensitive)
    let samples = sensitive.isEmpty ? local : sensitive
    contrast = samples.map(\.contrast).sorted()[samples.count / 3]
    edgeDetail = samples.map(\.edge).sorted()[samples.count / 3]
  }

  private static func percentile(_ histogram: [Int], rank: Int) -> Int {
    var count = 0
    for (value, pixels) in histogram.enumerated() {
      count += pixels
      if count > rank { return value }
    }
    return 255
  }
}
