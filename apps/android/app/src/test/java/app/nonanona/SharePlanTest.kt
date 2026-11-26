package app.nonanona

import app.nonanona.feature.settlement.ExpenseStatus
import app.nonanona.feature.settlement.KrwBasis
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

    private data class PairCase(
        val krw: Long,
        val payer: Int?,
        val split: List<Long>?,
        val problem: String?,
    )

    private val pairCases =
        examples.getJSONObject("pair_splits").getJSONArray("cases").let { a ->
            (0 until a.length()).map { i ->
                val c = a.getJSONObject(i)
                PairCase(
                    c.getLong("krw"),
                    if (c.isNull("payer")) null else c.getInt("payer"),
                    if (c.isNull("split")) null else c.getJSONArray("split").let { s -> (0 until s.length()).map { s.getLong(it) } },
                    c.optString("problem").takeIf { it.isNotEmpty() },
                )
            }
        }

    @Test
    fun pairSplitMatchesSharedExamples() {
        assert(pairCases.isNotEmpty())
        for (c in pairCases) {
            assertEquals("${c.krw}원 결제자 ${c.payer}", c.split, SharePlan.pairSplit(c.krw, c.payer))
            c.split?.let { assert(it.sum() == c.krw && it.all { v -> v > 0 }) }
        }
    }

    /**
     * 같은 예제를 검토 입력으로: 방장이 결제자인 경우와 회원이 결제자인 경우, 구성원 목록 순서가 어느 쪽이든
     * 몫이 사람에게 맞게 붙고, 결제자가 두 사람 밖이면(셋째 구성원) 정해진 문제로 막힌다.
     */
    @Test
    fun evenModeFollowsSharedExamplesForBothRoleOrderings() {
        val third = LedgerMember(MemberId("x"), "라마", false)
        for (ordered in listOf(listOf(host, member, third), listOf(member, host, third))) {
            val pair = listOf(ordered[0].id, ordered[1].id)
            for (c in pairCases) {
                val e = expense(c.krw, "KRW")
                val form =
                    ShareForm.of(e, ordered).copy(
                        pair = pair.toSet(),
                        payer = c.payer?.let { pair[it] } ?: third.id,
                    )
                val expected =
                    c.split?.let { split -> ShareResult.Valid(pair.zip(split).map { (m, v) -> ShareLine(m, v) }) }
                        ?: ShareResult.Invalid(if (c.problem == "too_small") ShareProblem.TooSmallToSplit else ShareProblem.NotDivisible)
                assertEquals("${c.krw}원 ${ordered[0].displayName} 먼저", expected, form.shares(e, ordered))
            }
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
    fun foreignExpenseNeedsVerifiedKrwAndOddAmountGivesPayerTheExtraWon() {
        val e = expense(1408, "JPY")
        var form = ShareForm.of(e, members)
        assertEquals(ShareResult.Invalid(ShareProblem.PayerMissing), form.shares(e, members))
        form = form.copy(payer = host.id)
        assertEquals("환율로 자동 계산하지 않는다", ShareResult.Invalid(ShareProblem.KrwMissing), form.shares(e, members))
        form = form.copy(verifiedKrwText = "13377")
        assertEquals(
            "결제자가 1원을 더 부담한다",
            ShareResult.Valid(listOf(ShareLine(host.id, 6689), ShareLine(member.id, 6688))),
            form.shares(e, members),
        )
        form = form.copy(payer = member.id)
        assertEquals(ShareResult.Valid(listOf(ShareLine(host.id, 6688), ShareLine(member.id, 6689))), form.shares(e, members))
        form = form.copy(mode = ShareMode.Exact, exact = mapOf(host.id to "6688", member.id to "6688"))
        assertEquals(ShareResult.Invalid(ShareProblem.ExactMismatch(1)), form.shares(e, members))
        form = form.copy(exact = mapOf(host.id to "6688", member.id to "6689"))
        assertEquals(ShareResult.Valid(listOf(ShareLine(host.id, 6688), ShareLine(member.id, 6689))), form.shares(e, members))
    }

    /**
     * 이미 포함한 지출을 다시 열 때: 반씩 규칙과 같은 몫은 "둘이 반씩", 예전에 직접 적은 홀수 몫(결제자가 1원 덜 부담)은
     * "직접 나누기"로 값 그대로 열어, 다시 저장해도 몫이 바뀌지 않는다.
     */
    @Test
    fun reopeningKeepsStoredSharesWhetherPolicyOrLegacyManual() {
        fun included(
            hostKrw: Long,
            memberKrw: Long,
        ) = expense(1408, "JPY").copy(
            version = 3,
            status = ExpenseStatus.Included,
            payer = host.id,
            krwAmount = 13377,
            krwBasis = KrwBasis.VerifiedCharge,
            shares = listOf(ShareLine(host.id, hostKrw), ShareLine(member.id, memberKrw)),
        )
        val policy = included(6689, 6688)
        val reopened = ShareForm.of(policy, members)
        assertEquals(ShareMode.Even, reopened.mode)
        assertEquals(ShareResult.Valid(policy.shares), reopened.shares(policy, members))

        val legacy = included(6688, 6689)
        val legacyForm = ShareForm.of(legacy, members)
        assertEquals("예전 직접 나누기 몫을 반씩으로 바꾸지 않는다", ShareMode.Exact, legacyForm.mode)
        assertEquals(ShareResult.Valid(legacy.shares), legacyForm.shares(legacy, members))
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
