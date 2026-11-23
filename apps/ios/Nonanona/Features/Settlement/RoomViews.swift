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

  private var pendingCount: Int { ledger.expenses.filter { $0.status == .pending }.count }

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
            row.accessibilityIdentifier("expense-\(index + 1)")
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
        Text("결제 \(ledger.name(of: expense.payer)) · \(Won.text(krw)) · \(sharesText)")
          .textRole(.caption).foregroundStyle(.secondary)
      }
      if case .held(let reason) = expense.status {
        Text("보류 사유: \(reason)").textRole(.caption).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var sharesText: String {
    "부담 " + expense.shares.map { "\(ledger.name(of: $0.member)) \(Won.text($0.krw))" }.joined(separator: ", ")
  }

  @ViewBuilder private var status: some View {
    switch expense.status {
    case .pending: StatusLabel("확인 필요", role: .attention)
    case .included: StatusLabel("포함", role: .positive)
    case .held: StatusLabel("보류", role: .neutral)
    }
  }
}

/// 방장 검토: 결제자, 원화(KRW는 그대로, 외화는 확인한 청구액), 부담(한 사람 · 둘이 반씩 · 직접 나누기)을 정하고
/// 포함하거나 사유와 함께 보류한다. 반씩 나누어떨어지지 않으면 직접 나누게 한다(남는 원을 고르지 않는다).
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

  @State private var askingHoldReason = false
  static let holdReasons = ["원화 청구액 확인 대기", "결제 여부 불명확", "같은 지출일 수 있음"]

  private var krw: Int? { form.krw(for: expense) }
  private var result: Result<[ShareLine], ShareProblem> { form.shares(for: expense, members: ledger.members) }
  private var saving: Bool { state == .saving }

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

      ReceiptAttachmentSection(
        hasArtifact: expense.artifact != nil, state: receipt, onShow: onShowReceipt, onHide: onHideReceipt)

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

      Section {
        if expense.currency == "KRW" {
          Text("원화 결제 · \(Won.text(expense.amountMinor))").textRole(.body).accessibilityIdentifier("review-krw-fixed")
        } else {
          TextField("실제 원화 청구액(원)", text: binding(\.verifiedKRWText))
            .keyboardType(.numberPad)
            .accessibilityIdentifier("review-krw")
        }
      } header: {
        Text("원화").textRole(.sectionTitle).foregroundStyle(.primary).textCase(nil)
      } footer: {
        if expense.currency != "KRW" {
          Text("카드·계좌에 찍힌 원화 금액을 넣어 주세요. 아직 모르면 보류해 주세요. 환율로 자동 계산하지 않아요.")
            .textRole(.supporting)
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
            Text("한 사람 \(Won.text(lines[0].krw)) · 합계 \(Won.text(krw))").textRole(.supporting)
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
    case .personMissing: return "부담할 사람을 골라 주세요."
    case .pairRequired: return "반씩 나눌 두 사람을 골라 주세요."
    case .notDivisible: return "반씩 나누면 1원이 남아요. 직접 나누기로 사람마다 금액을 적어 주세요."
    case .exactInvalid: return "부담 금액은 원 단위 숫자로 적어 주세요."
    case .exactMismatch(let remaining):
      return remaining > 0
        ? "\(Won.text(remaining))이 남았어요. 합계가 원화와 같아야 해요." : "\(Won.text(-remaining)) 넘어요. 합계가 원화와 같아야 해요."
    }
  }

  private func binding<T>(_ path: WritableKeyPath<ShareForm, T>) -> Binding<T> {
    Binding(get: { form[keyPath: path] }, set: { value in edit { $0[keyPath: path] = value } })
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
    transfersSection(preview.transfers, total: preview.includedTotalKRW) { ledger.name(of: $0) }
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
    transfersSection(final.transfers, total: final.includedTotalKRW) { final.name(of: $0) }
    excludedSection(final.excluded) { id in
      final.expense(id).map { ($0.merchant, $0.date, Won.original($0.amountMinor, $0.currency)) }
    }
  }

  @ViewBuilder private func transfersSection(
    _ transfers: [Transfer], total: Int, name: @escaping (MemberID) -> String
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
    case .network: "인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요."
    case .unavailable: "지금은 저장할 수 없어요. 잠시 후 다시 시도해 주세요."
    case .unknown: "저장하지 못했어요. 다시 시도해 주세요."
    }
  }
}
