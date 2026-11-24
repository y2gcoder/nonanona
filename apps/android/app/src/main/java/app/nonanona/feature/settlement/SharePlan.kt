package app.nonanona.feature.settlement

/** 방장이 고르는 부담 방식. 서버에는 어느 방식이든 원 단위 몫만 간다. */
enum class ShareMode {
    /** 한 사람이 전부 부담한다. */
    One,

    /** 두 사람이 똑같이 나눈다. 홀수 금액이면 결제자가 남는 1원을 더 부담한다(결제자가 두 사람 중 하나일 때만). */
    Even,

    /** 사람마다 원 단위 몫을 직접 적는다(남는 원이 생길 때). */
    Exact,
}

/** 몫 계산. 원 단위 정수만 쓰고 몫의 합은 언제나 원화와 같다. 환율 환산·반올림은 하지 않는다(ADR-0001). */
object SharePlan {
    /**
     * 두 사람 균등 몫(ADR-0007). [payerIndex]는 두 사람 중 결제자의 자리(0·1), 결제자가 두 사람 밖이면 null.
     * 짝수 금액은 똑같이 나눈다. 홀수 금액은 결제자가 floor(원화/2)+1, 다른 사람이 floor(원화/2)를 부담한다.
     * 결제자가 두 사람 밖인 홀수 금액은 남는 1원을 받을 사람이 없어 null(직접 나눈다). 한 사람 몫이 0원이 되는 1원도
     * null이다(서버는 0원 몫을 받지 않는다 — 한 사람 부담으로 정한다).
     */
    fun pairSplit(
        krw: Long,
        payerIndex: Int?,
    ): List<Long>? {
        if (krw < 2) return null
        val half = krw / 2
        if (krw % 2 == 0L) return listOf(half, half)
        return when (payerIndex) {
            0 -> listOf(half + 1, half)
            1 -> listOf(half, half + 1)
            else -> null
        }
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

    /** 홀수 금액인데 결제자가 두 사람 밖이라 남는 1원을 줄 사람이 없다. 직접 나눠야 한다. */
    data object NotDivisible : ShareProblem

    /** 1원은 두 사람이 나눌 수 없다(한 사람 몫이 0원). 한 사람 부담으로 정해야 한다. */
    data object TooSmallToSplit : ShareProblem

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
                if (krw < 2) return ShareResult.Invalid(ShareProblem.TooSmallToSplit)
                val payerIndex = people.indexOf(payer).takeIf { it >= 0 }
                val split = SharePlan.pairSplit(krw, payerIndex) ?: return ShareResult.Invalid(ShareProblem.NotDivisible)
                ShareResult.Valid(people.zip(split).map { (m, v) -> ShareLine(m, v) })
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
        /**
         * 처음 열 때: 이미 포함한 지출이면 그 값, 아니면 결제자 미정·목록 앞 두 명 반씩.
         * 저장된 두 사람 몫이 반씩 규칙과 같을 때만 "둘이 반씩"으로 열고, 그 밖의 몫(예전에 직접 적은 홀수 몫 포함)은
         * "직접 나누기"로 그대로 연다.
         */
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

                        shares.size == 2 && isPairSplit(shares, expense.payer, members) -> {
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

        private fun isPairSplit(
            shares: List<ShareLine>,
            payer: MemberId?,
            members: List<LedgerMember>,
        ): Boolean {
            val people = members.map { it.id }.filter { id -> shares.any { it.member == id } }
            if (people.size != 2) return false
            val stored = people.map { id -> shares.first { it.member == id }.krw }
            val payerIndex = people.indexOf(payer).takeIf { it >= 0 }
            return SharePlan.pairSplit(stored.sum(), payerIndex) == stored
        }
    }
}
