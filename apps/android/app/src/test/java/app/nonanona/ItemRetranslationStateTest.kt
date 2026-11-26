package app.nonanona

import app.nonanona.feature.receiptimport.ItemPlan
import app.nonanona.feature.receiptimport.ItemPlanLine
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.receiptimport.StoredItemRetranslation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class ItemRetranslationStateTest {
    @get:Rule val tmp = TemporaryFolder()

    private val receipt = Route.Receipt("draft-a", "photo-01")
    private val first = line("ocr-1", "焼き鳥")
    private val second = line("ocr-2", "枝豆")
    private val third = line("ocr-3", "水")

    @Test
    fun reopenedStoreKeepsOnlyMatchingOriginalsAndRetainsUnavailableRows() =
        runBlocking {
            val root = tmp.newFolder()
            ReceiptDraftStore(root).saveRetranslation(
                receipt.draftId,
                receipt.itemId,
                StoredItemRetranslation(true, listOf(first, second, third), mapOf(first.id to "닭꼬치", second.id to "풋콩")),
            )
            val store = ReceiptDraftStore(root)
            val plan = plan(first.copy(originalName = "唐揚げ"), second, third)
            val state = state(store, { plan })

            val unrelated = Route.Receipt("draft-b", receipt.itemId)
            state.restore(unrelated)
            assertNull(state.sessions.value[unrelated])
            state.restore(receipt)

            val restored = state.sessions.value.getValue(receipt)
            assertEquals(listOf(second, third), restored.selected)
            assertEquals(mapOf(second.id to "풋콩"), (restored.phase as RetranslationPhase.Results).suggestions)
            assertEquals(listOf(second, third), store.loadRetranslation(receipt.draftId, receipt.itemId)?.lines)
        }

    @Test
    fun onlyExplicitlyAcceptedRowChangesAndRemainingRowsRestore() =
        runBlocking {
            val root = tmp.newFolder()
            val store = ReceiptDraftStore(root)
            var plan = plan(first, second, third)
            val state =
                state(
                    store,
                    { plan },
                    translate = { listOf("닭꼬치", "풋콩", null) },
                    apply = { snapshot, name ->
                        val updated = plan.acceptRetranslation(name, snapshot)
                        val result = if (updated === plan) RetranslationApply.Changed else RetranslationApply.Applied
                        plan = updated
                        result
                    },
                )

            state.restore(receipt)
            state.open(receipt, plan.lines)
            plan.lines.forEach { state.select(receipt, it.id, true) }
            state.confirm(receipt)
            state.awaitSession { it?.phase is RetranslationPhase.Results }
            assertEquals(listOf(first, second, third), plan.lines)
            state.accept(receipt, first.id)
            state.awaitSession { (it?.phase as? RetranslationPhase.Results)?.accepted == mapOf(first.id to true) }
            assertEquals("닭꼬치", plan.line(first.id)?.name)
            assertEquals(second, plan.line(second.id))
            assertEquals(third, plan.line(third.id))

            val restored = state(ReceiptDraftStore(root), { plan })
            restored.restore(receipt)
            assertEquals(
                listOf(second, third),
                restored.sessions.value
                    .getValue(receipt)
                    .selected,
            )
            restored.close(receipt)
            restored.awaitSession { it == null }
            assertNull(store.loadRetranslation(receipt.draftId, receipt.itemId))
        }

    @Test
    fun interruptedBatchRetryUsesAllCurrentEligibleRowsAndKeepsThePreviousSelection() =
        runBlocking {
            val store = ReceiptDraftStore(tmp.newFolder())
            store.saveRetranslation(
                receipt.draftId,
                receipt.itemId,
                StoredItemRetranslation(true, listOf(first), suggestions = null),
            )
            var currentPlan = plan(first, second)
            val state =
                state(store, { currentPlan }, translate = { names ->
                    assertEquals(listOf(first.originalName, third.originalName), names)
                    listOf("닭꼬치", "물")
                })
            state.restore(receipt)
            assertEquals(RetranslationPhase.Unavailable, state.sessions.value[receipt]?.phase)

            val updatedFirst = first.copy(amountText = "450")
            val excluded = line("ocr-4", "お茶").copy(excluded = true)
            val unnamed = line("ocr-5", "")
            currentPlan = plan(second, updatedFirst, third, excluded, unnamed)
            state.retry(receipt)
            val consent = state.sessions.value.getValue(receipt)
            assertEquals(RetranslationPhase.Consent, consent.phase)
            assertTrue(consent.batch)
            assertEquals(listOf(second, updatedFirst, third), consent.lines)
            assertEquals(listOf(updatedFirst), consent.selected)

            state.select(receipt, third.id, true)
            state.confirm(receipt)
            state.awaitSession { it?.phase is RetranslationPhase.Results }
            assertEquals(listOf(updatedFirst, third), store.loadRetranslation(receipt.draftId, receipt.itemId)?.lines)
        }

    @Test
    fun resultIsDiscardedWhenOnlyOriginalChanges() =
        runBlocking {
            val store = ReceiptDraftStore(tmp.newFolder())
            store.saveRetranslation(
                receipt.draftId,
                receipt.itemId,
                StoredItemRetranslation(false, listOf(first), mapOf(first.id to "닭꼬치")),
            )
            val state = state(store, { plan(first.copy(originalText = "焼き鳥 800")) })
            state.restore(receipt)
            assertNull(state.sessions.value[receipt])
            assertNull(store.loadRetranslation(receipt.draftId, receipt.itemId))
        }

    @Test
    fun alreadySavedNameIsNotOfferedAfterInterruptionDuringCleanup() =
        runBlocking {
            val store = ReceiptDraftStore(tmp.newFolder())
            store.saveRetranslation(
                receipt.draftId,
                receipt.itemId,
                StoredItemRetranslation(false, listOf(first), mapOf(first.id to "닭꼬치")),
            )
            val plan = plan(first).acceptRetranslation("닭꼬치", first)
            val state = state(store, { plan })
            state.restore(receipt)
            assertNull(state.sessions.value[receipt])
            assertNull(store.loadRetranslation(receipt.draftId, receipt.itemId))
        }

    @Test
    fun requestWaitsForMarkerAndOnlyConfirmRetriesTheWrite() =
        runBlocking {
            var blocked = true
            val store = ReceiptDraftStore(tmp.newFolder(), writeFault = { blocked })
            var calls = 0
            val state =
                state(
                    store,
                    { plan(first) },
                    translate = {
                        calls++
                        val saved = store.loadRetranslation(receipt.draftId, receipt.itemId)
                        assertEquals(listOf(first), saved?.lines)
                        assertNull(saved?.suggestions)
                        listOf("닭꼬치")
                    },
                )
            state.restore(receipt)
            state.open(receipt, listOf(first))
            state.confirm(receipt)
            state.awaitSession { it?.failure != null }
            assertEquals(0, calls)
            assertEquals(
                RetranslationPhase.Consent,
                state.sessions.value
                    .getValue(receipt)
                    .phase,
            )

            blocked = false
            state.retryFailure(receipt)
            assertEquals(RetranslationPhase.Consent, state.sessions.value[receipt]?.phase)
            assertEquals(0, calls)

            state.confirm(receipt)
            state.awaitSession { it?.phase is RetranslationPhase.Results }
            assertEquals(1, calls)
            val stored = store.loadRetranslation(receipt.draftId, receipt.itemId)
            assertEquals(mapOf(first.id to "닭꼬치"), stored?.suggestions)
            assertNull(
                state.sessions.value
                    .getValue(receipt)
                    .failure,
            )
        }

    @Test
    fun adapterCancellationLeavesRequestingAndClearsMarker() =
        runBlocking {
            val store = ReceiptDraftStore(tmp.newFolder())
            val state = state(store, { plan(first) }, translate = { throw CancellationException("adapter cancelled") })
            state.restore(receipt)
            state.open(receipt, listOf(first))
            state.confirm(receipt)
            state.awaitSession { it?.phase == RetranslationPhase.Unavailable }
            assertNull(store.loadRetranslation(receipt.draftId, receipt.itemId))
        }

    @Test
    fun stalledTranslationStopsAtFortySeconds() =
        runBlocking {
            val store = ReceiptDraftStore(tmp.newFolder())
            val state = state(store, { plan(first) }, translate = { awaitCancellation() })
            state.restore(receipt)
            state.open(receipt, listOf(first))
            state.confirm(receipt)
            withTimeout(45_000) { state.sessions.first { it[receipt]?.phase == RetranslationPhase.Unavailable } }
            assertNull(store.loadRetranslation(receipt.draftId, receipt.itemId))
        }

    @Test
    fun retryAfterFailedApplySavesTheNameOrKeepsTheFailureVisible() =
        runBlocking {
            val store = ReceiptDraftStore(tmp.newFolder())
            var currentPlan = plan(first)
            var attempts = 0
            val state =
                state(store, { currentPlan }, translate = { listOf("닭꼬치") }, apply = { snapshot, name ->
                    attempts++
                    if (attempts < 3) {
                        RetranslationApply.SaveFailed
                    } else {
                        currentPlan = currentPlan.acceptRetranslation(name, snapshot)
                        RetranslationApply.Applied
                    }
                })
            state.restore(receipt)
            state.open(receipt, listOf(first))
            state.confirm(receipt)
            state.awaitSession { it?.phase is RetranslationPhase.Results }
            state.accept(receipt, first.id)
            state.awaitSession { it?.failure != null }

            state.retryFailure(receipt)
            state.awaitSession { it?.saving == false }
            assertEquals(first, currentPlan.line(first.id))
            assertEquals(
                RetranslationFailure.Apply(first.id),
                state.sessions.value
                    .getValue(receipt)
                    .failure,
            )
            assertEquals(2, attempts)

            state.retryFailure(receipt)
            state.awaitSession { it == null }
            assertEquals("닭꼬치", currentPlan.line(first.id)?.name)
            assertNull(store.loadRetranslation(receipt.draftId, receipt.itemId))
        }

    @Test
    fun failureAndChangedPermitImplicitDismissalExceptDuringSaveOrDeleteFailure() {
        for (phase in listOf(RetranslationPhase.Unavailable, RetranslationPhase.Changed)) {
            val session = ItemRetranslationSession(listOf(first), phase = phase, ownsRecord = true)
            assertTrue(session.canDismissImplicitly)
            assertTrue(!session.copy(saving = true).canDismissImplicitly)
            assertTrue(!session.copy(failure = RetranslationFailure.Delete(dismiss = true)).canDismissImplicitly)
        }
    }

    @Test
    fun malformedFileShowsFailureWithoutSendingAutomatically() =
        runBlocking {
            val root = tmp.newFolder()
            val invalid = root.resolve("drafts/${receipt.draftId}/retranslations/${receipt.itemId}.json")
            requireNotNull(invalid.parentFile).mkdirs()
            invalid.writeText("{")
            var requests = 0
            val state =
                state(ReceiptDraftStore(root), { plan(first) }, translate = {
                    requests++
                    listOf("닭꼬치")
                })
            state.restore(receipt)
            assertEquals(RetranslationPhase.Unavailable, state.sessions.value[receipt]?.phase)
            assertEquals(0, requests)
        }

    @Test
    fun retryAfterFailedCloseDeletesResultAndCloses() =
        runBlocking {
            val root = tmp.newFolder()
            val store = ReceiptDraftStore(root)
            store.saveRetranslation(
                receipt.draftId,
                receipt.itemId,
                StoredItemRetranslation(false, listOf(first), mapOf(first.id to "닭꼬치")),
            )
            val state = state(store, { plan(first) })
            state.restore(receipt)
            val staging = root.resolve("drafts/${receipt.draftId}/retranslations/.${receipt.itemId}.json.partial")
            assertTrue(staging.mkdir())
            staging.resolve("blocked").writeText("fixture")
            state.close(receipt)
            state.awaitSession { it?.failure != null }
            assertTrue(staging.deleteRecursively())
            state.retryFailure(receipt)
            state.awaitSession { it == null }
            assertNull(store.loadRetranslation(receipt.draftId, receipt.itemId))
        }

    @Test
    fun retryAfterFailedResultWritePersistsTheSameSuggestion() =
        runBlocking {
            var writes = 0
            val store = ReceiptDraftStore(tmp.newFolder(), writeFault = { ++writes == 2 })
            var requests = 0
            val state =
                state(store, { plan(first) }, translate = {
                    requests++
                    listOf("닭꼬치")
                })
            state.restore(receipt)
            state.open(receipt, listOf(first))
            state.confirm(receipt)
            state.awaitSession { it?.failure != null }
            assertNull(store.loadRetranslation(receipt.draftId, receipt.itemId)?.suggestions)
            state.retryFailure(receipt)
            state.awaitSession { it?.saving == false && it.failure == null }
            assertEquals(1, requests)
            assertEquals(mapOf(first.id to "닭꼬치"), store.loadRetranslation(receipt.draftId, receipt.itemId)?.suggestions)
        }

    @Test
    fun restoredBatchSkipsAppliedLineAndAppliesRemainingSnapshot() =
        runBlocking {
            val root = tmp.newFolder()
            ReceiptDraftStore(root).saveRetranslation(
                receipt.draftId,
                receipt.itemId,
                StoredItemRetranslation(true, listOf(first, second), mapOf(first.id to "닭꼬치", second.id to "풋콩")),
            )
            val store = ReceiptDraftStore(root)
            var plan = plan(first, second).acceptRetranslation("닭꼬치", first)
            val state =
                state(store, { plan }, apply = { snapshot, name ->
                    val updated = plan.acceptRetranslation(name, snapshot)
                    if (updated === plan) {
                        RetranslationApply.Changed
                    } else {
                        plan = updated
                        RetranslationApply.Applied
                    }
                })
            state.restore(receipt)
            assertEquals(
                listOf(second),
                state.sessions.value
                    .getValue(receipt)
                    .selected,
            )
            state.accept(receipt, second.id)
            state.awaitSession { (it?.phase as? RetranslationPhase.Results)?.accepted == mapOf(second.id to true) }
            assertEquals("닭꼬치", plan.line(first.id)?.name)
            assertEquals("풋콩", plan.line(second.id)?.name)
            assertNull(store.loadRetranslation(receipt.draftId, receipt.itemId))
        }

    @Test
    fun rejectedApplyKeepsProposalAndStoredSnapshot() =
        runBlocking {
            val root = tmp.newFolder()
            val store = ReceiptDraftStore(root)
            var plan = plan(first)
            val state =
                state(store, { plan }, translate = { listOf("닭꼬치") }, apply = { snapshot, name ->
                    assertTrue(plan.acceptRetranslation(name, snapshot) === plan)
                    RetranslationApply.Changed
                })
            state.restore(receipt)
            state.open(receipt, listOf(first))
            state.confirm(receipt)
            state.awaitSession { it?.phase is RetranslationPhase.Results }
            plan = plan.setAmount(first.id, "200")
            state.accept(receipt, first.id)
            state.awaitSession { (it?.phase as? RetranslationPhase.Results)?.accepted == mapOf(first.id to false) }
            assertEquals("200", plan.line(first.id)?.amountText)
            val saved = store.loadRetranslation(receipt.draftId, receipt.itemId)
            assertEquals(listOf(first), saved?.lines)
            assertEquals("닭꼬치", saved?.suggestions?.get(first.id))
        }

    @Test
    fun opensOnlyAfterTheSameReceiptFinishesRestoring() =
        runBlocking {
            val reading = CompletableDeferred<Unit>()
            val resumeRead = CountDownLatch(1)
            val store =
                ReceiptDraftStore(tmp.newFolder(), readFault = {
                    reading.complete(Unit)
                    check(resumeRead.await(5, TimeUnit.SECONDS))
                    false
                })
            val stale = StoredItemRetranslation(false, listOf(first.copy(originalText = "古い")), suggestions = null)
            store.saveRetranslation(receipt.draftId, receipt.itemId, stale)
            val state = state(store, { plan(first) })

            state.open(receipt, listOf(first))
            assertNull("복원 시작 전", state.sessions.value[receipt])
            val restore = launch { state.restore(receipt) }
            try {
                withTimeout(5_000) { reading.await() }
                assertEquals(RetranslationRestore.Restoring, state.restores.value[receipt])
                state.open(receipt, listOf(first))
                assertNull("기록을 읽는 동안", state.sessions.value[receipt])
            } finally {
                resumeRead.countDown()
            }
            restore.join()

            val other = Route.Receipt(receipt.draftId, "photo-02")
            state.open(other, listOf(first))
            assertNull("아직 복원하지 않은 다른 영수증", state.sessions.value[other])
            state.open(receipt, listOf(first))
            assertEquals(RetranslationPhase.Consent, state.sessions.value[receipt]?.phase)
        }

    @Test
    fun transientReadFailureKeepsTheFileAndOffersReload() =
        runBlocking {
            var blocked = true
            val store = ReceiptDraftStore(tmp.newFolder(), readFault = { blocked })
            val stored = StoredItemRetranslation(false, listOf(first), mapOf(first.id to "닭꼬치"))
            store.saveRetranslation(receipt.draftId, receipt.itemId, stored)
            val state = state(store, { plan(first) })
            state.restore(receipt)
            assertEquals(RetranslationRestore.Failed, state.restores.value[receipt])
            state.open(receipt, listOf(first))
            assertNull(state.sessions.value[receipt])

            blocked = false
            assertEquals(stored, store.loadRetranslation(receipt.draftId, receipt.itemId))
            state.reload(receipt)
            withTimeout(5_000) { state.restores.first { it[receipt] == RetranslationRestore.Ready } }
            assertEquals(RetranslationPhase.Results(mapOf(first.id to "닭꼬치")), state.sessions.value[receipt]?.phase)
            assertEquals(stored, store.loadRetranslation(receipt.draftId, receipt.itemId))
        }

    @Test
    fun dismissingFreshConsentDoesNotDeleteAnUnownedRecord() =
        runBlocking {
            val store = ReceiptDraftStore(tmp.newFolder())
            val state = state(store, { plan(first) })
            state.restore(receipt)
            state.open(receipt, listOf(first))
            val pending = StoredItemRetranslation(false, listOf(first), suggestions = null)
            store.saveRetranslation(receipt.draftId, receipt.itemId, pending)
            state.close(receipt)
            state.awaitSession { it == null }
            assertEquals(pending, store.loadRetranslation(receipt.draftId, receipt.itemId))
        }

    private fun CoroutineScope.state(
        store: ReceiptDraftStore,
        plan: () -> ItemPlan,
        translate: suspend (List<String>) -> List<String?> = { error("사용자 동의 없이 요청했어요") },
        apply: suspend (ItemPlanLine, String) -> RetranslationApply = { _, _ -> error("사용자 선택 없이 적용했어요") },
    ) = ItemRetranslationState(this, store, translate, { plan() }, { _, line, name -> apply(line, name) })

    private suspend fun ItemRetranslationState.awaitSession(matches: (ItemRetranslationSession?) -> Boolean) {
        withTimeout(5_000) { sessions.first { matches(it[receipt]) } }
    }

    private fun plan(vararg lines: ItemPlanLine) = ItemPlan("receipt-items-v1", "JPY", 300, null, emptyList(), lines.toList(), 1)

    private fun line(
        id: String,
        original: String,
    ) = ItemPlanLine(
        id = id,
        kind = ItemPlanLine.Kind.Item,
        sourceLineIds = listOf(id.substringAfter('-').toInt()),
        originalText = "$original 100",
        originalName = original,
        name = "",
        nameSource = ItemPlanLine.NameSource.None,
        amountText = "100",
        flags = emptyList(),
        checked = true,
        excluded = false,
        assignees = emptyList(),
    )
}
