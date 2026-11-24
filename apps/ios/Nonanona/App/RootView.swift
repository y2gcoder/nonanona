import SwiftUI

/// 목록(홈)과 고른 화면. 넓은 창(가로 regular)에서는 나란히, 좁거나 낮은 창에서는 한 화면씩 쌓인다.
/// `NavigationSplitView`가 크기 종류에 따라 접고 펴며 접히는 부분(예약 영역)에 맞춰 열 폭을 정한다.
/// 고른 화면은 모델의 `selection`(안정 ID)이므로 창 크기·접기·회전이 바뀌어도 같은 화면이 남는다.
struct RootView: View {
  @Bindable var model: AppModel

  private func debugConfirm(_ draftID: String) -> ((String) -> Void)? {
    #if DEBUG
      return { model.debugConfirmWithSuggestions(draftID: draftID, itemID: $0) }
    #else
      return nil
    #endif
  }

  var body: some View {
    NavigationSplitView {
      HomeView(model: model)
        // 목록을 숨겨 고른 화면이 창 전체(접히는 부분 포함)를 쓰는 일이 없게 한다. 두 열은 시스템이 접힘에 맞춘다.
        .toolbar(removing: .sidebarToggle)
    } detail: {
      // 상세 열 안의 쌓기: 초안(영수증 목록) 위에 영수증 검토를 올린다. 좁은 창에서는 분할 보기가 목록 위에 이어 쌓는다.
      NavigationStack {
        detail
          .navigationDestination(item: $model.reviewing) { target in
            // 모델을 자기 body에서 읽는 뷰로 둔다. 목적지 클로저는 모델이 바뀌어도 다시 불리지 않아, 값을 클로저에서 만들면
            // 화면이 예전 값에 머물고 입력 칸이 그 값(빈 글자)을 다시 써 버린다(시뮬레이터에서 재현).
            ReviewDestination(model: model, target: target).id(target)
          }
          // 장부 위에 지출 검토, 송금표가 쌓인다(모델의 안정 ID로만 가리켜 배치가 바뀌어도 같은 화면이 남는다).
          .navigationDestination(
            item: Binding(get: { model.rooms.reviewing }, set: { model.rooms.reviewing = $0 })
          ) { target in
            ExpenseReviewDestination(model: model, rooms: model.rooms, target: target).id(target)
          }
          .navigationDestination(
            item: Binding(get: { model.rooms.settlementShown }, set: { model.rooms.settlementShown = $0 })
          ) { trip in
            SettlementDestination(rooms: model.rooms, trip: trip).id(trip)
          }
          // 장부 위에 올린 사람(회원)의 품목 나누기 제안(ADR-0011).
          .navigationDestination(item: $model.proposalSplit) { split in
            ItemSplitDestination(model: model, rooms: model.rooms, split: split).id(split)
          }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .tint(.primary)
    #if DEBUG
      .background(DebugHingeLog())
    #endif
    .modifier(uploadConfirmation)
    .alert(
      "정산을 확정할까요?",
      isPresented: Binding(
        get: { model.rooms.finalizeConfirmation != nil }, set: { if !$0 { model.rooms.finalizeConfirmation = nil } }),
      presenting: model.rooms.finalizeConfirmation
    ) { trip in
      Button("확정") { Task { await model.rooms.finalize(trip) } }.accessibilityIdentifier("finalize-confirm")
      Button("취소", role: .cancel) { model.rooms.finalizeConfirmation = nil }
    } message: { _ in
      Text("지금 미리보기의 송금표로 고정돼요. 확정한 뒤에는 지출을 더하거나 고칠 수 없어요.")
    }
    .alert(
      "방장에게 제안을 보낼까요?",
      isPresented: Binding(
        get: { model.proposalConfirmation != nil }, set: { if !$0 { model.proposalConfirmation = nil } }),
      presenting: model.proposalConfirmation.flatMap { split in model.proposalRequest(split).map { (split, $0) } }
    ) { shown in
      Button("보내기") { Task { await model.confirmProposalSend(shown.0, shown.1) } }
        .accessibilityIdentifier("proposal-send-confirm")
      Button("취소", role: .cancel) { model.proposalConfirmation = nil }
    } message: { shown in
      Text(proposalConsentText(shown.1, trip: shown.0.expense.tripID))
    }
    .sheet(
      isPresented: Binding(
        get: { model.login != .hidden },
        set: { if !$0 { model.dismissLogin() } })
    ) {
      LoginSheet(
        state: model.login, providers: model.signInProviders, testOnlyNotice: model.testOnlyNotice,
        onSignIn: { provider in Task { await model.signIn(with: provider) } },
        onCancel: model.dismissLogin)
    }
  }

  /// 보낼 값을 그대로 보인다: 사람마다 원, 원화 기준과 합계. 품목 정보는 보내지 않는다는 것을 함께 알린다.
  private func proposalConsentText(_ request: ShareProposalRequest, trip: TripID) -> String {
    let ledger = model.rooms.ledgers[trip]
    let lines = request.shares.map { "\(ledger?.name(of: $0.member) ?? "") \(Won.text($0.krw))" }.joined(
      separator: ", ")
    let basis: String =
      switch request.basis {
      case .krwOriginal: "원화 결제"
      case .referenceEstimate: "기준환율 예상 금액"
      case .verifiedCharge: "방장이 확인한 실제 청구액"
      case .acquisitionCost: "방장이 확인한 환전 원가"
      }
    return "\(lines) (합계 \(Won.text(request.krwTotal)), \(basis)). 사람마다 금액만 보내고 품목 이름·품목 금액·영수증 글자는 보내지 않아요. "
      + "방장이 확인하고 포함해야 정산에 들어가요."
  }

  /// 최종 확인은 한 곳(여기)에서만 띄운다. 개발용 화면이 없는 release에서는 아무것도 하지 않는다.
  private var uploadConfirmation: some ViewModifier {
    #if DEBUG
      DebugUploadConfirmation(
        confirmation: model.uploadConfirmation, onConfirm: model.confirmUpload, onCancel: model.cancelUploadConfirmation
      )
    #else
      EmptyModifier()
    #endif
  }

  @ViewBuilder private var detail: some View {
    switch model.selection {
    case .draft(let id):
      if let draft = model.drafts.first(where: { $0.id == id }) {
        DraftView(
          draft: draft, photoURLs: model.graph.drafts.photoURLs(of: draft),
          processing: model.processing[draft.id],
          rowSummary: { model.rowSummaries[ReviewTarget(draftID: draft.id, itemID: $0)] },
          reviewFinished: model.reviewFinished.contains(draft.id),
          manualEntryCount: model.manualEntryCount(draftID: draft.id),
          onOpen: { model.openReview(ReviewTarget(draftID: draft.id, itemID: $0)) },
          onStartReview: { model.startReview(draftID: draft.id) },
          onRetry: { model.retryPhoto(draftID: draft.id, itemID: $0) },
          onDebugConfirm: debugConfirm(draft.id),
          upload: DraftUploadContext(
            destination: model.room,
            confirmedCount: model.confirmedCount(draftID: draft.id),
            state: model.uploads[draft.id] ?? .idle,
            signedIn: model.session != nil,
            onRequest: { Task { await model.requestUpload(draftID: draft.id) } },
            onLogin: model.showLogin,
            manualState: model.manualUploads[draft.id] ?? .idle,
            onRequestManual: { Task { await model.requestManualUpload(draftID: draft.id) } }))
      } else {
        DetailPlaceholder()
      }
    case .invite:
      InviteView(
        signedIn: model.session != nil, join: model.join,
        onLogin: model.showLogin,
        onJoin: { Task { await model.joinPendingInvite() } })
    case .room:
      if let room = model.room, let ledger = model.rooms.ledgers[room.id] {
        RoomLedgerView(
          ledger: ledger, localDraftCount: model.drafts.count,
          loading: model.rooms.loadingLedger.contains(room.id), failure: model.rooms.ledgerFailure[room.id],
          onReview: { model.rooms.openReview(ExpenseTarget(tripID: room.id, expenseID: $0)) },
          onSettlement: { model.rooms.openSettlement(room.id) },
          onRefresh: { await model.refreshRoom(room.id) },
          canPropose: { model.canProposeItems($0, in: ledger) },
          onPropose: { model.openItemProposal(ExpenseTarget(tripID: room.id, expenseID: $0)) })
      } else if let room = model.room {
        TripRoomView(room: room, localDraftCount: model.drafts.count)
      } else {
        DetailPlaceholder()
      }
    case nil:
      DetailPlaceholder()
    }
  }
}

/// 검토 화면 목적지. 모델(@Observable)을 body에서 읽어, 처리 상태·입력이 바뀌면 다시 그린다.
private struct ReviewDestination: View {
  @Bindable var model: AppModel
  let target: ReviewTarget

  var body: some View {
    if let item = model.item(target), let draft = model.drafts.first(where: { $0.id == target.draftID }),
      let manifest = model.processing[target.draftID]
    {
      ReceiptReviewView(
        content: ReceiptReviewContent(
          item: item,
          photoURL: model.graph.drafts.photoURLs(of: draft)[item.position - 1],
          proposal: model.proposals[target],
          review: model.resolvedReview(target),
          problems: item.state == .ready || item.state == .failed ? model.fieldProblems(target) : [],
          preview: model.previews[target],
          confirmedArtifact: model.confirmedArtifacts[target],
          confirmedCount: manifest.count(.confirmed),
          totalCount: manifest.items.count,
          readyCount: manifest.count(.ready),
          busy: model.confirming != nil,
          saveFailed: model.draftSaveFailed.contains(target),
          confirmFailed: model.confirmFailed.contains(target)),
        showsMaskedPreview: $model.showsMaskedPreview,
        actions: ReceiptReviewActions(
          edit: { model.edit(target, $0) },
          requestPreview: { model.requestPreview(target) },
          retry: { model.retryPhoto(draftID: target.draftID, itemID: target.itemID) },
          retrySave: { model.retrySave(target) },
          confirmAndNext: { Task { await model.confirmAndNext(target) } }))
    }
  }
}

/// 지출 검토 목적지. 모델을 body에서 읽어 입력·저장 상태가 바뀌면 다시 그린다.
private struct ExpenseReviewDestination: View {
  @Bindable var model: AppModel
  @Bindable var rooms: RoomModel
  let target: ExpenseTarget

  var body: some View {
    if let ledger = rooms.ledgers[target.tripID], let expense = rooms.expense(target), let form = rooms.forms[target] {
      ExpenseReviewView(
        expense: expense, ledger: ledger, form: form, state: rooms.reviewState[target],
        refreshed: rooms.reviewRefreshed.contains(target),
        edit: { rooms.editForm(target, $0) },
        onInclude: { Task { await rooms.include(target) } },
        onHold: { reason in Task { await rooms.hold(target, reason: reason) } },
        receipt: rooms.receiptViews[target],
        onShowReceipt: { Task { await rooms.showReceipt(target) } },
        onHideReceipt: { rooms.hideReceipt(target) },
        onKeepEstimate: { Task { await rooms.keepEstimate(target) } },
        onApplyEstimate: { Task { await rooms.applyNewEstimate(target) } },
        itemSplitAvailable: model.localReceipt(for: expense) != nil,
        onOpenItemSplit: { model.openItemSplit(target) },
        onFillProposal: { rooms.fillFromProposal(target) }
      )
      // 지출 검토 위에 품목별 나누기(이 기기에서 올린 영수증만). 검토 화면에 붙여, 닫으면 검토로 돌아온다
      // (뿌리 화면에 붙이면 닫을 때 검토까지 함께 닫힌다 — 시뮬레이터에서 재현).
      .navigationDestination(item: $model.itemSplit) { split in
        ItemSplitDestination(model: model, rooms: rooms, split: split).id(split)
      }
    }
  }
}

/// 품목별 나누기 목적지. 품목 계획(기기 안)과 방장 검토 입력(원화·결제자·구성원)을 body에서 읽어 바뀌면 다시 계산한다.
private struct ItemSplitDestination: View {
  @Bindable var model: AppModel
  @Bindable var rooms: RoomModel
  let split: ItemSplitTarget

  var body: some View {
    let ledger = rooms.ledgers[split.expense.tripID]
    let expense = rooms.expense(split.expense)
    let form = rooms.forms[split.expense]
    let isProposal = split.purpose == .proposal
    let basis = model.proposalBasis(split)
    let proposalKRW: Int? = if case .ready(_, let krw, _) = basis { krw } else { nil }
    ItemSplitView(
      content: ItemSplitContent(
        plan: model.itemPlans[split.receipt],
        people: (ledger?.members ?? []).map { ItemSplitPerson(id: $0.id.value, name: $0.displayName) },
        krw: isProposal ? proposalKRW : expense.flatMap { form?.krw(for: $0) },
        allocation: model.itemAllocation(split),
        translation: model.itemTranslation[split.receipt],
        translatorLabel: model.graph.itemTranslator.label,
        translatorIsPreview: model.graph.itemTranslator.source == .preview,
        saveFailed: model.itemPlanSaveFailed.contains(split.receipt),
        loadFailure: model.itemPlanLoadFailed[split.receipt],
        proposal: isProposal
          ? ItemProposalPanel(
            basis: basis, remainderChoice: model.proposalRemainder(split)?.value,
            request: model.proposalRequest(split), sent: expense?.shareProposal,
            sendState: rooms.proposalState[split.expense]) : nil),
      actions: ItemSplitActions(
        edit: { model.editItemPlan(split.receipt, $0) },
        retrySave: { model.retryItemPlanSave(split.receipt) },
        retryLoad: { model.retryItemPlanLoad(split.receipt) },
        translate: { Task { await model.translateItemNames(split.receipt) } },
        recheckTranslation: { Task { await model.checkTranslation(split.receipt) } },
        apply: { model.applyItemSplit(split) },
        chooseRemainder: { model.chooseProposalRemainder(split, MemberID(value: $0)) },
        propose: { model.requestProposalSend(split) }))
  }
}

private struct SettlementDestination: View {
  @Bindable var rooms: RoomModel
  let trip: TripID

  var body: some View {
    SettlementView(
      ledger: rooms.ledgers[trip], preview: rooms.previews[trip], final: rooms.finals[trip],
      state: rooms.settlementState[trip], refreshed: rooms.finalizeRefreshed.contains(trip),
      onFinalize: { rooms.requestFinalize(trip) },
      onRefresh: { await rooms.loadSettlement(trip) },
      onOpenExpense: { rooms.openCorrection(trip, expenseID: $0) })
  }
}

/// 넓은 창에서 아직 아무것도 고르지 않았을 때 목록 옆에 보인다. 좁은 창에서는 보이지 않는다.
private struct DetailPlaceholder: View {
  var body: some View {
    ContentUnavailableView {
      Text("초안을 골라 주세요").textRole(.sectionTitle)
    } description: {
      Text("목록에서 초안을 고르면 여기에 보여요.").textRole(.supporting)
    }
    .accessibilityIdentifier("detail-placeholder")
  }
}
