import SwiftUI

/// 가로로 잇다가 폭이 모자라면 다음 줄로 넘기는 배치(사람 칩, 일행 줄).
struct FlowLayout: Layout {
  var spacing: CGFloat = Spacing.s
  var lineSpacing: CGFloat = Spacing.s

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    let sizes = zip(subviews, proposals(subviews, width: width)).map { $0.sizeThatFits($1) }
    return arrange(sizes, width: width).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let proposals = proposals(subviews, width: bounds.width)
    let sizes = zip(subviews, proposals).map { $0.sizeThatFits($1) }
    for (index, origin) in arrange(sizes, width: bounds.width).origins.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: proposals[index])
    }
  }

  /// 들어가는 것은 제 크기(제안 없음)로 둔다. 잰 폭을 그대로 제안하면 반올림으로 모자라 글자가 말줄임될 수 있다.
  /// 한 줄 폭보다 넓은 것만 폭을 제안해 줄바꿈시킨다.
  private func proposals(_ subviews: Subviews, width: CGFloat) -> [ProposedViewSize] {
    subviews.map { subview in
      subview.sizeThatFits(.unspecified).width <= width ? .unspecified : ProposedViewSize(width: width, height: nil)
    }
  }

  /// 줄 높이는 그 줄에서 가장 큰 것이고, 작은 것은 줄 가운데에 둔다("일행"과 이름·라벨이 한 줄로 보이게).
  func arrange(_ sizes: [CGSize], width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
    var lines: [[Int]] = []
    var x: CGFloat = 0
    for (index, size) in sizes.enumerated() {
      if lines.isEmpty || (x > 0 && x + size.width > width) {
        lines.append([])
        x = 0
      }
      lines[lines.count - 1].append(index)
      x += size.width + spacing
    }
    var origins = [CGPoint](repeating: .zero, count: sizes.count)
    var y: CGFloat = 0
    var widest: CGFloat = 0
    for line in lines {
      let lineHeight = line.map { sizes[$0].height }.max() ?? 0
      var x: CGFloat = 0
      for index in line {
        origins[index] = CGPoint(x: x, y: y + (lineHeight - sizes[index].height) / 2)
        widest = max(widest, x + sizes[index].width)
        x += sizes[index].width + spacing
      }
      y += lineHeight + lineSpacing
    }
    return (origins, CGSize(width: widest, height: lines.isEmpty ? 0 : y - lineSpacing))
  }
}
