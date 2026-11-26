import ReceiptImport
import SwiftUI

#if canImport(Translation)
  import Translation
#endif

/// 품목별 나누기에서 고를 수 있는 사람(여행방 구성원). 표시 이름과 서버 ID만 받는다.
struct ItemSplitPerson: Hashable {
  let id: String
  let name: String
}

/// 품목별 나누기 화면에 그릴 값. 계획과 계산 결과는 앱 모델이 만든다.
struct ItemSplitContent {
  let plan: ItemPlan?
  let people: [ItemSplitPerson]
  /// 방장이 지출 검토에서 정한 원화(엔화 영수증). 없으면 몫을 계산하지 않는다.
  let krw: Int?
  let allocation: Result<ItemAllocation, ItemAllocationProblem>?
  let translation: ItemTranslationState?
  let translatorLabel: String
  let translatorIsPreview: Bool
  let saveFailed: Bool
  /// 저장한 계획을 열지 못했다(통화를 받지 않는 경우와 다르다). 계획 파일은 그대로 있다.
  let loadFailure: ItemPlanLoadFailure?
  /// 올린 사람(회원)의 제안 화면이면 값이 있다(ADR-0011). nil이면 방장 검토(직접 나누기에 채우기).
  var proposal: ItemProposalPanel? = nil
  /// 품목명 다시 번역 단추를 보일지(debug 미리보기 대역이 있을 때).
  var canRetranslate = false
  /// 그 영수증에 남긴 재번역 기록을 다 읽어 새로 시작할 수 있는지. 읽는 동안·읽지 못했으면 단추를 막는다.
  var retranslationReady = false
  /// 남긴 재번역 기록을 읽지 못했다(파일은 그대로). 다시 불러오기를 둔다.
  var retranslationLoadFailed = false
  /// 열려 있는 품목명 다시 번역(앱 모델이 가진다). 있으면 시트가 뜬다.
  var retranslation: ItemRetranslationSession? = nil
}

/// 제안 화면에 그릴 값: 묶을 원화 기준, 남은 원을 낼 사람, 보낼 요청(전부), 장부의 가장 최근 제안과 보내기 상태.
struct ItemProposalPanel {
  let basis: ProposalBasis
  let remainderChoice: String?
  let request: ShareProposalRequest?
  let sent: ShareProposal?
  let sendState: ProposalSendState?
  /// 확인 창을 연 뒤 보낼 값이 바뀌어 보내지 않았다(다시 확인해야 보낸다).
  var consentChanged = false
}

struct ItemSplitActions {
  let edit: ((inout ItemPlan) -> Void) -> Void
  let retrySave: () -> Void
  let retryLoad: () -> Void
  let translate: () -> Void
  let recheckTranslation: () -> Void
  let apply: () -> Void
  var chooseRemainder: (String) -> Void = { _ in }
  var propose: () -> Void = {}
  var beginRetranslation: ([ItemPlanLine]) -> Void = { _ in }
  var retryRetranslationLoad: () -> Void = {}
  var retranslation = ItemRetranslationActions(
    toggle: { _ in }, confirm: {}, retry: {}, accept: { _, _ in }, close: {})
}

/// 영수증 품목으로 사람마다 몫을 계산해 지출 검토의 "직접 나누기"에 채운다. 품목 이름·OCR 글자는 이 기기에만 있고,
/// 여행방에는 방장이 검토에서 "포함하기"를 누를 때 사람마다 원 단위 몫만 간다(지금 직접 나누기와 같은 값).
struct ItemSplitView: View {
  let content: ItemSplitContent
  let actions: ItemSplitActions

  @State private var downloadRequested = false

  var body: some View {
    List {
      Section {
        Text(
          content.proposal == nil
            ? "품목 이름과 영수증 글자는 이 기기에만 있어요. 여행방에는 사람마다 부담 금액(원)만 \"직접 나누기\"로 올라가요."
            : "품목 이름과 영수증 글자는 이 기기에만 있어요. 방장에게는 사람마다 부담 금액(원)만 제안으로 가고, 방장이 확인해야 정산에 들어가요."
        )
        .textRole(.supporting).foregroundStyle(.secondary)
        .accessibilityIdentifier("items-privacy")
      }
      if let plan = content.plan {
        translationSection
        linesSection(plan)
        addSection
        summarySection(plan)
        if let proposal = content.proposal {
          proposalSection(plan, proposal)
        } else {
          resultSection(plan)
        }
      } else if let failure = content.loadFailure {
        Section {
          Text(Self.loadFailureMessage(failure))
            .textRole(.body).accessibilityIdentifier("items-load-failed")
          Button("다시 불러오기", action: actions.retryLoad).accessibilityIdentifier("items-load-retry")
        }
      } else {
        Section {
          Text("이 영수증의 통화는 아직 품목별로 나눌 수 없어요. 지출 검토에서 직접 나눠 주세요.")
            .textRole(.body).accessibilityIdentifier("items-unsupported")
        }
      }
    }
    .itemRetranslationSheet(content.retranslation, actions.retranslation)
    .modifier(TranslationDownload(requested: $downloadRequested, onFinished: actions.recheckTranslation))
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("완료") {
          UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .accessibilityIdentifier("keyboard-done")
      }
    }
    .adaptiveContentMargins()
    .navigationTitle("품목별로 나누기")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("item-split-screen")
  }

  static func loadFailureMessage(_ failure: ItemPlanLoadFailure) -> String {
    switch failure {
    case .unreadable:
      return "저장한 품목 계획을 이 기기에서 읽지 못했어요. 계획은 지우거나 바꾸지 않았어요. 다시 불러와 주세요."
    case .invalid:
      return "저장한 품목 계획이 손상됐거나 이 영수증과 맞지 않아 열 수 없어요. 계획은 지우거나 바꾸지 않았어요. 지출 검토에서 직접 나눌 수 있어요."
    }
  }

  // MARK: 번역

  @ViewBuilder private var translationSection: some View {
    Section {
      Text(translationStatus).textRole(.supporting).accessibilityIdentifier("items-translation-status")
      switch content.translation {
      case .available(.ready), .translated, .failed:
        Button(content.translation == .failed ? "다시 번역하기" : "이름 번역하기", action: actions.translate)
          .accessibilityIdentifier("items-translate")
      case .available(.needsDownload):
        Button("일본어·한국어 번역 언어 받기") { downloadRequested = true }
          .accessibilityIdentifier("items-translation-download")
      case .available(.unsupported), .checking, .translating, nil:
        EmptyView()
      }
    } header: {
      Text("한국어 이름").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
    } footer: {
      Text(
        content.translatorIsPreview
          ? "미리보기 대역은 정해 둔 사전이에요. 실제 기계 번역이 아니에요."
          : "번역은 이 기기 안에서만 해요. 번역한 이름은 제안이라 고칠 수 있어요."
      )
      .textRole(.caption)
    }
  }

  private var translationStatus: String {
    let name = content.translatorLabel
    switch content.translation {
    case .checking, nil: return "\(name) 확인 중…"
    case .available(.ready): return "\(name)을 쓸 수 있어요."
    case .available(.needsDownload): return "\(name)을 쓰려면 일본어·한국어 언어를 이 기기에 받아야 해요."
    case .available(.unsupported): return "이 기기에서는 일본어→한국어 기기 번역을 쓸 수 없어요. 이름을 직접 적어 주세요."
    case .translating: return "번역하는 중…"
    case .translated(let count): return "\(count)개 이름을 채웠어요(\(name)). 직접 적은 이름은 바꾸지 않았어요."
    case .failed: return "번역하지 못했어요. 다시 시도하거나 이름을 직접 적어 주세요."
    }
  }

  // MARK: 줄

  @ViewBuilder private func linesSection(_ plan: ItemPlan) -> some View {
    Section {
      if content.saveFailed {
        HStack {
          Text("품목을 기기에 저장하지 못했어요.").textRole(.supporting).foregroundStyle(.red)
          Spacer()
          Button("다시 저장", action: actions.retrySave).accessibilityIdentifier("items-retry-save")
        }
      }
      if plan.lines.isEmpty {
        Text("영수증에서 품목을 찾지 못했어요. 아래에서 품목을 직접 더해 주세요.")
          .textRole(.supporting).accessibilityIdentifier("items-empty")
      }
      if content.canRetranslate {
        if content.retranslationLoadFailed {
          Text("저장한 번역 결과를 이 기기에서 읽지 못했어요. 결과는 지우거나 바꾸지 않았어요. 다시 불러와 주세요.")
            .textRole(.supporting).accessibilityIdentifier("items-retranslation-load-failed")
          Button("다시 불러오기", action: actions.retryRetranslationLoad)
            .accessibilityIdentifier("items-retranslation-load-retry")
        }
        let available = plan.retranslatableLines
        if available.count > 1 {
          Button("여러 품목 다시 번역") { actions.beginRetranslation(available) }
            .disabled(!content.retranslationReady)
            .accessibilityIdentifier("items-retranslate-batch")
        }
      }
      ForEach(plan.lines) { line in
        ItemLineRow(line: line, currency: plan.currency, people: content.people, edit: actions.edit)
        if content.canRetranslate, !line.originalName.isEmpty, !line.excluded {
          Button("이 항목 다시 번역") { actions.beginRetranslation([line]) }
            .disabled(!content.retranslationReady)
            .accessibilityIdentifier("item-\(line.id)-retranslate")
        }
      }
    } header: {
      Text("품목").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
    } footer: {
      Text("여러 사람을 고르면 그 줄을 똑같이 나눠요. 세금·할인은 저절로 나누지 않아요. 필요하면 조정 줄을 더해 누가 낼지 정해 주세요.")
        .textRole(.caption)
    }
  }

  private var addSection: some View {
    Section {
      Button("품목 더하기") { actions.edit { $0.addLine(kind: .item, name: "", amountText: "") } }
        .accessibilityIdentifier("items-add-item")
      Button("조정 줄 더하기(세금·수수료·할인)") {
        actions.edit { $0.addLine(kind: .adjustment, name: "", amountText: "") }
      }
      .accessibilityIdentifier("items-add-adjustment")
    }
  }

  @ViewBuilder private func summarySection(_ plan: ItemPlan) -> some View {
    Section {
      ForEach(plan.summary) { line in
        LabeledContent(Self.summaryLabel(line.kind)) {
          Text(line.amountMinor.map { Won.original($0, plan.currency) } ?? "읽지 못함")
        }
        .accessibilityIdentifier("items-summary-\(line.id)")
      }
      LabeledContent("줄 합계", value: Won.original(plan.linesTotal, plan.currency))
        .accessibilityIdentifier("items-lines-total")
      LabeledContent("영수증 합계(확인한 값)", value: Won.original(plan.receiptTotalMinor, plan.currency))
      if plan.difference != 0 {
        Text(
          "차이 \(Won.original(plan.difference, plan.currency)) — 세금·할인·빠진 품목 때문일 수 있어요. 금액을 고치거나 조정 줄을 더해 주세요."
        )
        .textRole(.supporting).foregroundStyle(.orange).accessibilityIdentifier("items-difference")
      }
      if let ocr = plan.ocrTotalMinor, ocr != plan.receiptTotalMinor {
        Text("영수증에서 읽은 합계(\(Won.original(ocr, plan.currency)))가 확인한 합계와 달라요.")
          .textRole(.supporting).foregroundStyle(.orange)
      }
    } header: {
      Text("영수증 요약(나누지 않음)").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
    }
  }

  static func summaryLabel(_ kind: SummaryKind) -> String {
    switch kind {
    case .subtotal: "소계"
    case .tax: "세금"
    case .total: "합계"
    case .payment: "결제·거스름"
    case .discount: "할인"
    }
  }

  // MARK: 결과

  @ViewBuilder private func resultSection(_ plan: ItemPlan) -> some View {
    Section {
      if plan.currency != "KRW" {
        Text(content.krw.map { "정산 원화 \(Won.text($0))(지출 검토에서 정한 값)을 줄 몫의 비율로 나눠요." } ?? "지출 검토에서 원화를 먼저 정해 주세요.")
          .textRole(.supporting)
      }
      switch content.allocation {
      case .success(let allocation)?:
        allocationRows(allocation)
        Button("직접 나누기에 채우기", action: actions.apply)
          .buttonStyle(.primaryAction)
          .accessibilityIdentifier("items-apply")
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
      case .failure(let problem)?:
        Text(Self.message(problem, plan: plan, people: content.people))
          .textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier("items-problem")
      case nil:
        EmptyView()
      }
    } header: {
      Text("사람마다 부담").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
    } footer: {
      Text("채우기는 서버에 보내지 않아요. 지출 검토에서 확인하고 \"포함하기\"를 눌러야 여행방에 저장돼요.").textRole(.caption)
    }
  }

  // MARK: 제안(올린 사람)

  @ViewBuilder private func proposalSection(_ plan: ItemPlan, _ proposal: ItemProposalPanel) -> some View {
    Section {
      Text(ShareProposalText.basis(proposal.basis))
        .textRole(.supporting).accessibilityIdentifier("items-proposal-basis")
      if case .ready = proposal.basis {
        switch content.allocation {
        case .success(let allocation)?:
          switch allocation {
          case .exact(let shares), .pairRule(let shares):
            shareRows(shares)
          case .remainder(let floors, let remaining):
            shareRows(floors)
            Text("원 단위로 나눠떨어지지 않아 \(Won.text(remaining))이 남아요. 남은 원을 낼 사람을 골라 주세요. 저절로 정하지 않아요.")
              .textRole(.supporting).foregroundStyle(.orange).accessibilityIdentifier("items-remainder")
            ForEach(Array(floors.enumerated()), id: \.element.member) { index, share in
              Button {
                actions.chooseRemainder(share.member)
              } label: {
                HStack {
                  Text("\(name(share.member))이(가) \(Won.text(remaining)) 더 내기")
                  Spacer()
                  if proposal.remainderChoice == share.member { Image(systemName: "checkmark") }
                }
              }
              .accessibilityIdentifier("items-remainder-\(index + 1)")
              .accessibilityAddTraits(proposal.remainderChoice == share.member ? .isSelected : [])
            }
          }
          if let request = proposal.request {
            Text(
              "보낼 몫: " + request.shares.map { "\(name($0.member.value)) \(Won.text($0.krw))" }.joined(separator: " · ")
            )
            .textRole(.supporting).accessibilityIdentifier("items-proposal-preview")
          }
          Button(proposal.sendState == .sending ? "보내는 중…" : "방장에게 제안 보내기", action: actions.propose)
            .buttonStyle(.primaryAction)
            .disabled(proposal.request == nil || proposal.sendState == .sending)
            .accessibilityIdentifier("items-propose")
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        case .failure(let problem)?:
          Text(Self.message(problem, plan: plan, people: content.people))
            .textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier("items-problem")
        case nil:
          EmptyView()
        }
      }
      if proposal.consentChanged {
        Text("확인 창을 연 뒤 지출이나 원화 기준이 바뀌어 보내지 않았어요. 바뀐 값을 확인하고 다시 보내 주세요.")
          .textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier("items-proposal-consent-changed")
      }
      switch proposal.sendState {
      case .sent?:
        Text("제안을 보냈어요. 방장이 확인하고 포함해야 정산에 들어가요.")
          .textRole(.supporting).accessibilityIdentifier("items-proposal-sent")
      case .failed(let failure)?:
        Text(failure.message).textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier(
          "items-proposal-failed")
      case .sending?, nil:
        EmptyView()
      }
      if let sent = proposal.sent {
        Text(ShareProposalText.uploaderState(sent.state))
          .textRole(.supporting).accessibilityIdentifier("items-proposal-state")
      }
    } header: {
      Text("방장에게 제안").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
    } footer: {
      Text("보내는 값: 사람마다 금액(원), 원화 기준과 합계, 지출 버전. 품목 이름·품목 금액·영수증 글자·사진은 보내지 않아요.")
        .textRole(.caption)
    }
  }

  private func name(_ member: String) -> String {
    content.people.first { $0.id == member }?.name ?? "알 수 없는 구성원"
  }

  @ViewBuilder private func allocationRows(_ allocation: ItemAllocation) -> some View {
    switch allocation {
    case .exact(let shares), .pairRule(let shares):
      shareRows(shares)
      if case .pairRule = allocation {
        Text("두 사람 몫이 같아 남는 1원은 결제자가 더 부담해요(둘이 반씩과 같은 규칙).")
          .textRole(.supporting).accessibilityIdentifier("items-pair-rule")
      }
    case .remainder(let floors, let remaining):
      shareRows(floors)
      Text("원 단위로 나눠떨어지지 않아 \(Won.text(remaining))이 남아요. 채운 뒤 \"직접 나누기\"에서 누가 낼지 정해 주세요.")
        .textRole(.supporting).foregroundStyle(.orange).accessibilityIdentifier("items-remainder")
    }
  }

  private func shareRows(_ shares: [ItemMemberShare]) -> some View {
    ForEach(Array(shares.enumerated()), id: \.element.member) { index, share in
      LabeledContent(content.people.first { $0.id == share.member }?.name ?? "알 수 없는 구성원", value: Won.text(share.krw))
        .accessibilityIdentifier("items-share-\(index + 1)")
    }
  }

  static func message(_ problem: ItemAllocationProblem, plan: ItemPlan, people: [ItemSplitPerson]) -> String {
    func lineName(_ id: String) -> String {
      guard let line = plan.line(id) else { return "줄" }
      if !line.name.isEmpty { return "'\(line.name)'" }
      if !line.originalName.isEmpty { return "'\(line.originalName)'" }
      return line.kind == .adjustment ? "조정 줄" : "품목"
    }
    switch problem {
    case .noLines: return "나눌 줄이 없어요. 품목을 더해 주세요."
    case .unsupportedCurrency: return "이 통화는 아직 품목별로 나눌 수 없어요."
    case .amountInvalid(let id): return "\(lineName(id)) 금액을 숫자로 적어 주세요."
    case .needsCheck(let id): return "\(lineName(id))은(는) 확인이 필요해요. 값을 고치거나 \"확인함\"을 눌러 주세요."
    case .unassigned(let id): return "\(lineName(id))을(를) 낼 사람을 골라 주세요."
    case .totalMismatch(let difference):
      return "줄 합계가 영수증 합계와 \(Won.original(difference, plan.currency)) 달라요. 저절로 나누지 않아요."
    case .krwMissing: return "지출 검토에서 원화를 먼저 정해 주세요."
    case .nonPositiveShare(let member):
      return "\(people.first { $0.id == member }?.name ?? "한 사람")의 몫이 0원 이하예요. 할인 줄을 다른 사람에게도 나눠 주세요."
    case .tooLarge: return "나누는 사람 조합이 너무 많아 계산할 수 없어요. 직접 나눠 주세요."
    }
  }
}

/// 한 줄: 영수증 원문, 한국어 이름, 금액, 확인 표시, 낼 사람.
private struct ItemLineRow: View {
  let line: ItemPlanLine
  let currency: String
  let people: [ItemSplitPerson]
  let edit: ((inout ItemPlan) -> Void) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.s) {
      Text(
        line.originalText.isEmpty ? (line.kind == .adjustment ? "직접 더한 조정 줄" : "직접 더한 품목") : "원문: \(line.originalText)"
      )
      .textRole(.caption).foregroundStyle(.secondary)
      .accessibilityIdentifier("item-\(line.id)-original")
      TextField(
        line.kind == .adjustment ? "이름(예: 소비세, 할인)" : "한국어 이름",
        text: Binding(get: { line.name }, set: { text in edit { $0.setName(line.id, text) } })
      )
      .accessibilityIdentifier("item-\(line.id)-name")
      if let source = sourceLabel {
        Text(source).textRole(.caption).foregroundStyle(.secondary).accessibilityIdentifier("item-\(line.id)-source")
      }
      LabeledContent(line.kind == .adjustment ? "금액(\(currency), 할인은 -)" : "금액(\(currency))") {
        TextField("0", text: Binding(get: { line.amountText }, set: { text in edit { $0.setAmount(line.id, text) } }))
          .keyboardType(line.kind == .adjustment ? .numbersAndPunctuation : .numberPad)
          .multilineTextAlignment(.trailing)
          .accessibilityIdentifier("item-\(line.id)-amount")
      }
      if line.needsCheck {
        HStack {
          Text(line.flags.map(Self.flagText).joined(separator: " ")).textRole(.supporting).foregroundStyle(.orange)
          Spacer()
          Button("확인함") { edit { $0.markChecked(line.id) } }
            .buttonStyle(.bordered).accessibilityIdentifier("item-\(line.id)-check")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("item-\(line.id)-flags")
      }
      if !line.excluded {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack {
            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
              Toggle(
                person.name,
                isOn: Binding(
                  get: { line.assignees.contains(person.id) },
                  set: { on in edit { $0.setAssignee(line.id, member: person.id, on: on) } })
              )
              .toggleStyle(.button)
              .accessibilityIdentifier("item-\(line.id)-person-\(index + 1)")
            }
          }
        }
      }
      if line.isManual {
        Button("이 줄 지우기", role: .destructive) { edit { $0.removeManual(line.id) } }
          .accessibilityIdentifier("item-\(line.id)-remove")
      } else {
        Toggle(
          "품목 아님(나누기에서 빼기)",
          isOn: Binding(get: { line.excluded }, set: { value in edit { $0.setExcluded(line.id, value) } })
        )
        .accessibilityIdentifier("item-\(line.id)-exclude")
      }
    }
    .padding(.vertical, Spacing.xs)
    .opacity(line.excluded ? 0.6 : 1)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("item-\(line.id)")
  }

  private var sourceLabel: String? {
    switch line.nameSource {
    case .onDevice: "기기 번역 제안"
    case .preview: "미리보기 대역 · 실제 번역 아님"
    case .none, .user: nil
    }
  }

  static func flagText(_ flag: ItemFlag) -> String {
    switch flag {
    case .nameMissing: "이름을 읽지 못했어요."
    case .amountUnreadable: "금액을 읽지 못했어요."
    case .quantity: "수량이 있어요. 금액이 줄 합계인지 확인해 주세요."
    case .exceedsTotal: "영수증 합계보다 커요."
    }
  }
}

/// "언어 받기"를 누르면 시스템 창으로 사용자의 허락을 받아 일본어·한국어 언어를 받는다(iOS 18+). 끝나면 다시 확인한다.
private struct TranslationDownload: ViewModifier {
  @Binding var requested: Bool
  let onFinished: () -> Void

  #if canImport(Translation)
    /// 격리되지 않은 곳에서 만든 동작(세션을 다른 격리로 넘기지 않는다). 끝나면 메인 스레드에서 알린다.
    @available(iOS 18.0, *)
    nonisolated static func prepare(_ done: @escaping @MainActor () -> Void) -> (TranslationSession) async -> Void {
      { session in
        try? await session.prepareTranslation()
        await done()
      }
    }
  #endif

  func body(content: Content) -> some View {
    #if canImport(Translation)
      if #available(iOS 18.0, *) {
        content.translationTask(
          requested
            ? TranslationSession.Configuration(
              source: AppleItemTranslator.sourceLanguage, target: AppleItemTranslator.targetLanguage) : nil,
          action: Self.prepare { [onFinished] in
            requested = false
            onFinished()
          })
      } else {
        content
      }
    #else
      content
    #endif
  }
}
