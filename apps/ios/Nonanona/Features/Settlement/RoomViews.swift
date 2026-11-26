import ReceiptImport
import SwiftUI

// 여행방 장부, 방장 검토, 송금표(미리보기·확정본). 계산은 서버가 하고 화면은 서버 값을 그린다.
// 목록·상세 분할 보기의 상세 열 안에 쌓이고(장부 위에 검토·송금표), 각 화면은 한 열이라 접힘 피하기를 시스템에 맡긴다.

enum Won {
  static func text(_ krw: Int) -> String { "\(krw.formatted(.number.grouping(.automatic)))원" }

  static func original(_ minor: Int, _ currency: String) -> String {
    let text = ReviewForm.amountText(minor: minor, currency: currency)
    let digits = ReviewForm.currencies.first { $0.code == currency }?.minorDigits ?? 0
    let whole = digits == 0 ? (Int(text)?.formatted(.number.grouping(.automatic)) ?? text) : text
    return "\(whole) \(currency)"
  }
}

/// 원화 기준의 고정 문구(ADR-0008). 예상액은 언제나 "예상"과 고시값·단위·출처·기준일을 함께 보인다.
/// 가상 시험값(fixture)은 시장 환율이 아니라고 따로 적는다. 자유 입력 문구는 없다.
enum KRWBasisText {
  static func label(_ basis: KRWBasis?) -> String? {
    switch basis {
    case .krwOriginal: "원화 결제"
    case .verifiedCharge: "실제 청구액"
    case .acquisitionCost: "환전 원가"
    case .referenceEstimate: "예상 금액"
    case nil: nil
    }
  }

  /// "한국은행 ECOS 원/일본엔(100엔) · 2026-11-02 고시 · 100엔당 905.25원"
  static func quote(_ q: ReferenceQuote) -> String {
    "한국은행 ECOS \(q.itemName) · \(q.rateDate) 고시 · \(q.quoteUnit)엔당 \(q.rate)원"
  }

  /// 지출일에 고시가 없어 그 전 가장 최근 고시일 값을 쓴 경우의 설명.
  static func fallback(_ q: ReferenceQuote, expenseDate: String) -> String? {
    q.rateDate == expenseDate ? nil : "지출일(\(expenseDate))에 고시가 없어 그 전 가장 최근 고시일 값이에요."
  }

  static let synthetic = "가상 시험 환율 · 시장 환율 아님"
  static let notActual = "기준환율로 계산한 예상 금액이에요. 실제 청구액이 아니에요."

  static func acquisition(_ a: AcquisitionBasis, currency: String) -> String {
    "증빙으로 확인한 환전 원가 · \(Won.text(a.krwPaid))에 \(Won.original(a.foreignMinor, currency))"
  }

  /// 지출 한 건의 원화 근거 줄(포함한 지출). 실제 청구액·원화 결제는 nil.
  static func detail(basis: KRWBasis?, fx: ReferenceQuote?, acquisition: AcquisitionBasis?, currency: String)
    -> [String]
  {
    switch basis {
    case .referenceEstimate:
      guard let fx else { return [] }
      return [notActual, quote(fx)] + (fx.isSynthetic ? [synthetic] : [])
    case .acquisitionCost:
      return acquisition.map { [self.acquisition($0, currency: currency)] } ?? []
    default: return []
    }
  }
}

/// 기준환율 정정(ADR-0009)의 고정 문구. 정정은 금액을 저절로 바꾸지 않고, 방장이 고른다.
enum FXCorrectionText {
  /// 장부 지출 줄의 알림.
  static func rowNote(_ correction: FXCorrection) -> String {
    switch correction {
    case .required: "기준환율이 정정됐어요. 고정 금액 유지나 새 예상 금액 적용을 골라야 확정할 수 있어요."
    case .kept: "기준환율이 정정됐지만 고정 금액 유지를 골랐어요. 예상 금액 그대로예요."
    case .unavailable: "기준환율 정정 뒤 쓸 고시값이 없어요. 보류하거나 실제 청구액·환전 원가로 다시 포함해야 확정할 수 있어요."
    }
  }

  /// 검토 화면 비교 아래의 상태 설명.
  static func state(_ correction: FXCorrection) -> String {
    switch correction {
    case .required: "확정하려면 둘 중 하나를 골라 주세요. 고르기 전에는 포함한 금액이 바뀌지 않아요."
    case .kept: "고정 금액 유지를 골랐어요. 정산에는 고정한 예상 금액이 쓰이고 예상 금액으로 남아요. 새 예상 금액을 적용할 수도 있어요."
    case .unavailable:
      "정정 뒤 이 날짜에 쓸 수 있는 기준환율이 없어 자동으로 다시 계산하지 않아요. 실제 청구액·환전 원가를 골라 다시 포함하거나 보류해 주세요."
    }
  }

  static func signed(_ diff: Int) -> String { diff >= 0 ? "+\(Won.text(diff))" : "-\(Won.text(-diff))" }

  /// 송금표의 결정 필요 줄: "고정 13,554원 → 새 13,563원" 또는 "고정 18,187원 · 쓸 고시값 없음".
  static func summary(_ expense: LedgerExpense) -> String {
    let pinned = "고정 \(expense.krwAmount.map(Won.text) ?? "")"
    guard let new = SharePlan.usableEstimate(expense.fxProposal, amountMinor: expense.amountMinor) else {
      return "\(pinned) · 쓸 고시값 없음"
    }
    return "\(pinned) → 새 \(Won.text(new.krw))"
  }

  static let applyExactHint = "직접 나눈 몫은 자동으로 바꾸지 않아요. 아래 부담 금액을 새 예상 금액에 맞게 고친 뒤 적용해 주세요."
}

/// 홈의 여행방 목록. 로그인했을 때만 보인다.
struct TripListSection: View {
  let trips: [TripSummary]
  let failure: RoomLoadFailure?
  let onOpen: (TripSummary) -> Void

  var body: some View {
    Section {
      if trips.isEmpty {
        Text(failure == nil ? "참여한 여행방이 없어요." : "여행방 목록을 불러오지 못했어요.").textRole(.supporting)
      }
      ForEach(trips, id: \.id) { trip in
        Button {
          onOpen(trip)
        } label: {
          HStack(spacing: Spacing.s) {
            Text(trip.name).textRole(.body).foregroundStyle(.primary)
            Spacer()
            if trip.isFinalized { StatusLabel("확정됨", role: .positive) }
            if trip.isHost { StatusLabel("방장", role: .neutral) }
          }
        }
        .accessibilityIdentifier("trip-row")
      }
    } header: {
      Text("여행방").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
    }
  }
}

/// 여행방 장부: 일행, 지출(올린 사람·결제자·부담·상태), 송금표 진입. 방장은 지출을 눌러 검토한다.
struct RoomLedgerView: View {
  let ledger: RoomLedger
  let localDraftCount: Int
  let loading: Bool
  let failure: RoomLoadFailure?
  let onReview: (String) -> Void
  let onSettlement: () -> Void
  let onRefresh: () async -> Void
  /// 회원이 이 기기에서 올린 영수증 지출이면 품목으로 나눠 방장에게 제안할 수 있다(ADR-0011).
  var canPropose: (LedgerExpense) -> Bool = { _ in false }
  var onPropose: (String) -> Void = { _ in }

  private var pendingCount: Int { ledger.expenses.filter { $0.status == .pending }.count }
  private var correctionCount: Int { ledger.expenses.filter { $0.fxCorrection?.blocksFinalize == true }.count }

  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: Spacing.s) {
          HStack(spacing: Spacing.s) {
            StatusLabel("참여함", role: .positive).accessibilityIdentifier("room-status")
            if ledger.isFinalized {
              StatusLabel("정산 확정됨", role: .positive).accessibilityIdentifier("room-finalized")
            } else if pendingCount > 0 {
              StatusLabel("확인 필요 \(pendingCount)건", role: .attention).accessibilityIdentifier("room-pending")
            }
            if !ledger.isFinalized && correctionCount > 0 {
              StatusLabel("환율 정정 결정 필요 \(correctionCount)건", role: .attention)
                .accessibilityIdentifier("room-fx-correction")
            }
          }
          if let failure {
            Text(failure.message).textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier("room-failure")
          }
        }
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 0, leading: Spacing.m, bottom: 0, trailing: Spacing.m))

      Section {
        ForEach(ledger.members, id: \.id) { member in
          HStack {
            Text(member.displayName).textRole(.body)
            Spacer()
            if member.isHost {
              StatusLabel("방장", role: .neutral)
            } else if member.id == ledger.me {
              StatusLabel("나", role: .neutral)
            }
          }
        }
      } header: {
        Text("일행").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      }

      Section {
        if ledger.expenses.isEmpty {
          Text("아직 올라온 지출이 없어요.").textRole(.supporting)
        }
        ForEach(Array(ledger.expenses.enumerated()), id: \.element.id) { index, expense in
          let row = ExpenseRow(expense: expense, ledger: ledger)
          if ledger.isHost && !ledger.isFinalized {
            Button {
              onReview(expense.id)
            } label: {
              row
            }
            .accessibilityIdentifier("expense-\(index + 1)")
            .accessibilityHint("검토하기")
          } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
              row.accessibilityIdentifier("expense-\(index + 1)")
              if let sent = expense.shareProposal, expense.uploadedBy == ledger.me {
                Text(ShareProposalText.uploaderState(sent.state))
                  .textRole(.caption).foregroundStyle(.secondary)
                  .accessibilityIdentifier("expense-proposal-\(index + 1)")
              }
              if canPropose(expense) {
                Button("품목으로 나눠 방장에게 제안") { onPropose(expense.id) }
                  .buttonStyle(.borderless)
                  .accessibilityIdentifier("propose-items-\(index + 1)")
              }
            }
          }
        }
      } header: {
        Text("지출").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      } footer: {
        if ledger.isHost && !ledger.isFinalized && !ledger.expenses.isEmpty {
          Text("지출을 눌러 결제자·원화·부담을 확인하고 포함하거나 보류해 주세요.").textRole(.supporting)
        }
      }

      Section {
        Button(ledger.isFinalized ? "확정된 송금표 보기" : "송금표 미리보기", action: onSettlement)
          .buttonStyle(.primaryAction)
          .accessibilityIdentifier("open-settlement")
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
      } footer: {
        if localDraftCount > 0 {
          Text("영수증 초안 \(localDraftCount)장은 아직 이 기기에만 있어요.").textRole(.supporting)
        }
      }
    }
    .overlay(alignment: .top) {
      if loading { ProgressView().padding(Spacing.s) }
    }
    .refreshable { await onRefresh() }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("새로고침") { Task { await onRefresh() } }.accessibilityIdentifier("room-refresh")
      }
    }
    .adaptiveContentMargins()
    .navigationTitle(ledger.name)
    .accessibilityIdentifier("room-screen")
  }
}

/// 지출 한 줄: 가게(또는 직접 입력) · 날짜 · 원래 금액 · 올린 사람, 상태, 결제자·원화·부담.
struct ExpenseRow: View {
  let expense: LedgerExpense
  let ledger: RoomLedger

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
        Text(expense.merchant ?? "가게 이름 없음").textRole(.body).foregroundStyle(.primary)
        Spacer()
        status
      }
      Text("\(expense.date) · \(Won.original(expense.amountMinor, expense.currency))")
        .textRole(.supporting).foregroundStyle(.secondary)
      Text(
        "\(ledger.name(of: expense.uploadedBy))이(가) 올림 · \(expense.isManual ? "직접 입력(증빙 없음)" : "가린 사본")"
      )
      .textRole(.caption).foregroundStyle(.secondary)
      if expense.status == .included, let krw = expense.krwAmount {
        Text("결제 \(ledger.name(of: expense.payer)) · \(krwText(krw)) · \(sharesText)")
          .textRole(.caption).foregroundStyle(.secondary)
        ForEach(
          KRWBasisText.detail(
            basis: expense.krwBasis, fx: expense.fx, acquisition: expense.acquisition, currency: expense.currency),
          id: \.self
        ) { line in
          Text(line).textRole(.caption).foregroundStyle(.secondary)
        }
        if let correction = expense.fxCorrection {
          Text(FXCorrectionText.rowNote(correction)).textRole(.caption)
            .foregroundStyle(correction == .kept ? Color.secondary : Color.orange)
        } else if expense.fxSuperseded {
          Text("더 새 기준환율 고시값이 있어요. 포함한 금액은 그대로이고 다시 검토할 수 있어요.")
            .textRole(.caption).foregroundStyle(.orange)
        }
      }
      if case .held(let reason) = expense.status {
        Text("보류 사유: \(reason)").textRole(.caption).foregroundStyle(.secondary)
      }
      if ledger.isHost, expense.shareProposal?.state == .current {
        Text("올린 사람의 품목 나누기 제안이 있어요").textRole(.caption).foregroundStyle(.orange)
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// 실제 청구액이 아니면 기준 이름을 금액 옆에 붙인다(예: "예상 금액 12,746원").
  private func krwText(_ krw: Int) -> String {
    switch expense.krwBasis {
    case .referenceEstimate, .acquisitionCost: "\(KRWBasisText.label(expense.krwBasis) ?? "") \(Won.text(krw))"
    default: Won.text(krw)
    }
  }

  private var sharesText: String {
    "부담 " + expense.shares.map { "\(ledger.name(of: $0.member)) \(Won.text($0.krw))" }.joined(separator: ", ")
  }

  @ViewBuilder private var status: some View {
    switch expense.status {
    case .pending: StatusLabel("확인 필요", role: .attention)
    case .included:
      if expense.fxCorrection?.blocksFinalize == true {
        StatusLabel("포함 · 환율 정정", role: .attention)
      } else if expense.krwBasis == .referenceEstimate {
        StatusLabel("포함 · 예상", role: .attention)
      } else {
        StatusLabel("포함", role: .positive)
      }
    case .held: StatusLabel("보류", role: .neutral)
    }
  }
}

/// 방장 검토: 결제자, 원화(KRW는 그대로, 외화는 확인한 청구액), 부담(한 사람 · 둘이 반씩 · 직접 나누기)을 정하고
/// 포함하거나 사유와 함께 보류한다. 반씩은 홀수 금액이면 결제자가 1원을 더 부담하고, 결제자가 두 사람 밖이면 직접 나누게 한다.
struct ExpenseReviewView: View {
  let expense: LedgerExpense
  let ledger: RoomLedger
  let form: ShareForm
  let state: ReviewSaveState?
  let refreshed: Bool
  let edit: ((inout ShareForm) -> Void) -> Void
  let onInclude: () -> Void
  let onHold: (String) -> Void
  var receipt: ReceiptViewState? = nil
  var onShowReceipt: () -> Void = {}
  var onHideReceipt: () -> Void = {}
  var onKeepEstimate: () -> Void = {}
  var onApplyEstimate: () -> Void = {}
  /// 이 지출을 이 기기에서 올려 영수증 품목(기기 안)으로 나눌 수 있다.
  var itemSplitAvailable = false
  var onOpenItemSplit: () -> Void = {}
  /// 올린 사람의 제안 몫을 "직접 나누기"에 채운다(보내지 않는다, ADR-0011).
  var onFillProposal: () -> Void = {}

  @State private var askingHoldReason = false
  static let holdReasons = ["원화 청구액 확인 대기", "결제 여부 불명확", "같은 지출일 수 있음"]

  private var krw: Int? { form.krw(for: expense) }
  private var result: Result<[ShareLine], ShareProblem> { form.shares(for: expense, members: ledger.members) }
  private var saving: Bool { state == .saving }
  /// 지금 입력한 몫(결제자를 아직 고르지 않았어도). 제안과 나란히 비교할 때만 쓴다.
  private var enteredShares: [ShareLine]? {
    var probe = form
    if probe.payer == nil { probe.payer = ledger.members.first?.id }
    return try? probe.shares(for: expense, members: ledger.members).get()
  }
  /// 새 예상 금액 적용으로 보낼 몫(기준을 기준환율 예상으로 둔 입력). 직접 나눈 몫은 고치지 않으므로 맞지 않으면 실패다.
  private var applyResult: Result<[ShareLine], ShareProblem> {
    var applied = form
    applied.krwSource = .estimate
    return applied.shares(for: expense, members: ledger.members)
  }

  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(expense.merchant ?? "가게 이름 없음").textRole(.sectionTitle)
          Text("\(expense.date) · \(Won.original(expense.amountMinor, expense.currency))")
            .textRole(.body).accessibilityIdentifier("review-original")
          Text("\(ledger.name(of: expense.uploadedBy))이(가) 올림 · \(expense.isManual ? "직접 입력(증빙 없음)" : "가린 사본")")
            .textRole(.supporting).foregroundStyle(.secondary)
        }
      }

      if let correction = expense.fxCorrection {
        FXCorrectionSection(
          expense: expense, correction: correction, canApply: (try? applyResult.get()) != nil,
          exactMode: form.mode == .exact, saving: saving, onKeep: onKeepEstimate, onApply: onApplyEstimate)
      }

      ReceiptAttachmentSection(
        hasArtifact: expense.artifact != nil, state: receipt, onShow: onShowReceipt, onHide: onHideReceipt)

      if ledger.isHost, let proposal = expense.shareProposal {
        ShareProposalSection(
          proposal: proposal, expense: expense, ledger: ledger, form: form, entered: enteredShares, saving: saving,
          onFill: onFillProposal)
      }

      Section {
        Picker("결제자", selection: binding(\.payer)) {
          Text("고르기").tag(MemberID?.none)
          ForEach(ledger.members, id: \.id) { Text($0.displayName).tag(Optional($0.id)) }
        }
        .accessibilityIdentifier("review-payer")
      } header: {
        Text("결제자").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      } footer: {
        Text("실제로 돈을 낸 사람이에요. 올린 사람과 다를 수 있어요.").textRole(.supporting)
      }

      KRWSection(expense: expense, form: form, saving: saving, edit: edit)

      if expense.artifact != nil {
        Section {
          if itemSplitAvailable {
            Button("영수증 품목으로 나누기", action: onOpenItemSplit)
              .disabled(saving)
              .accessibilityIdentifier("review-item-split")
          } else {
            Text("이 영수증은 다른 기기에서 올려 품목으로 나눌 수 없어요. 품목 글자는 올린 기기에만 있어요.")
              .textRole(.supporting).foregroundStyle(.secondary)
              .accessibilityIdentifier("review-item-split-unavailable")
          }
        } footer: {
          if itemSplitAvailable {
            Text("이 기기에 있는 품목으로 사람마다 몫을 계산해 \"직접 나누기\"에 채워요. 품목 이름은 올라가지 않아요.")
              .textRole(.caption)
          }
        }
      }

      Section {
        Picker("부담 방식", selection: binding(\.mode)) {
          Text("한 사람").tag(ShareMode.one)
          Text("둘이 반씩").tag(ShareMode.even)
          Text("직접 나누기").tag(ShareMode.exact)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("review-share-mode")
        switch form.mode {
        case .one:
          Picker("부담할 사람", selection: binding(\.one)) {
            Text("고르기").tag(MemberID?.none)
            ForEach(ledger.members, id: \.id) { Text($0.displayName).tag(Optional($0.id)) }
          }
          .accessibilityIdentifier("review-share-one")
        case .even:
          ForEach(ledger.members, id: \.id) { member in
            Toggle(
              member.displayName,
              isOn: Binding(
                get: { form.pair.contains(member.id) },
                set: { on in edit { if on { $0.pair.insert(member.id) } else { $0.pair.remove(member.id) } } })
            )
            .disabled(saving)
          }
          if let krw, case .success(let lines) = result {
            Text(Self.evenSummary(lines, krw: krw, payer: form.payer, ledger: ledger))
              .textRole(.supporting).accessibilityIdentifier("review-even-summary")
          }
        case .exact:
          ForEach(Array(ledger.members.enumerated()), id: \.element.id) { index, member in
            LabeledContent(member.displayName) {
              TextField(
                "0",
                text: Binding(
                  get: { form.exact[member.id] ?? "" },
                  set: { text in edit { $0.exact[member.id] = text } })
              )
              .keyboardType(.numberPad)
              .multilineTextAlignment(.trailing)
              .accessibilityIdentifier("review-exact-\(index + 1)")
              .accessibilityLabel("\(member.displayName) 부담 원")
            }
          }
        }
        if let problem {
          Text(problem).textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier("review-share-problem")
        }
      } header: {
        Text("부담").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      }

      Section {
        if expense.fxSuperseded && expense.fxCorrection == nil {
          Text("포함한 예상 금액 뒤에 더 새 기준환율 고시값이 들어왔어요. 다시 저장하면 새 값으로 바뀌어요.")
            .textRole(.supporting).foregroundStyle(.orange).accessibilityIdentifier("review-fx-superseded")
        }
        if refreshed {
          Text("다른 변경이 먼저 저장돼 최신 값으로 다시 열었어요. 확인하고 다시 저장해 주세요.")
            .textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier("review-refreshed")
        }
        if case .failed(let failure) = state, !(refreshed && failure == .stale) {
          Text(failure.message).textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier("review-failure")
        }
        Button(saving ? "저장하는 중…" : "포함하기", action: onInclude)
          .buttonStyle(.primaryAction)
          .disabled(saving || (try? result.get()) == nil)
          .accessibilityIdentifier("review-include")
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
        Button("보류하기") { askingHoldReason = true }
          .disabled(saving)
          .accessibilityIdentifier("review-hold")
      }
    }
    .confirmationDialog("보류 사유", isPresented: $askingHoldReason, titleVisibility: .visible) {
      ForEach(Self.holdReasons, id: \.self) { reason in
        Button(reason) { onHold(reason) }
      }
      Button("취소", role: .cancel) {}
    } message: {
      Text("보류한 지출은 송금표에서 빠지고 사유와 함께 남아요.")
    }
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
    .navigationTitle("지출 검토")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("expense-review-screen")
  }

  private var problem: String? {
    guard case .failure(let problem) = result else { return nil }
    switch problem {
    case .payerMissing: return "결제자를 골라 주세요."
    case .krwMissing: return "실제 원화 청구액을 넣거나 보류해 주세요."
    case .acquisitionInvalid: return "환전에 쓴 원화와 받은 엔을 원·엔 단위 숫자로 넣어 주세요."
    case .estimateUnavailable: return "쓸 수 있는 기준환율이 없어요. 다른 기준을 고르거나 보류해 주세요."
    case .personMissing: return "부담할 사람을 골라 주세요."
    case .pairRequired: return "반씩 나눌 두 사람을 골라 주세요."
    case .notDivisible:
      return "결제자가 두 사람 밖이라 남는 1원을 누가 낼지 정할 수 없어요. 직접 나누기로 사람마다 금액을 적어 주세요."
    case .tooSmallToSplit: return "1원은 두 사람이 나눌 수 없어요. 한 사람으로 정해 주세요."
    case .exactInvalid: return "부담 금액은 원 단위 숫자로 적어 주세요."
    case .exactMismatch(let remaining):
      return remaining > 0
        ? "\(Won.text(remaining))이 남았어요. 합계가 원화와 같아야 해요." : "\(Won.text(-remaining)) 넘어요. 합계가 원화와 같아야 해요."
    }
  }

  /// 반씩 결과. 홀수 금액이면 결제자가 1원을 더 부담한다는 것과 사람마다 몫을 함께 보인다.
  static func evenSummary(_ lines: [ShareLine], krw: Int, payer: MemberID?, ledger: RoomLedger) -> String {
    guard lines.count == 2, lines[0].krw != lines[1].krw else {
      return "한 사람 \(Won.text(lines[0].krw)) · 합계 \(Won.text(krw))"
    }
    let each = lines.map { "\(ledger.name(of: $0.member)) \(Won.text($0.krw))" }.joined(separator: " · ")
    return "\(each) · 합계 \(Won.text(krw)). 남는 1원은 결제자(\(ledger.name(of: payer)))가 더 부담해요."
  }

  private func binding<T>(_ path: WritableKeyPath<ShareForm, T>) -> Binding<T> {
    Binding(get: { form[keyPath: path] }, set: { value in edit { $0[keyPath: path] = value } })
  }
}

/// 검토 화면의 원화: KRW는 그대로, 엔화는 실제 청구액 → 환전 원가 → 기준환율 예상 순으로 고른다(ADR-0001·0008).
/// 다른 외화는 실제 청구액만. 예상액은 서버 고시값으로만 만들고 "예상"과 근거를 함께 보인다.
/// 방장 검토의 "올린 사람의 품목 나누기 제안": 원화 기준·합계, 사람마다 제안 몫과 지금 입력(또는 포함한) 몫, 상태.
/// 채우기는 입력만 바꾸고 보내지 않는다. 지금 제안이 아니거나 방장이 고를 수 있는 원화와 맞지 않으면 채울 수 없다.
struct ShareProposalSection: View {
  let proposal: ShareProposal
  let expense: LedgerExpense
  let ledger: RoomLedger
  let form: ShareForm
  let entered: [ShareLine]?
  let saving: Bool
  let onFill: () -> Void

  private var canFill: Bool {
    var copy = form
    return copy.fill(from: proposal, expense: expense, members: ledger.members)
  }
  private var other: [ShareLine] { entered ?? (expense.status == .included ? expense.shares : []) }
  private var otherLabel: String { entered != nil ? "입력" : "포함" }

  var body: some View {
    let comparison = ProposalComparison(proposal: proposal, other: other, members: ledger.members)
    Section {
      Text("\(ledger.name(of: proposal.proposedBy))이(가) 보낸 제안 · \(ShareProposalText.basisLabel(proposal))")
        .textRole(.body).accessibilityIdentifier("review-proposal-basis")
      ForEach(Array(comparison.rows.enumerated()), id: \.element.member) { index, row in
        LabeledContent(ledger.name(of: row.member)) {
          Text(
            "제안 \(row.proposed.map(Won.text) ?? "없음") · \(otherLabel) \(row.other.map(Won.text) ?? "없음")"
          )
        }
        .accessibilityIdentifier("review-proposal-row-\(index + 1)")
      }
      if !other.isEmpty {
        Text(comparison.matches ? "\(otherLabel)한 몫이 제안과 같아요." : "\(otherLabel)한 몫이 제안과 달라요.")
          .textRole(.supporting).foregroundStyle(comparison.matches ? Color.secondary : Color.orange)
          .accessibilityIdentifier("review-proposal-match")
      }
      Text(ShareProposalText.hostState(proposal.state))
        .textRole(.supporting).accessibilityIdentifier("review-proposal-state")
      if proposal.state == .current {
        Button("제안 몫을 직접 나누기에 채우기", action: onFill)
          .disabled(saving || !canFill)
          .accessibilityIdentifier("review-proposal-fill")
        if !canFill {
          Text("지금 이 지출에서 고를 수 있는 원화와 제안의 원화가 달라 채울 수 없어요.")
            .textRole(.supporting).foregroundStyle(.secondary).accessibilityIdentifier("review-proposal-unfillable")
        }
      }
    } header: {
      Text("올린 사람의 품목 나누기 제안").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
    } footer: {
      Text("품목 이름은 오지 않아요. 제안은 정산을 바꾸지 않아요. 채운 뒤 결제자를 고르고 \"포함하기\"를 눌러야 들어가요.")
        .textRole(.caption)
    }
  }
}

struct KRWSection: View {
  let expense: LedgerExpense
  let form: ShareForm
  let saving: Bool
  let edit: ((inout ShareForm) -> Void) -> Void

  private var sources: [KRWSource] { ShareForm.sources(for: expense) }
  private var source: KRWSource { form.source(for: expense) }

  var body: some View {
    Section {
      if expense.currency == "KRW" {
        Text("원화 결제 · \(Won.text(expense.amountMinor))").textRole(.body).accessibilityIdentifier("review-krw-fixed")
      } else {
        if sources.count > 1 {
          Picker(
            "원화 기준",
            selection: Binding(get: { source }, set: { value in edit { $0.krwSource = value } })
          ) {
            Text("실제 청구액").tag(KRWSource.actual)
            Text("환전 원가").tag(KRWSource.acquisition)
            Text("기준환율 예상").tag(KRWSource.estimate)
          }
          .pickerStyle(.segmented)
          .disabled(saving)
          .accessibilityIdentifier("review-krw-source")
        }
        switch source {
        case .actual:
          TextField("실제 원화 청구액(원)", text: field(\.verifiedKRWText))
            .keyboardType(.numberPad)
            .accessibilityIdentifier("review-krw")
        case .acquisition:
          TextField("환전에 쓴 원화(원)", text: field(\.acquisitionKRWText))
            .keyboardType(.numberPad)
            .accessibilityIdentifier("review-acq-krw")
          TextField("받은 엔(엔)", text: field(\.acquisitionForeignText))
            .keyboardType(.numberPad)
            .accessibilityIdentifier("review-acq-foreign")
          if let a = form.acquisitionInput, let krw = form.krw(for: expense) {
            Text(
              "\(Won.original(expense.amountMinor, expense.currency)) × \(Won.text(a.krwPaid)) ÷ \(Won.original(a.foreignMinor, expense.currency)) = \(Won.text(krw)) (원 단위 반올림)"
            )
            .textRole(.supporting).accessibilityIdentifier("review-acq-result")
          }
        case .estimate:
          estimate
        }
      }
    } header: {
      Text("원화").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
    } footer: {
      if expense.currency == "JPY" {
        Text("실제 원화 청구액이 있으면 그 금액을, 없으면 증빙으로 확인한 환전 원가를 쓰고, 둘 다 없을 때만 기준환율 예상을 골라 주세요. 모르면 보류해 주세요.")
          .textRole(.supporting)
      } else if expense.currency != "KRW" {
        Text("카드·계좌에 찍힌 원화 금액을 넣어 주세요. 아직 모르면 보류해 주세요. 이 통화는 환율로 계산하지 않아요.")
          .textRole(.supporting)
      }
    }
  }

  @ViewBuilder private var estimate: some View {
    if let usable = SharePlan.usableEstimate(expense.fxProposal, amountMinor: expense.amountMinor) {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("예상 금액 \(Won.text(usable.krw))").textRole(.body).accessibilityIdentifier("review-estimate-krw")
        Text(KRWBasisText.quote(usable.quote)).textRole(.supporting).accessibilityIdentifier("review-estimate-quote")
        if let note = KRWBasisText.fallback(usable.quote, expenseDate: expense.date) {
          Text(note).textRole(.supporting).accessibilityIdentifier("review-estimate-fallback")
        }
        Text(
          "\(Won.original(expense.amountMinor, expense.currency)) × \(usable.quote.rate)원 ÷ \(usable.quote.quoteUnit)엔, 원 단위 반올림"
        )
        .textRole(.caption).foregroundStyle(.secondary)
        Text(KRWBasisText.notActual).textRole(.caption).foregroundStyle(.secondary)
        if usable.quote.isSynthetic {
          Text(KRWBasisText.synthetic).textRole(.caption).foregroundStyle(.orange)
            .accessibilityIdentifier("review-estimate-synthetic")
        }
      }
    } else {
      Text(unavailableText).textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier("review-estimate-none")
    }
  }

  private var unavailableText: String {
    switch expense.fxProposal {
    case .undetermined: "이 날짜의 기준환율을 아직 확인하지 못했어요. 실제 청구액·환전 원가를 쓰거나 보류해 주세요."
    case .unavailable: "지출일 앞 31일 안에 기준환율 고시가 없어 예상 금액을 만들 수 없어요. 보류해 주세요."
    case .proposed, nil: "기준환율 예상 금액을 확인할 수 없어요. 새로고침하거나 보류해 주세요."
    }
  }

  private func field(_ path: WritableKeyPath<ShareForm, String>) -> Binding<String> {
    Binding(get: { form[keyPath: path] }, set: { value in edit { $0[keyPath: path] = value } })
  }
}

/// 기준환율 정정(ADR-0009): 고정한 예상 금액과 지금 적용되는 새 예상 금액을 기준·기준일·금액으로 나란히 보이고, 방장이
/// 고정 금액 유지나 새 예상 금액 적용을 고르게 한다. 새 고시값이 없으면 두 동작 모두 없고 보류·다른 기준으로만 푼다.
struct FXCorrectionSection: View {
  let expense: LedgerExpense
  let correction: FXCorrection
  let canApply: Bool
  let exactMode: Bool
  let saving: Bool
  let onKeep: () -> Void
  let onApply: () -> Void

  private var replacement: (quote: ReferenceQuote, krw: Int)? {
    SharePlan.usableEstimate(expense.fxProposal, amountMinor: expense.amountMinor)
  }

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("고정한 예상 금액").textRole(.caption).foregroundStyle(.secondary)
        Text(expense.krwAmount.map(Won.text) ?? "").textRole(.body).monospacedDigit()
          .accessibilityIdentifier("review-fx-pinned-krw")
        if let fx = expense.fx {
          Text(KRWBasisText.quote(fx)).textRole(.supporting).accessibilityIdentifier("review-fx-pinned-quote")
          if fx.isSynthetic {
            Text(KRWBasisText.synthetic).textRole(.caption).foregroundStyle(.orange)
          }
        }
      }
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("지금 적용되는 기준환율").textRole(.caption).foregroundStyle(.secondary)
        if let replacement {
          Text("새 예상 금액 \(Won.text(replacement.krw))").textRole(.body).monospacedDigit()
            .accessibilityIdentifier("review-fx-new-krw")
          Text(KRWBasisText.quote(replacement.quote)).textRole(.supporting)
            .accessibilityIdentifier("review-fx-new-quote")
          if replacement.quote.isSynthetic {
            Text(KRWBasisText.synthetic).textRole(.caption).foregroundStyle(.orange)
          }
          if let pinned = expense.krwAmount {
            Text("차이 \(FXCorrectionText.signed(replacement.krw - pinned))").textRole(.caption)
              .foregroundStyle(.secondary).accessibilityIdentifier("review-fx-diff")
          }
        } else {
          Text("쓸 수 있는 기준환율 고시값이 없어요.").textRole(.body).foregroundStyle(.red)
            .accessibilityIdentifier("review-fx-new-none")
        }
      }
      Text(FXCorrectionText.state(correction)).textRole(.supporting)
        .foregroundStyle(correction == .kept ? Color.secondary : Color.orange)
        .accessibilityIdentifier("review-fx-state")
      if correction == .required, replacement != nil {
        Button("고정 금액 유지", action: onKeep)
          .disabled(saving)
          .accessibilityIdentifier("review-fx-keep")
      }
      if correction != .unavailable, replacement != nil {
        Button("새 예상 금액 적용", action: onApply)
          .disabled(saving || !canApply)
          .accessibilityIdentifier("review-fx-apply")
        if exactMode && !canApply {
          Text(FXCorrectionText.applyExactHint).textRole(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("review-fx-apply-hint")
        }
      }
    } header: {
      Text("기준환율 정정").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
    }
  }
}

/// 검토 화면의 증빙: 공유한 가림 사본을 눌러서 열고, 직접 입력은 증빙 없음. 실패해도 검토는 그대로 할 수 있다.
struct ReceiptAttachmentSection: View {
  let hasArtifact: Bool
  let state: ReceiptViewState?
  let onShow: () -> Void
  let onHide: () -> Void

  var body: some View {
    Section {
      if !hasArtifact {
        Text("증빙 없음 · 직접 입력이라 사진이 없어요.").textRole(.body).accessibilityIdentifier("review-receipt-none")
      } else {
        switch state {
        case nil:
          Button("가린 사본 보기", action: onShow).accessibilityIdentifier("review-receipt-show")
        case .loading:
          HStack(spacing: Spacing.s) {
            ProgressView()
            Text("사본을 불러오는 중…").textRole(.supporting)
          }
          .accessibilityIdentifier("review-receipt-loading")
        case .shown(let decoded):
          Image(decorative: decoded.cgImage, scale: 1)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .accessibilityElement()
            .accessibilityLabel("가린 영수증 사본")
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("review-receipt-image")
          Text("올린 사본과 같아요 · 확인 \(decoded.image.sha256.prefix(8))")
            .textRole(.caption).foregroundStyle(.secondary).accessibilityIdentifier("review-receipt-verified")
          Button("사본 닫기", action: onHide).accessibilityIdentifier("review-receipt-hide")
        case .failed(let failure):
          Text(failure.message).textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier(
            "review-receipt-failure")
          Button("다시 시도", action: onShow).accessibilityIdentifier("review-receipt-retry")
        }
      }
    } header: {
      Text("증빙").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
    } footer: {
      if hasArtifact {
        Text("올린 사람이 가림을 확인한 사본만 보여요. 원본 사진과 읽은 글자는 올린 사람 기기에만 있어요.").textRole(.supporting)
      }
    }
  }
}

extension ReceiptViewFailure {
  var message: String {
    switch self {
    case .sessionExpired: "로그인이 만료됐어요. 다시 로그인한 뒤 다시 시도해 주세요."
    case .denied: "이 사본을 볼 권한이 없어요."
    case .missing: "사본을 찾을 수 없거나 볼 수 없어요."
    case .mismatch: "받은 사본이 올린 사본과 달라 보여 주지 않았어요."
    case .undecodable: "사본 그림을 열 수 없어요. 다시 시도해 주세요."
    case .network: "인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요."
    case .unavailable: "지금은 사본을 불러올 수 없어요. 잠시 후 다시 시도해 주세요."
    case .unknown: "사본을 불러오지 못했어요. 다시 시도해 주세요."
    }
  }
}

/// 송금표. 확정 전에는 서버가 지금 입력으로 계산한 미리보기, 확정 뒤에는 고정된 확정본을 그린다.
struct SettlementView: View {
  let ledger: RoomLedger?
  let preview: SettlementPreview?
  let final: FinalSettlement?
  let state: SettlementScreenState?
  let refreshed: Bool
  let onFinalize: () -> Void
  let onRefresh: () async -> Void
  /// 결정이 필요한 지출을 눌렀다(방장). 송금표를 닫고 그 지출 검토를 연다.
  var onOpenExpense: (String) -> Void = { _ in }

  var body: some View {
    List {
      if let final {
        finalSections(final)
      } else if let preview, let ledger {
        previewSections(preview, ledger)
      } else if case .failed(let failure) = state {
        Text(failure.message).textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier("settlement-failure")
      } else {
        ProgressView()
      }
    }
    .refreshable { await onRefresh() }
    .adaptiveContentMargins()
    .navigationTitle(final == nil ? "송금표 미리보기" : "확정된 송금표")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("settlement-screen")
  }

  @ViewBuilder private func previewSections(_ preview: SettlementPreview, _ ledger: RoomLedger) -> some View {
    Section {
      VStack(alignment: .leading, spacing: Spacing.s) {
        StatusLabel("미리보기 · 아직 확정 전", role: .attention).accessibilityIdentifier("settlement-status")
        if preview.pendingCount > 0 {
          Text("확인 필요 지출 \(preview.pendingCount)건이 있어 확정할 수 없어요. 방장이 포함하거나 보류해야 해요.")
            .textRole(.supporting).accessibilityIdentifier("settlement-pending")
        }
        if !preview.fxCorrectionIDs.isEmpty {
          Text("기준환율이 정정된 예상 금액 \(preview.fxCorrectionIDs.count)건이 있어 확정할 수 없어요.")
            .textRole(.supporting).foregroundStyle(.orange).accessibilityIdentifier("settlement-fx-blocked")
        }
        if refreshed {
          Text("미리보기 뒤에 바뀐 내용이 있어 확정하지 않았어요. 새 송금표를 확인하고 다시 확정해 주세요.")
            .textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier("settlement-refreshed")
        } else if case .failed(let failure) = state {
          Text(failure.message).textRole(.supporting).foregroundStyle(.red).accessibilityIdentifier(
            "settlement-failure")
        }
      }
    }
    .listRowBackground(Color.clear)
    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.m, bottom: 0, trailing: Spacing.m))
    correctionSection(preview.fxCorrectionIDs, ledger)
    transfersSection(preview.transfers, total: preview.includedTotalKRW, estimated: preview.estimatedTotalKRW) {
      ledger.name(of: $0)
    }
    conversionSection(
      ledger.expenses.filter { $0.status == .included }.map {
        ConvertedExpense(
          merchant: $0.merchant, date: $0.date, original: Won.original($0.amountMinor, $0.currency),
          krw: $0.krwAmount, basis: $0.krwBasis, fx: $0.fx, acquisition: $0.acquisition, currency: $0.currency)
      })
    excludedSection(preview.excluded) { id in
      ledger.expenses.first { $0.id == id }.map { ($0.merchant, $0.date, Won.original($0.amountMinor, $0.currency)) }
    }
    if ledger.isHost {
      Section {
        Button(state == .finalizing ? "확정하는 중…" : "정산 확정", action: onFinalize)
          .buttonStyle(.primaryAction)
          .disabled(!preview.ready || state == .finalizing)
          .accessibilityIdentifier("settlement-finalize")
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
      } footer: {
        Text("확정하면 이 송금표가 고정되고 지출을 더하거나 고칠 수 없어요.").textRole(.supporting)
      }
    } else {
      Section {
        Text("방장이 확정하면 이 송금표가 고정돼요.").textRole(.supporting)
      }
    }
  }

  /// 기준환율 정정으로 방장 결정이 필요한 지출(ADR-0009). 방장은 눌러서 그 지출 검토로 간다.
  @ViewBuilder private func correctionSection(_ ids: [String], _ ledger: RoomLedger) -> some View {
    if !ids.isEmpty {
      Section {
        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
          let expense = ledger.expenses.first { $0.id == id }
          let row = VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(expense?.merchant ?? "가게 이름 없음").textRole(.body).foregroundStyle(.primary)
            Text(expense.map { "\($0.date) · \(Won.original($0.amountMinor, $0.currency))" } ?? "")
              .textRole(.caption).foregroundStyle(.secondary)
            Text(expense.map(FXCorrectionText.summary) ?? "").textRole(.caption).foregroundStyle(.orange)
          }
          if ledger.isHost {
            Button {
              onOpenExpense(id)
            } label: {
              row
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settlement-fx-\(index + 1)")
            .accessibilityHint("검토하기")
          } else {
            row.accessibilityElement(children: .combine).accessibilityIdentifier("settlement-fx-\(index + 1)")
          }
        }
      } header: {
        Text("기준환율 정정 · 결정 필요").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      } footer: {
        Text(
          ledger.isHost
            ? "지출을 눌러 고정 금액 유지나 새 예상 금액 적용을 골라 주세요. 쓸 고시값이 없는 지출은 보류하거나 실제 청구액·환전 원가로 포함해 주세요."
            : "방장이 정해야 확정할 수 있어요."
        ).textRole(.supporting)
      }
    }
  }

  /// 서버의 UTC 시각(초 단위, Z)을 이 기기 시간대로 보인다. 읽지 못하면 받은 글자 그대로.
  static func localTime(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
    return date.formatted(.dateTime.year().month().day().hour().minute())
  }

  @ViewBuilder private func finalSections(_ final: FinalSettlement) -> some View {
    Section {
      VStack(alignment: .leading, spacing: Spacing.s) {
        StatusLabel("정산 확정됨", role: .positive).accessibilityIdentifier("settlement-status")
        Text("확정 \(final.version)판 · \(Self.localTime(final.finalizedAt))")
          .textRole(.supporting)
        Text("확정 번호 \(final.id.prefix(8)) · 기록 \(final.snapshotSHA256.prefix(8))")
          .textRole(.caption).foregroundStyle(.secondary).accessibilityIdentifier("settlement-final-id")
      }
    }
    .listRowBackground(Color.clear)
    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.m, bottom: 0, trailing: Spacing.m))
    transfersSection(final.transfers, total: final.includedTotalKRW, estimated: final.estimatedTotalKRW) {
      final.name(of: $0)
    }
    conversionSection(
      final.expenses.filter { $0.kind == "shared" || $0.kind == "personal" }.map {
        ConvertedExpense(
          merchant: $0.merchant, date: $0.date, original: Won.original($0.amountMinor, $0.currency),
          krw: $0.krwAmount, basis: $0.krwBasis, fx: $0.fx, acquisition: $0.acquisition, currency: $0.currency)
      })
    excludedSection(final.excluded) { id in
      final.expense(id).map { ($0.merchant, $0.date, Won.original($0.amountMinor, $0.currency)) }
    }
  }

  /// 원화 기준 목록에 보일 지출(포함한 것만).
  struct ConvertedExpense {
    let merchant: String?
    let date: String
    let original: String
    let krw: Int?
    let basis: KRWBasis?
    let fx: ReferenceQuote?
    let acquisition: AcquisitionBasis?
    let currency: String
  }

  /// 실제 청구액이 아닌 원화(환전 원가·기준환율 예상)로 넣은 지출과 그 근거. 없으면 그리지 않는다.
  @ViewBuilder private func conversionSection(_ all: [ConvertedExpense]) -> some View {
    let converted = all.filter { $0.basis == .referenceEstimate || $0.basis == .acquisitionCost }
    if !converted.isEmpty {
      Section {
        ForEach(Array(converted.enumerated()), id: \.offset) { index, x in
          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
              Text(x.merchant ?? "가게 이름 없음").textRole(.body)
              Spacer()
              Text("\(KRWBasisText.label(x.basis) ?? "") \(x.krw.map(Won.text) ?? "")").textRole(.body)
                .monospacedDigit()
            }
            Text("\(x.date) · \(x.original)").textRole(.caption).foregroundStyle(.secondary)
            ForEach(
              KRWBasisText.detail(basis: x.basis, fx: x.fx, acquisition: x.acquisition, currency: x.currency),
              id: \.self
            ) { line in
              Text(line).textRole(.caption).foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("converted-\(index + 1)")
        }
      } header: {
        Text("원화 환산 근거").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      } footer: {
        Text("실제 청구액이 아닌 지출이에요. 예상 금액은 확정해도 예상으로 남아요.").textRole(.supporting)
      }
    }
  }

  @ViewBuilder private func transfersSection(
    _ transfers: [Transfer], total: Int, estimated: Int, name: @escaping (MemberID) -> String
  ) -> some View {
    Section {
      if transfers.isEmpty {
        Text("보낼 돈이 없어요.").textRole(.body).accessibilityIdentifier("transfer-none")
      }
      ForEach(Array(transfers.enumerated()), id: \.offset) { index, t in
        HStack {
          Text("\(name(t.from)) → \(name(t.to))").textRole(.body)
          Spacer()
          Text(Won.text(t.krw)).textRole(.body).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transfer-\(index + 1)")
      }
      HStack {
        Text("함께 쓴 돈").textRole(.supporting)
        Spacer()
        Text(Won.text(total)).textRole(.supporting).monospacedDigit()
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("settlement-total")
      if estimated > 0 {
        HStack {
          Text("이 중 예상 금액(기준환율)").textRole(.supporting)
          Spacer()
          Text(Won.text(estimated)).textRole(.supporting).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settlement-estimated")
      }
    } header: {
      Text("송금").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
    }
  }

  @ViewBuilder private func excludedSection(
    _ excluded: [ExcludedExpense], describe: @escaping (String) -> (String?, String, String)?
  ) -> some View {
    if !excluded.isEmpty {
      Section {
        ForEach(Array(excluded.enumerated()), id: \.offset) { index, x in
          let d = describe(x.expenseID)
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(d?.0 ?? "가게 이름 없음").textRole(.body)
            Text([d?.1, d?.2].compactMap { $0 }.joined(separator: " · ")).textRole(.caption).foregroundStyle(.secondary)
            Text(x.kind == .held ? "보류: \(x.reason ?? "")" : "개인 지출(결제자 혼자 부담)")
              .textRole(.caption).foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("excluded-\(index + 1)")
        }
      } header: {
        Text("제외된 지출").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      } footer: {
        Text("보류한 지출과 개인 지출은 송금에 들어가지 않아요.").textRole(.supporting)
      }
    }
  }
}

extension RoomLoadFailure {
  var message: String {
    switch self {
    case .sessionExpired: "로그인이 만료됐어요. 다시 로그인해 주세요."
    case .notFound: "이 여행방을 볼 수 없어요. 여행방 구성원인지 확인해 주세요."
    case .network: "인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요."
    case .unavailable: "지금은 여행방을 불러올 수 없어요. 잠시 후 다시 시도해 주세요."
    case .unknown: "여행방을 불러오지 못했어요. 다시 시도해 주세요."
    }
  }
}

extension SettlementFailure {
  var message: String {
    switch self {
    case .sessionExpired: "로그인이 만료됐어요. 다시 로그인한 뒤 다시 시도해 주세요."
    case .notFound: "이 여행방이나 지출을 볼 수 없어요."
    case .hostOnly: "방장만 할 수 있어요."
    case .stale: "다른 변경이 먼저 저장됐어요. 최신 내용을 확인하고 다시 시도해 주세요."
    case .pendingReview: "확인 필요 지출이 남아 확정할 수 없어요."
    case .finalized: "이미 확정된 정산이에요. 확정된 송금표를 확인해 주세요."
    case .rejected: "저장하지 못했어요. 결제자·원화·부담 금액을 다시 확인해 주세요."
    case .quoteChanged: "기준환율 고시값이 새로 들어와 예상 금액이 바뀌었어요. 새 금액을 확인하고 다시 저장해 주세요."
    case .fxCorrectionRequired: "기준환율이 정정된 예상 금액이 있어 확정하지 않았어요. 지출마다 고정 금액 유지나 새 예상 금액 적용을 골라 주세요."
    case .fxReplacementUnavailable: "정정 뒤 쓸 수 있는 기준환율이 없어요. 실제 청구액·환전 원가로 포함하거나 보류해 주세요."
    case .fxNothingToKeep: "이미 정해졌거나 고시값이 다시 바뀌었어요. 최신 내용을 확인해 주세요."
    case .uploaderOnly: "이 지출을 올린 사람만 품목 나누기 제안을 보낼 수 있어요."
    case .network: "인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요."
    case .unavailable: "지금은 저장할 수 없어요. 잠시 후 다시 시도해 주세요."
    case .unknown: "저장하지 못했어요. 다시 시도해 주세요."
    }
  }
}
