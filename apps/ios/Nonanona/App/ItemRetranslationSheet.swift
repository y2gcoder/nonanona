import ReceiptImport
import SwiftUI

/// 품목 재번역 시트가 부르는 동작. 요청과 결과는 `ItemRetranslationModel`이 가진다(시트는 그리기만 한다).
struct ItemRetranslationActions {
  let toggle: (String) -> Void
  let confirm: () -> Void
  let retry: () -> Void
  let accept: (ItemPlanLine, String) -> Void
  /// 기기 저장에 실패한 일을 다시 한다(결과 쓰기·적용은 ‘다시 저장’, 기록 삭제는 ‘다시 시도’).
  var retrySave: () -> Void = {}
  /// ‘닫기’를 눌렀다.
  let close: () -> Void
  /// 시트가 단추가 아닌 길로 닫혔다(아래로 쓸기, 또는 화면이 빠지며 시스템이 닫음). 그 시트가 그리던 세션 ID를 넘긴다.
  var dismissed: (UUID) -> Void = { _ in }
}

extension ItemRetranslationActions {
  @MainActor init(model: ItemRetranslationModel, target: ReviewTarget) {
    self.init(
      toggle: { model.toggle(target, $0) }, confirm: { model.confirm(target) }, retry: { model.retry(target) },
      accept: { model.accept(target, $0, $1) }, retrySave: { model.retrySave(target) },
      close: { model.close(target) },
      dismissed: { model.dismissed(target, $0) })
  }
}

extension View {
  /// 모델에 재번역이 있으면 시트를 띄운다. 시트가 다시 만들어져도 같은 요청·결과를 그린다. 단추가 아닌 길로 닫히면
  /// 모델이 단계를 보고 정한다(요청 중·결과는 그대로 남고, 쉽게 닫히는 단계만 끝난다).
  func itemRetranslationSheet(_ session: ItemRetranslationSession?, _ actions: ItemRetranslationActions)
    -> some View
  {
    let shown = session?.id
    return sheet(
      isPresented: Binding(get: { session != nil }, set: { if !$0, let shown { actions.dismissed(shown) } })
    ) {
      if let session { ItemRetranslationSheet(session: session, actions: actions) }
    }
  }
}

struct ItemRetranslationSheet: View {
  let session: ItemRetranslationSession
  let actions: ItemRetranslationActions

  private var isBatch: Bool { session.isBatch }
  private var phase: ItemRetranslationSession.Phase { session.phase }

  var body: some View {
    NavigationStack {
      Form {
        if isBatch && phase == .consent {
          Section {
            previewDisclosure
            ForEach(session.candidates) { line in
              selectionButton(for: line)
            }
          } header: {
            Text("다시 번역할 품목")
          }
        } else {
          Section("선택한 품목명") {
            ForEach(session.shownLines) { line in
              VStack(alignment: .leading) {
                Text(line.originalName)
                  .accessibilityIdentifier(isBatch ? "retranslation-original-\(line.id)" : "retranslation-original")
                if phase == .results { result(for: line) }
              }
            }
          }
        }
        if session.saveFailed {
          Section {
            // 품목 계획 저장 실패와 같은 문구(Android `items_save_failed`). 단추는 Android와 같게 기록 삭제 실패면
            // ‘다시 시도’(`items_retranslation_retry`), 결과 저장·적용 실패면 ‘다시 저장’(`items_retry_save`)이다.
            Text("품목을 기기에 저장하지 못했어요.").textRole(.supporting).foregroundStyle(.red)
              .accessibilityIdentifier("retranslation-save-failed")
            if session.canRetrySave {
              Button(session.retriesClear ? "다시 시도" : "다시 저장", action: actions.retrySave)
                .disabled(session.saving)
                .accessibilityIdentifier("retranslation-retry-save")
            }
          }
        }
        Section {
          switch phase {
          case .consent:
            if !isBatch {
              previewDisclosure
              confirmButton
            }
          case .requesting:
            ProgressView("번역하는 중…")
          case .results:
            EmptyView()
          case .unavailable:
            Text("번역 제안을 받지 못했어요. 이름을 직접 적거나 다시 시도해 주세요.")
            // 저장 실패가 남아 있으면 그 일을 먼저 다시 한다(같은 이름의 단추를 둘 두지 않는다. Android와 같다).
            if !session.saveFailed {
              Button("다시 시도", action: actions.retry).disabled(session.saving)
                .accessibilityIdentifier("retranslation-retry")
            }
          case .changed:
            Text("품목이 바뀌었어요. 지금 품목을 확인한 뒤 다시 번역해 주세요.")
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        if isBatch && phase == .consent {
          VStack {
            Text("\(session.selection.count)개 선택 · 최대 \(ItemRetranslationSession.maximumSelection)개")
              .textRole(.supporting)
            confirmButton.buttonStyle(.borderedProminent)
          }
          .frame(maxWidth: .infinity)
          .padding()
          .background(.bar)
        }
      }
      .navigationTitle("품목명 다시 번역")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        // 요청 중에는 ‘닫기’를 쓸 수 없다(응답 뒤에만 ‘닫기’로 마친다).
        Button("닫기", action: actions.close).disabled(!session.canClose)
          .accessibilityIdentifier("retranslation-close")
      }
    }
    // 요청 중·결과 단계·삭제 실패가 남은 때는 바깥 터치·아래로 쓸기로 닫히지 않는다. 동의·줄 선택·실패·변경 안내는 쉽게 닫힌다.
    .interactiveDismissDisabled(session.blocksDismissal)
  }

  private var previewDisclosure: some View {
    Text("미리보기 대역이에요. 이 시험에서는 품목명을 외부로 보내지 않아요.").textRole(.supporting)
  }

  private var confirmButton: some View {
    Button("확인하고 다시 번역", action: actions.confirm)
      .disabled(session.selectedLines.isEmpty || session.saving)
      .accessibilityIdentifier("retranslation-confirm")
  }

  private func selectionButton(for line: ItemPlanLine) -> some View {
    let isSelected = session.selection.contains(line.id)
    let full = session.selection.count == ItemRetranslationSession.maximumSelection
    return Button {
      actions.toggle(line.id)
    } label: {
      HStack {
        Text(line.originalName)
        Spacer()
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isSelected && full)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("retranslation-select-\(line.id)")
  }

  @ViewBuilder private func result(for line: ItemPlanLine) -> some View {
    if let name = session.suggestions[line.id] {
      Text(name).accessibilityIdentifier(isBatch ? "retranslation-proposal-\(line.id)" : "retranslation-proposal")
      if let applied = session.accepted[line.id] {
        Text(applied ? "적용했어요." : "품목이 바뀌었어요. 다시 번역해 주세요.").textRole(.supporting)
      } else {
        Button("이 이름 사용") { actions.accept(line, name) }
          .buttonStyle(.bordered)
          .disabled(session.saving)
          .accessibilityIdentifier(isBatch ? "retranslation-accept-\(line.id)" : "retranslation-accept")
      }
    } else {
      Text("번역 제안이 없어 원문을 유지했어요.")
        .textRole(.supporting)
        .accessibilityIdentifier("retranslation-unavailable-\(line.id)")
    }
  }
}
