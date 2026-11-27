import ImageIO
import ReceiptImport
import SwiftUI

/// 검토 화면에서 사용자가 바꾼 것 하나. 앱 모델이 저장된 입력(`ReviewDraft`)에 적용하고 바로 디스크에 쓴다.
enum ReviewEdit {
  case date(String)
  case amount(String)
  case currency(String)
  case merchant(String)
  case toggleLine(Int)
  case addRegion
  case moveRegion(String, by: Int)
  case resizeRegion(String, by: Int)
  case removeRegion(String)
}

/// 검토 화면이 그리는 값. 화면은 이 값과 동작만 알고, 저장·굽기는 앱 모델과 처리기가 맡는다.
struct ReceiptReviewContent {
  let item: ProcessingItem
  let photoURL: URL
  /// 기기 안에서만 쓰는 OCR 제안(읽은 줄 전체 포함). 읽지 못했거나 아직 읽는 중이면 nil.
  let proposal: OCRProposal?
  let review: ResolvedReview
  let problems: Set<FieldProblem>
  let preview: MaskPreview?
  let confirmedArtifact: Data?
  let confirmedCount: Int
  let totalCount: Int
  let readyCount: Int
  let busy: Bool
  /// 고친 입력을 디스크에 쓰지 못했다(입력은 화면·메모리에 남아 있다).
  let saveFailed: Bool
  /// 확인을 디스크에 남기지 못했다(확인되지 않았다).
  let confirmFailed: Bool
}

struct ReceiptReviewActions {
  let edit: (ReviewEdit) -> Void
  let requestPreview: () -> Void
  let retry: () -> Void
  let retrySave: () -> Void
  let confirmAndNext: () -> Void
}

/// 영수증 한 장의 검토: 기기 안 원본과 가린 사본을 비교하고, 가림(OCR 줄·직접 더한 띠)과 읽은 값을 고친 뒤
/// "확인하고 다음"으로 확인한다. 읽지 못한 사진은 이 사진만 다시 읽거나 값을 직접 입력한다.
/// 한 열로만 쌓는다(넓은 창에서는 분할 보기의 상세 열 안에 있고, 열은 시스템이 접힘을 피해 둔다).
struct ReceiptReviewView: View {
  let content: ReceiptReviewContent
  @Binding var showsMaskedPreview: Bool
  let actions: ReceiptReviewActions

  private var item: ProcessingItem { content.item }

  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: Spacing.s) {
          HStack(spacing: Spacing.s) {
            StatusLabel(item.reviewStatusText, role: item.reviewStatusRole)
              .accessibilityIdentifier("review-status")
            Text("확인 \(content.confirmedCount)/\(content.totalCount)")
              .textRole(.supporting)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("review-progress")
          }
          Text(item.reviewGuidance).textRole(.supporting)
          if item.state == .ready, let proposal = content.proposal, proposal.needsMaskReview != false {
            Text("가림이 충분한지 확실하지 않아요. 번호가 보이지 않는지 확인해 주세요.")
              .textRole(.supporting)
              .accessibilityIdentifier("review-mask-warning")
          }
        }
      }
      imageSection
      switch item.state {
      case .ready:
        maskSection
        fieldsSection(editable: true)
      case .failed:
        failedSection
        fieldsSection(editable: true)
      case .confirmed:
        fieldsSection(editable: false)
      case .queued, .processing:
        EmptyView()
      }
    }
    .adaptiveContentMargins()
    // 숫자 자판에는 닫기 키가 없다. 목록을 끌거나 자판 위 "완료"로 닫는다.
    .scrollDismissesKeyboard(.interactively)
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("완료") {
          UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .accessibilityIdentifier("keyboard-done")
      }
    }
    .navigationTitle("사진 \(item.position)")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("review-screen")
    .safeAreaInset(edge: .bottom) {
      if item.state == .ready || item.state == .failed { confirmBar }
    }
    .task(id: previewKey) {
      if showsMaskedPreview, item.state == .ready, content.preview == nil { actions.requestPreview() }
    }
  }

  private var previewKey: String {
    "\(showsMaskedPreview)-\(item.state.rawValue)-\(content.preview == nil)-\(content.proposal != nil)"
  }

  // MARK: 사진

  @ViewBuilder private var imageSection: some View {
    Section {
      if item.state == .ready {
        Picker("보기", selection: $showsMaskedPreview) {
          Text("원본").tag(false)
          Text("가린 사본").tag(true)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("review-view-mode")
      }
      Group {
        if item.state == .confirmed {
          if let data = content.confirmedArtifact, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
              .accessibilityLabel("확인한 가린 사본. 가린 곳의 글자는 읽어 주지 않아요.")
              .accessibilityIdentifier("review-confirmed-artifact")
          } else {
            Text("사진 없이 직접 입력했어요. 이 사진은 이 기기에만 있고 여행방에 올라가지 않아요.")
              .textRole(.supporting)
              .accessibilityIdentifier("review-manual-note")
          }
        } else if showsMaskedPreview, item.state == .ready {
          if let preview = content.preview, let image = UIImage(data: preview.pngData) {
            Image(uiImage: image).resizable().scaledToFit()
              .accessibilityLabel("가린 사본 미리보기, 가림 \(preview.maskCount)곳. 가린 곳의 글자는 읽어 주지 않아요.")
              .accessibilityIdentifier("review-preview")
          } else {
            ProgressView("가린 사본을 만드는 중").frame(maxWidth: .infinity, minHeight: 120)
          }
        } else {
          OriginalPhoto(
            url: content.photoURL, proposal: content.proposal,
            masked: item.state == .ready ? content.review : nil
          )
          .accessibilityElement()
          .accessibilityAddTraits(.isImage)
          .accessibilityLabel(
            item.state == .ready
              ? "원본 사진 \(item.position), 이 기기에만 있어요. 가릴 곳 \(content.review.maskCount)곳을 검은 띠로 표시했어요."
              : "원본 사진 \(item.position), 이 기기에만 있어요."
          )
          .accessibilityIdentifier("review-original")
        }
      }
      .frame(maxWidth: .infinity)
    } footer: {
      if item.state == .ready {
        Text("원본과 읽은 글자 전체는 이 기기에만 남아요. 여행방에는 확인한 가린 사본과 날짜·금액·통화·가게만 올라가요.")
          .textRole(.caption)
      }
    }
  }

  // MARK: 가림

  @ViewBuilder private var maskSection: some View {
    Section {
      Label {
        Text("자동으로 찾지 못한 정보가 있을 수 있어요. 카드·회원·예약 번호나 전화번호가 보이면 그 줄을 가리거나, 줄이 목록에 없으면 가림 영역을 더해 주세요.")
          .textRole(.supporting)
      } icon: {
        Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
      }
      .accessibilityIdentifier("mask-warning")
      if let lines = content.proposal?.ocr.lines {
        let suggested = Set(content.proposal?.suggestedMaskLineIDs ?? [])
        ForEach(lines, id: \.id) { line in
          Toggle(
            isOn: Binding(
              get: { content.review.maskLineIDs.contains(line.id) },
              set: { _ in actions.edit(.toggleLine(line.id)) })
          ) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
              Text(line.text).textRole(.body)
              if suggested.contains(line.id) {
                Text("자동 제안").textRole(.caption).foregroundStyle(.secondary)
              }
            }
          }
          .accessibilityHint("켜면 이 줄을 검은 띠로 가려요")
          .accessibilityIdentifier("mask-line-\(line.id)")
        }
      }
      ForEach(Array(content.review.regions.enumerated()), id: \.element.id) { index, region in
        RegionRow(number: index + 1, region: region, edit: actions.edit)
      }
      Button {
        actions.edit(.addRegion)
      } label: {
        Label("가림 영역 더하기", systemImage: "plus.rectangle")
      }
      .accessibilityIdentifier("mask-add-region")
    } header: {
      Text("가림 \(content.review.maskCount)곳").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
        .accessibilityIdentifier("mask-count")
    }
  }

  // MARK: 실패

  @ViewBuilder private var failedSection: some View {
    Section {
      Text(item.failureText).textRole(.body)
      Button("이 사진만 다시 읽기", action: actions.retry)
        .accessibilityIdentifier("review-retry")
      Text("다시 읽어도 안 되면 아래에 값을 직접 입력해 주세요. 직접 입력한 값만 저장하고, 이 사진은 이 기기에만 남아 여행방에 올라가지 않아요.")
        .textRole(.supporting)
        .foregroundStyle(.secondary)
    } header: {
      Text("읽지 못했어요").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
    }
  }

  // MARK: 값

  @ViewBuilder private func fieldsSection(editable: Bool) -> some View {
    Section {
      if editable {
        FieldRow(
          label: "가게", text: content.review.merchant, problem: problem(.merchant), id: "review-merchant",
          keyboard: .default
        ) { actions.edit(.merchant($0)) }
        FieldRow(
          label: "날짜(예: 2026-11-03 또는 20261103)", text: content.review.date, problem: problem(.date), id: "review-date",
          keyboard: .numbersAndPunctuation
        ) { actions.edit(.date($0)) }
        FieldRow(
          label: "금액", text: content.review.amount, problem: problem(.amount), id: "review-amount",
          keyboard: .decimalPad
        ) { actions.edit(.amount($0)) }
        if content.proposal?.needsTotalReview == true {
          Text("기울어진 사진에서 찾은 합계예요. 원본의 합계와 비교해 주세요.")
            .textRole(.caption).foregroundStyle(.secondary)
        }
        Picker(
          "통화",
          selection: Binding(get: { content.review.currency }, set: { actions.edit(.currency($0)) })
        ) {
          ForEach(ReviewForm.currencies, id: \.code) { Text($0.code).tag($0.code) }
        }
        .accessibilityIdentifier("review-currency")
      } else if let fields = item.confirmed?.fields {
        LabeledContent("가게", value: fields.merchant ?? "없음")
        LabeledContent("날짜", value: fields.date)
        LabeledContent(
          "금액",
          value: "\(ReviewForm.amountText(minor: fields.amountMinor, currency: fields.currency)) \(fields.currency)"
        )
        .accessibilityIdentifier("review-confirmed-amount")
      }
    } header: {
      Text(editable && item.state == .failed ? "직접 입력" : "읽어 낸 값")
        .textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
    } footer: {
      if editable {
        Text("통화는 영수증에 적힌 통화예요. 원화 금액은 여행방에서 방장이 확인해요.").textRole(.caption)
      }
    }
  }

  private func problem(_ field: FieldProblem) -> String? {
    guard content.problems.contains(field) else { return nil }
    return switch field {
    case .date: "날짜를 2026-11-03처럼 입력해 주세요."
    case .amount: "금액을 0보다 큰 숫자로 입력해 주세요."
    case .currency: "통화를 골라 주세요."
    case .merchant: "가게 이름은 80자까지, 한 줄로 입력해 주세요."
    }
  }

  // MARK: 확인

  private var confirmBar: some View {
    VStack(spacing: Spacing.s) {
      if content.confirmFailed {
        Text("확인을 저장하지 못했어요. 아직 확인되지 않았고 입력은 그대로예요. 다시 눌러 주세요.")
          .textRole(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("review-confirm-error")
      }
      if content.saveFailed {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
          Text("입력을 기기에 저장하지 못했어요. 화면의 입력은 그대로예요.")
            .textRole(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("review-save-error")
          Button("다시 저장", action: actions.retrySave).buttonStyle(.bordered)
            .accessibilityIdentifier("review-save-retry")
        }
      }
      Group {
        if !content.problems.isEmpty {
          Text("확인하려면 위에서 표시한 값을 고쳐 주세요.").foregroundStyle(.red)
        } else if item.state == .failed {
          Text("확인하면 직접 입력한 값만 저장해요.")
        } else {
          Text("확인하면 가린 사본을 만들어요. 원본은 이 기기에만 남아요.")
        }
      }
      .textRole(.caption)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("review-confirm-hint")
      Button("확인하고 다음", action: actions.confirmAndNext)
        .buttonStyle(.primaryAction)
        .disabled(!content.problems.isEmpty || content.busy)
        .accessibilityHint(
          content.readyCount > 1 || (content.readyCount == 1 && item.state != .ready)
            ? "확인한 뒤 다음 영수증을 열어요" : "확인한 뒤 목록으로 돌아가요"
        )
        .accessibilityIdentifier("review-confirm-next")
    }
    .padding(.horizontal, Spacing.m)
    .padding(.vertical, Spacing.s)
    .background(.bar)
  }
}

/// 직접 더한 가림 띠 한 개. 끌기 대신 버튼과 VoiceOver 조절(위·아래로 쓸기)로 옮기고 크기를 바꾼다.
private struct RegionRow: View {
  let number: Int
  let region: MaskRegion
  let edit: (ReviewEdit) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.s) {
      Text("직접 더한 영역 \(number) · 위에서 \(region.topPercent)–\(region.bottomPercent)%")
        .textRole(.body)
        .accessibilityLabel("직접 더한 영역 \(number)")
        .accessibilityValue("사진 위에서 \(region.topPercent)퍼센트부터 \(region.bottomPercent)퍼센트까지")
        .accessibilityAdjustableAction { direction in
          switch direction {
          case .increment: edit(.moveRegion(region.id, by: MaskRegion.moveStep))
          case .decrement: edit(.moveRegion(region.id, by: -MaskRegion.moveStep))
          @unknown default: break
          }
        }
        .accessibilityIdentifier("region-\(number)-value")
      ViewThatFits(in: .horizontal) {
        HStack(spacing: Spacing.s) { buttons }
        VStack(alignment: .leading, spacing: Spacing.s) { buttons }
      }
      // 목록 행 안의 여러 버튼은 스타일이 있어야 각자 눌린다(없으면 한 번 누르면 행의 버튼이 모두 동작해 "삭제"까지 불린다).
      .buttonStyle(.bordered)
    }
    .padding(.vertical, Spacing.xs)
  }

  @ViewBuilder private var buttons: some View {
    Button("위로") { edit(.moveRegion(region.id, by: -MaskRegion.moveStep)) }
      .accessibilityLabel("영역 \(number) 위로")
      .accessibilityIdentifier("region-\(number)-up")
    Button("아래로") { edit(.moveRegion(region.id, by: MaskRegion.moveStep)) }
      .accessibilityLabel("영역 \(number) 아래로")
      .accessibilityIdentifier("region-\(number)-down")
    Button("넓게") { edit(.resizeRegion(region.id, by: MaskRegion.resizeStep)) }
      .accessibilityLabel("영역 \(number) 넓게")
      .accessibilityIdentifier("region-\(number)-grow")
    Button("좁게") { edit(.resizeRegion(region.id, by: -MaskRegion.resizeStep)) }
      .accessibilityLabel("영역 \(number) 좁게")
      .accessibilityIdentifier("region-\(number)-shrink")
    Button("삭제", role: .destructive) { edit(.removeRegion(region.id)) }
      .accessibilityLabel("영역 \(number) 삭제")
      .accessibilityIdentifier("region-\(number)-remove")
  }
}

/// 이름표를 위에 둔 입력 칸. 큰 글자에서도 이름표와 값이 한 줄에 갇히지 않는다.
private struct FieldRow: View {
  let label: String
  let text: String
  let problem: String?
  let id: String
  let keyboard: UIKeyboardType
  let onChange: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label).textRole(.supporting).foregroundStyle(.secondary).accessibilityHidden(true)
      TextField(label, text: Binding(get: { text }, set: { onChange($0) }))
        .keyboardType(keyboard)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
      if let problem {
        Text(problem).textRole(.caption).foregroundStyle(.red).accessibilityIdentifier("\(id)-problem")
      }
    }
    .padding(.vertical, Spacing.xs)
  }
}

/// 기기 안 원본. 확인 전에는 가릴 곳(고른 줄·더한 띠)을 반투명 검은 띠로 겹쳐 보여 준다(사본은 확인 때 따로 굽는다).
private struct OriginalPhoto: View {
  let url: URL
  let proposal: OCRProposal?
  let masked: ResolvedReview?
  @State private var image: UIImage?

  var body: some View {
    Color(uiColor: .tertiarySystemFill)
      .aspectRatio(aspect, contentMode: .fit)
      .overlay {
        if let image { Image(uiImage: image).resizable().scaledToFit() }
      }
      .overlay {
        // 굽는 사본과 같은 순서로 칠한다: 검정 → 보존 상자 되돌림(지움) → 민감 상자·사용자가 켠 줄·더한 띠 검정.
        // 캔버스 한 장 안에서 지우므로 사진은 그대로이고, 겹친 곳도 한 번만 칠한 것처럼 보인다.
        Canvas { context, size in
          func path(_ polygon: [CGPoint]) -> Path {
            Path { path in
              path.addLines(polygon.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
              path.closeSubpath()
            }
          }
          guard let plan else { return }
          for polygon in plan.black { context.fill(path(polygon), with: .color(.black)) }
          var restore = context
          restore.blendMode = .clear
          for polygon in plan.restore { restore.fill(path(polygon), with: .color(.black)) }
          for polygon in plan.cover { context.fill(path(polygon), with: .color(.black)) }
        }
        .opacity(0.55)
        .clipped()
      }
      .task(id: url) { image = await Self.load(url) }
  }

  private var aspect: CGFloat {
    guard let proposal, proposal.ocr.pixelHeight > 0 else { return 0.75 }
    return CGFloat(proposal.ocr.pixelWidth) / CGFloat(proposal.ocr.pixelHeight)
  }

  private var plan: MaskPlan? {
    guard let masked, let proposal else { return nil }
    return proposal.maskPlan(lineIDs: masked.maskLineIDs, regions: masked.regions)
  }

  private static func load(_ url: URL) async -> UIImage? {
    await Task.detached(priority: .userInitiated) {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 1_600,
      ]
      return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
    }.value
  }
}

extension ProcessingItem {
  var reviewStatusText: String {
    switch state {
    case .queued: "대기 중"
    case .processing: "읽는 중"
    case .ready: "확인 필요"
    case .failed: "읽지 못함"
    case .confirmed: confirmed?.isManualEntry == true ? "확인함 · 직접 입력" : "확인함"
    }
  }

  var reviewStatusRole: StatusRole {
    switch state {
    case .queued, .processing: .neutral
    case .ready: .attention
    case .failed: .error
    case .confirmed: .positive
    }
  }

  var reviewGuidance: String {
    switch state {
    case .queued: "순서를 기다리고 있어요. 다 읽으면 여기서 확인할 수 있어요."
    case .processing: attempts > 1 ? "사진 \(position)을 다시 읽고 있어요." : "사진 \(position)을 이 기기에서 읽고 있어요."
    case .ready: "원본과 비교해 가림과 값을 확인해 주세요."
    case .failed: "이 사진의 글자를 읽지 못했어요."
    case .confirmed: "확인했어요. 확인한 뒤에는 고칠 수 없어요."
    }
  }

  var failureText: String {
    switch failure {
    case .unreadable: "글자를 읽지 못했어요. 초점이 맞지 않았을 수 있어요."
    case .missingTotal: "합계 금액을 찾지 못했어요."
    case .missingDate: "날짜를 찾지 못했어요."
    case .invalidImage: "이미지를 열 수 없어요."
    case .recognitionError, nil: "읽는 중 문제가 생겼어요."
    }
  }
}
