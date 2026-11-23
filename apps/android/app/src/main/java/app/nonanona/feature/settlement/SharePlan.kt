package app.nonanona.feature.settlement

/** 방장이 고르는 부담 방식. 서버에는 어느 방식이든 원 단위 몫만 간다. */
enum class ShareMode {
    /** 한 사람이 전부 부담한다. */
    One,

    /** 두 사람이 똑같이 나눈다. 정확히 나누어떨어질 때만 쓸 수 있다. */
    Even,

    /** 사람마다 원 단위 몫을 직접 적는다(남는 원이 생길 때). */
    Exact,
}

/** 몫 계산. 반올림하거나 남는 원을 누구에게 줄지 고르지 않는다(규칙 미정, ADR-0001). 나누어떨어지지 않으면 null이다. */
object SharePlan {
    fun evenSplit(
        krw: Long,
        people: Int,
    ): List<Long>? {
        if (krw <= 0 || people <= 0 || krw % people != 0L) return null
        return List(people) { krw / people }
    }

    /** 원 단위 정수 입력. 전각 등 유니코드 숫자와 자릿수 쉼표·공백을 받고, 그 밖의 글자가 있으면 null. */
    fun parseWon(text: String): Long? {
        val digits = StringBuilder()
        for (ch in text) {
            if (ch == ',' || ch == ' ' || ch == '，') continue
            if (!Character.isDigit(ch)) return null
            digits.append(Character.digit(ch, 10))
        }
        if (digits.isEmpty() || digits.length > 11) return null
        return digits.toString().toLong().takeIf { it > 0 }
    }
}

sealed interface ShareProblem {
    data object PayerMissing : ShareProblem

    data object KrwMissing : ShareProblem

    data object PersonMissing : ShareProblem

    data object PairRequired : ShareProblem

    /** 반으로 나누면 원이 남는다. 직접 나눠야 한다. */
    data object NotDivisible : ShareProblem

    data object ExactInvalid : ShareProblem

    /** 직접 적은 몫의 합이 원화와 다르다(양수면 아직 남은 금액). */
    data class ExactMismatch(
        val remaining: Long,
    ) : ShareProblem
}

sealed interface ShareResult {
    data class Valid(
        val shares: List<ShareLine>,
    ) : ShareResult

    data class Invalid(
        val problem: ShareProblem,
    ) : ShareResult
}

/** 방장의 검토 입력. 화면 배치가 바뀌어도 남도록 상태에 둔다. */
data class ShareForm(
    /** 이 입력을 연 지출 버전. 보낼 때 이 버전을 기대 버전으로 쓴다(그사이 바뀌었으면 서버가 거절한다). */
    val baseVersion: Int,
    val payer: MemberId? = null,
    /** 외화 지출의 실제 원화 청구액(글자 그대로). */
    val verifiedKrwText: String = "",
    val mode: ShareMode = ShareMode.Even,
    val one: MemberId? = null,
    val pair: Set<MemberId> = emptySet(),
    val exact: Map<MemberId, String> = emptyMap(),
) {
    /** 정산에 쓸 원화. KRW 지출은 원래 금액, 외화는 확인한 청구액(없으면 null — 보류하거나 확인 필요로 둔다). */
    fun krw(expense: LedgerExpense): Long? = if (expense.currency == "KRW") expense.amountMinor else SharePlan.parseWon(verifiedKrwText)

    fun shares(
        expense: LedgerExpense,
        members: List<LedgerMember>,
    ): ShareResult {
        if (payer == null) return ShareResult.Invalid(ShareProblem.PayerMissing)
        val krw = krw(expense) ?: return ShareResult.Invalid(ShareProblem.KrwMissing)
        return when (mode) {
            ShareMode.One -> {
                val person = one ?: return ShareResult.Invalid(ShareProblem.PersonMissing)
                ShareResult.Valid(listOf(ShareLine(person, krw)))
            }

            ShareMode.Even -> {
                val people = members.map { it.id }.filter { it in pair }
                if (people.size != 2) return ShareResult.Invalid(ShareProblem.PairRequired)
                val each = SharePlan.evenSplit(krw, 2) ?: return ShareResult.Invalid(ShareProblem.NotDivisible)
                ShareResult.Valid(people.zip(each).map { (m, v) -> ShareLine(m, v) })
            }

            ShareMode.Exact -> {
                val lines = mutableListOf<ShareLine>()
                for (member in members) {
                    val text = exact[member.id].orEmpty().trim()
                    if (text.isEmpty() || text == "0") continue
                    val value = SharePlan.parseWon(text) ?: return ShareResult.Invalid(ShareProblem.ExactInvalid)
                    lines += ShareLine(member.id, value)
                }
                if (lines.isEmpty()) return ShareResult.Invalid(ShareProblem.ExactInvalid)
                val total = lines.sumOf { it.krw }
                if (total != krw) return ShareResult.Invalid(ShareProblem.ExactMismatch(krw - total))
                ShareResult.Valid(lines)
            }
        }
    }

    companion object {
        /** 처음 열 때: 이미 포함한 지출이면 그 값, 아니면 결제자 미정·목록 앞 두 명 반씩. */
        fun of(
            expense: LedgerExpense,
            members: List<LedgerMember>,
        ): ShareForm {
            var form =
                ShareForm(
                    baseVersion = expense.version,
                    payer = expense.payer,
                    verifiedKrwText = if (expense.currency != "KRW") expense.krwAmount?.toString().orEmpty() else "",
                    pair = members.take(2).map { it.id }.toSet(),
                    one = expense.payer,
                )
            val shares = expense.shares
            if (shares.isNotEmpty()) {
                form =
                    when {
                        shares.size == 1 -> {
                            form.copy(mode = ShareMode.One, one = shares[0].member)
                        }

                        shares.size == 2 && shares[0].krw == shares[1].krw -> {
                            form.copy(
                                mode = ShareMode.Even,
                                pair = shares.map { it.member }.toSet(),
                            )
                        }

                        else -> {
                            form.copy(mode = ShareMode.Exact)
                        }
                    }.copy(exact = shares.associate { it.member to it.krw.toString() })
            }
            return form
        }
    }
}
