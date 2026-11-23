package app.nonanona

import app.nonanona.feature.settlement.ExpenseStatus
import app.nonanona.feature.settlement.LedgerExpense
import app.nonanona.feature.settlement.LedgerMember
import app.nonanona.feature.settlement.MemberId
import app.nonanona.feature.settlement.ShareForm
import app.nonanona.feature.settlement.ShareLine
import app.nonanona.feature.settlement.ShareMode
import app.nonanona.feature.settlement.SharePlan
import app.nonanona.feature.settlement.ShareProblem
import app.nonanona.feature.settlement.ShareResult
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/** 몫 제안은 공통 예제(apps/fixtures/settlement/examples.json)를 iOS·서버 계약 시험과 같이 쓴다. */
class SharePlanTest {
    private val examples =
        JSONObject(
            generateSequence(File("").absoluteFile) { it.parentFile }
                .map { File(it, "apps/fixtures/settlement/examples.json") }
                .first { it.isFile }
                .readText(),
        )

    @Test
    fun evenSplitOnlyWhenItDividesExactly() {
        val proposals = examples.getJSONArray("share_proposals")
        assert(proposals.length() > 0)
        for (i in 0 until proposals.length()) {
            val p = proposals.getJSONObject(i)
            val even = if (p.isNull("even")) null else p.getJSONArray("even").let { a -> (0 until a.length()).map { a.getLong(it) } }
            assertEquals("${p.getLong("krw")}원 ${p.getInt("people")}명", even, SharePlan.evenSplit(p.getLong("krw"), p.getInt("people")))
        }
    }

    @Test
    fun parseWonAcceptsDigitsAndGroupingOnly() {
        assertEquals(13377L, SharePlan.parseWon("13,377"))
        assertEquals(13377L, SharePlan.parseWon("１３３７７"))
        assertNull(SharePlan.parseWon("13377.5"))
        assertNull(SharePlan.parseWon("-1"))
        assertNull(SharePlan.parseWon("0"))
        assertNull(SharePlan.parseWon(""))
    }

    private val host = LedgerMember(MemberId("h"), "다라", true)
    private val member = LedgerMember(MemberId("m"), "가나", false)
    private val members = listOf(host, member)

    private fun expense(
        amount: Long,
        currency: String,
    ) = LedgerExpense(
        "e",
        1,
        false,
        member.id,
        "2026-11-03",
        amount,
        currency,
        "さくら食堂",
        ExpenseStatus.Pending,
        null,
        null,
        null,
        emptyList(),
    )

    @Test
    fun foreignExpenseNeedsVerifiedKrwAndOddAmountNeedsExactShares() {
        val e = expense(1408, "JPY")
        var form = ShareForm.of(e, members)
        assertEquals(ShareResult.Invalid(ShareProblem.PayerMissing), form.shares(e, members))
        form = form.copy(payer = host.id)
        assertEquals("환율로 자동 계산하지 않는다", ShareResult.Invalid(ShareProblem.KrwMissing), form.shares(e, members))
        form = form.copy(verifiedKrwText = "13377")
        assertEquals("남는 1원을 고르지 않는다", ShareResult.Invalid(ShareProblem.NotDivisible), form.shares(e, members))
        form = form.copy(mode = ShareMode.Exact, exact = mapOf(host.id to "6688", member.id to "6688"))
        assertEquals(ShareResult.Invalid(ShareProblem.ExactMismatch(1)), form.shares(e, members))
        form = form.copy(exact = mapOf(host.id to "6688", member.id to "6689"))
        assertEquals(ShareResult.Valid(listOf(ShareLine(host.id, 6688), ShareLine(member.id, 6689))), form.shares(e, members))
    }

    @Test
    fun krwExpenseUsesItsOwnAmount() {
        val e = expense(38000, "KRW")
        var form = ShareForm.of(e, members).copy(payer = host.id)
        assertEquals(38000L, form.krw(e))
        assertEquals(ShareResult.Valid(listOf(ShareLine(host.id, 19000), ShareLine(member.id, 19000))), form.shares(e, members))
        form = form.copy(mode = ShareMode.One, one = member.id)
        assertEquals(ShareResult.Valid(listOf(ShareLine(member.id, 38000))), form.shares(e, members))
    }
}
