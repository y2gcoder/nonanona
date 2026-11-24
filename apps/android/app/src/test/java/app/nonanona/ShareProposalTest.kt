package app.nonanona

import app.nonanona.feature.receiptimport.ItemAllocation
import app.nonanona.feature.receiptimport.ItemMemberShare
import app.nonanona.feature.settlement.ExpenseStatus
import app.nonanona.feature.settlement.FxProposal
import app.nonanona.feature.settlement.KrwBasis
import app.nonanona.feature.settlement.KrwSource
import app.nonanona.feature.settlement.LedgerExpense
import app.nonanona.feature.settlement.MemberId
import app.nonanona.feature.settlement.ProposalBasis
import app.nonanona.feature.settlement.ProposalComparison
import app.nonanona.feature.settlement.ProposalShares
import app.nonanona.feature.settlement.ReferenceQuote
import app.nonanona.feature.settlement.RoomLedger
import app.nonanona.feature.settlement.SettlementFailure
import app.nonanona.feature.settlement.ShareForm
import app.nonanona.feature.settlement.ShareLine
import app.nonanona.feature.settlement.ShareMode
import app.nonanona.feature.settlement.SharePlan
import app.nonanona.feature.settlement.ShareProposal
import app.nonanona.feature.settlement.ShareProposalRequest
import app.nonanona.feature.settlement.ShareResult
import app.nonanona.feature.settlement.filledFrom
import app.nonanona.localbackend.LocalJson
import app.nonanona.localbackend.LocalSettlementGateway
import app.nonanona.localbackend.Outcome
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 품목 나누기 제안 몫(ADR-0011, iOS ShareProposalTests와 같은 시나리오): 실제 서버 응답(가상 값) 해석과 실패 시 닫힘,
 * 보내는 본문(품목 정보 없음), 요청 키(iOS와 같은 값), 원화 기준 묶기, 남은 원의 명시적 선택, 방장의 채우기·비교.
 */
class ShareProposalTest {
    private val root =
        generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "apps/fixtures/settlement/proposal-responses") }
            .first { it.isDirectory }
    private val host = MemberId("00000000-0000-4000-8000-00000000000a")
    private val uploader = MemberId("00000000-0000-4000-8000-00000000000b")

    private fun text(name: String) = File(root, name).readText()

    private fun ledger(json: String): RoomLedger? = runCatching { LocalJson.ledger(JSONObject(json)) }.getOrNull()

    private fun byMerchant(name: String) = ledger(text(name))!!.expenses.associateBy { it.merchant.orEmpty() }

    @Test
    fun hostAndUploaderSeeProposalsOtherMemberDoesNot() {
        val by = byMerchant("ledger-host.json")
        val krw = by.getValue("가상 분식").shareProposal!!
        assertEquals(ShareProposal.State.Current, krw.state)
        assertEquals(KrwBasis.KrwOriginal, krw.basis)
        assertEquals(10001L, krw.krwTotal)
        assertEquals(uploader, krw.proposedBy)
        assertEquals(10001L, krw.shares.sumOf { it.krw })
        val jpy = by.getValue("さくら食堂").shareProposal!!
        assertEquals(KrwBasis.ReferenceEstimate, jpy.basis)
        assertNotNull(jpy.fxQuoteId)
        assertEquals(ShareProposal.State.Applied, by.getValue("가상 카페").shareProposal!!.state)
        assertEquals(ShareProposal.State.StaleExpense, by.getValue("가상 편의점").shareProposal!!.state)
        assertTrue(ledger(text("ledger-uploader.json"))!!.expenses.all { it.shareProposal != null })
        assertTrue(ledger(text("ledger-other-member.json"))!!.expenses.all { it.shareProposal == null })
    }

    @Test
    fun malformedProposalFailsClosed() {
        val cases =
            mapOf<String, (JSONObject) -> Unit>(
                "unknown state" to { it.put("state", "accepted") },
                "sum mismatch" to { it.put("krw_total", 10002) },
                "zero share" to {
                    val s = it.getJSONArray("shares")
                    val first = s.getJSONObject(0).getLong("krw")
                    s.getJSONObject(0).put("krw", 0)
                    it.put("krw_total", it.getLong("krw_total") - first)
                },
                "duplicate member" to {
                    val s = it.getJSONArray("shares")
                    s.getJSONObject(1).put("user_id", s.getJSONObject(0).getString("user_id"))
                },
                "not the uploader" to { it.put("proposed_by", host.value) },
                "estimate without quote" to { it.put("krw_basis", "reference_rate_estimate") },
                "quote on KRW" to { it.put("fx_quote_id", "11111111-1111-4111-8111-111111111111") },
                "non-member" to { it.getJSONArray("shares").getJSONObject(0).put("user_id", "00000000-0000-4000-8000-0000000000ff") },
                "future version" to { it.put("expense_version", 99) },
                "unknown basis" to { it.put("krw_basis", "made_up") },
                "string amount" to { it.getJSONArray("shares").getJSONObject(0).put("krw", "6000") },
            )
        for ((name, change) in cases) {
            val json = JSONObject(text("ledger-host.json"))
            val expense = json.getJSONArray("expenses").getJSONObject(0)
            change(expense.getJSONObject("share_proposal"))
            assertNull(name, ledger(json.toString()))
        }
    }

    @Test
    fun requestBodyCarriesOnlyIdsVersionBasisTotalAndShares() {
        val request =
            ShareProposalRequest("e1", 3, KrwBasis.ReferenceEstimate, 12746, "q1", listOf(ShareLine(host, 6373), ShareLine(uploader, 6373)))
        val body = LocalSettlementGateway.body(request)
        assertEquals(
            setOf("p_expense", "p_expected_version", "p_request_id", "p_krw_basis", "p_krw_total", "p_fx_quote_id", "p_shares"),
            body.keys().asSequence().toSet(),
        )
        val shares = body.getJSONArray("p_shares")
        for (i in 0 until shares.length()) {
            assertEquals(
                setOf("user_id", "krw"),
                shares
                    .getJSONObject(i)
                    .keys()
                    .asSequence()
                    .toSet(),
            )
        }
        assertEquals(request.requestId.toString(), body.getString("p_request_id"))
        val text = body.toString()
        for (word in listOf("唐揚げ", "消費税", "name", "item", "1280", "ocr")) assertFalse(word, text.contains(word))
    }

    @Test
    fun requestKeyMatchesIosAndIsContentBound() {
        val a = ShareProposalRequest("e1", 1, KrwBasis.KrwOriginal, 10001, null, listOf(ShareLine(host, 6000), ShareLine(uploader, 4001)))
        // iOS ShareProposalRequest.requestID와 같은 값(같은 규칙).
        assertEquals("49a7be2e-a0fd-84ce-a01c-462089b4a18e", a.requestId.toString())
        assertEquals(a.requestId, a.copy(shares = a.shares.reversed()).requestId)
        assertNotEquals(a.requestId, a.copy(expectedVersion = 2).requestId)
        assertNotEquals(a.requestId, a.copy(shares = listOf(ShareLine(host, 6001), ShareLine(uploader, 4000))).requestId)
    }

    @Test
    fun basisBindsOnlyToValuesTheHostCanSee() {
        val by = byMerchant("ledger-uploader.json")
        val krw = by.getValue("가상 분식")
        assertEquals(ProposalBasis.Ready(KrwBasis.KrwOriginal, 10001, null), ProposalBasis.of(krw, false))
        assertEquals(ProposalBasis.Unavailable(ProposalBasis.Reason.Finalized), ProposalBasis.of(krw, true))
        val jpy = by.getValue("さくら食堂")
        val ready = ProposalBasis.of(jpy, false) as ProposalBasis.Ready
        assertEquals(KrwBasis.ReferenceEstimate, ready.basis)
        assertEquals(12746L, ready.krw)
        assertEquals(jpy.shareProposal!!.fxQuoteId, ready.quote!!.quoteId)
        assertEquals(
            ProposalBasis.Unavailable(ProposalBasis.Reason.NoKrwBasis),
            ProposalBasis.of(jpy.copy(fxProposal = FxProposal.Undetermined), false),
        )
        val verified =
            LedgerExpense(
                "v",
                2,
                false,
                uploader,
                "2026-11-03",
                3500,
                "JPY",
                null,
                ExpenseStatus.Included,
                host,
                31999,
                KrwBasis.VerifiedCharge,
                emptyList(),
                fxProposal = FxProposal.Undetermined,
            )
        assertEquals(ProposalBasis.Ready(KrwBasis.VerifiedCharge, 31999, null), ProposalBasis.of(verified, false))
        val usd = verified.copy(currency = "USD", status = ExpenseStatus.Pending, krwAmount = null, krwBasis = null)
        assertEquals(ProposalBasis.Unavailable(ProposalBasis.Reason.UnsupportedCurrency), ProposalBasis.of(usd, false))
    }

    @Test
    fun remainderIsNeverChosenSilently() {
        val remainder = ItemAllocation.Remainder(listOf(ItemMemberShare("a", 333), ItemMemberShare("b", 333)), 1)
        assertNull(ProposalShares.from(remainder, null))
        assertNull(ProposalShares.from(remainder, MemberId("z")))
        assertEquals(
            listOf(ShareLine(MemberId("a"), 333), ShareLine(MemberId("b"), 334)),
            ProposalShares.from(remainder, MemberId("b")),
        )
        assertNull(ProposalShares.from(ItemAllocation.Exact(listOf(ItemMemberShare("a", 0))), null))
    }

    @Test
    fun hostFillsOnlyACurrentMatchingProposalAndComparesIt() {
        val ledger = ledger(text("ledger-host.json"))!!
        val by = ledger.expenses.associateBy { it.merchant.orEmpty() }
        val krw = by.getValue("가상 분식")
        val filled = ShareForm.of(krw, ledger.members).filledFrom(krw.shareProposal!!, krw, ledger.members)!!
        assertEquals(ShareMode.Exact, filled.mode)
        assertNull(filled.payer)
        val lines = (filled.copy(payer = host).shares(krw, ledger.members) as ShareResult.Valid).shares
        assertEquals(10001L, lines.sumOf { it.krw })
        assertTrue(ProposalComparison.of(krw.shareProposal!!, lines, ledger.members).matches)

        val jpy = by.getValue("さくら食堂")
        val jpyForm = ShareForm.of(jpy, ledger.members).filledFrom(jpy.shareProposal!!, jpy, ledger.members)!!
        assertEquals(KrwSource.Estimate, jpyForm.krwSource)
        assertEquals(12746L, jpyForm.krw(jpy))

        val stale = by.getValue("가상 편의점")
        assertNull(ShareForm.of(stale, ledger.members).filledFrom(stale.shareProposal!!, stale, ledger.members))
        assertFalse(ProposalComparison.of(stale.shareProposal!!, stale.shares, ledger.members).matches)

        // 고시값이 바뀌어 지금 예상액이 제안 합계와 다르면 채우지 않는다.
        val q = (jpy.fxProposal as FxProposal.Proposed).quote
        val newer = ReferenceQuote("other", "906.75", 100, q.rateDate, q.itemName, true)
        val moved = jpy.copy(fxProposal = FxProposal.Proposed(newer, SharePlan.referenceKrw(1408, "906.75", 100)!!))
        assertNull(ShareForm.of(moved, ledger.members).filledFrom(jpy.shareProposal!!, moved, ledger.members))
    }

    @Test
    fun uploaderOnlyMapsToTypedFailure() {
        assertEquals(SettlementFailure.UploaderOnly, LocalSettlementGateway.failure(Outcome.Http(403, "uploader_only")))
        assertEquals(SettlementFailure.Stale, LocalSettlementGateway.failure(Outcome.Http(409, "stale_expense")))
        assertEquals(SettlementFailure.QuoteChanged, LocalSettlementGateway.failure(Outcome.Http(409, "stale_quote")))
        assertEquals(SettlementFailure.Rejected, LocalSettlementGateway.failure(Outcome.Http(400, "shares_mismatch")))
    }
}
