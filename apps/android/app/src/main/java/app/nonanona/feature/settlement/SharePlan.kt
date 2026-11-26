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

/** 외화(엔) 지출의 원화를 어디서 가져올지. 고르는 순서가 ADR-0001의 우선순위다. */
enum class KrwSource {
    /** 카드·계좌에 찍힌 실제 원화 청구액(우선순위 1). */
    Actual,

    /** 증빙으로 확인한 환전 원가(우선순위 2, 엔화만). */
    Acquisition,

    /** 한국은행 기준환율 예상액(우선순위 3, 엔화만, 서버 고시값). */
    Estimate,
}

/**
 * 몫 계산. 원 단위 정수만 쓰고 몫의 합은 언제나 원화와 같다. 엔화 환산은 정확한 정수 계산 뒤 원 단위로
 * 반올림한다(양수 .5는 올림, ADR-0008). 서버도 같은 계산으로 다시 확인한다.
 */
object SharePlan {
    /** 1,000억 원 미만만(서버의 원화 한도). */
    const val MAX_KRW = 100_000_000_000L

    private val rateFormat = Regex("^(0|[1-9][0-9]{0,5})(\\.[0-9]{1,4})?$")

    /** floor(n/d + 1/2) = (2n + d) / (2d), n ≥ 0, d > 0. 넘치면 null. */
    fun halfUpDivide(
        n: Long,
        d: Long,
    ): Long? {
        if (n < 0 || d <= 0) return null
        return try {
            Math.addExact(Math.multiplyExact(n, 2L), d) / Math.multiplyExact(d, 2L)
        } catch (_: ArithmeticException) {
            null
        }
    }

    /** 환전 원가로 본 원화: 엔 × 환전에 쓴 원화 ÷ 받은 엔. 0원이 되거나 한도를 넘으면 null(쓸 수 없다). */
    fun acquisitionKrw(
        amountMinor: Long,
        krwPaid: Long,
        foreignMinor: Long,
    ): Long? {
        if (amountMinor !in 1 until 100_000_000L || krwPaid !in 1 until 10_000_000_000L || foreignMinor !in 1 until 1_000_000_000L) {
            return null
        }
        val n =
            try {
                Math.multiplyExact(amountMinor, krwPaid)
            } catch (_: ArithmeticException) {
                return null
            }
        return halfUpDivide(n, foreignMinor)?.takeIf { it in 1 until MAX_KRW }
    }

    /** 고시 글자("905.25")를 소수 넷째 자리까지의 정수(9052500)로. 형식이 다르면 null. */
    fun scaledRate(text: String): Long? {
        if (!rateFormat.matches(text)) return null
        val parts = text.split(".")
        val whole = parts[0].toLongOrNull() ?: return null
        val fraction = (parts.getOrNull(1) ?: "").padEnd(4, '0').toLongOrNull() ?: return null
        return (whole * 10_000 + fraction).takeIf { it > 0 }
    }

    /** 기준환율 예상액: 엔 × 고시값 ÷ 단위. 0원이 되거나 한도를 넘으면 null. */
    fun referenceKrw(
        amountMinor: Long,
        rate: String,
        quoteUnit: Int,
    ): Long? {
        if (amountMinor !in 1 until 100_000_000L || quoteUnit <= 0) return null
        val scaled = scaledRate(rate) ?: return null
        val n =
            try {
                Math.multiplyExact(amountMinor, scaled)
            } catch (_: ArithmeticException) {
                return null
            }
        return halfUpDivide(n, quoteUnit * 10_000L)?.takeIf { it in 1 until MAX_KRW }
    }

    /** 서버 제안을 쓸 수 있는가: 고시값이 있고, 앱이 따로 계산한 원화가 서버 원화와 같을 때만(아니면 쓰지 않는다). */
    fun usableEstimate(
        proposal: FxProposal?,
        amountMinor: Long,
    ): FxProposal.Proposed? =
        (proposal as? FxProposal.Proposed)?.takeIf {
            referenceKrw(amountMinor, it.quote.rate, it.quote.quoteUnit) == it.krw
        }

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

    /** 환전 원가 입력이 없거나 숫자가 아니거나, 계산한 원화가 0원·한도 밖이다. */
    data object AcquisitionInvalid : ShareProblem

    /** 쓸 수 있는 기준환율 고시값이 없다(아직 확인 못 함·고시 없음). 보류하거나 다른 기준을 고른다. */
    data object EstimateUnavailable : ShareProblem

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
    /** 외화 지출의 원화를 어디서 가져올지(엔화만 셋 중에서 고른다. 다른 외화는 실제 청구액뿐). */
    val krwSource: KrwSource = KrwSource.Actual,
    /** 외화 지출의 실제 원화 청구액(글자 그대로). */
    val verifiedKrwText: String = "",
    /** 환전 원가: 환전에 쓴 원화와 받은 엔(글자 그대로). */
    val acquisitionKrwText: String = "",
    val acquisitionForeignText: String = "",
    val mode: ShareMode = ShareMode.Even,
    val one: MemberId? = null,
    val pair: Set<MemberId> = emptySet(),
    val exact: Map<MemberId, String> = emptyMap(),
) {
    /** 지금 고른 기준(이 지출에서 쓸 수 없는 기준이면 실제 청구액). */
    fun source(expense: LedgerExpense): KrwSource = if (krwSource in sources(expense)) krwSource else KrwSource.Actual

    /** 환전 원가 입력(둘 다 원 단위·엔 단위 정수일 때만). */
    val acquisitionInput: AcquisitionBasis?
        get() {
            val paid = SharePlan.parseWon(acquisitionKrwText) ?: return null
            val foreign = SharePlan.parseWon(acquisitionForeignText) ?: return null
            return AcquisitionBasis(paid, foreign)
        }

    /** 정산에 쓸 원화. KRW 지출은 원래 금액, 외화는 고른 기준의 원화(없으면 null — 보류하거나 확인 필요로 둔다). */
    fun krw(expense: LedgerExpense): Long? {
        if (expense.currency == "KRW") return expense.amountMinor
        return when (source(expense)) {
            KrwSource.Actual -> SharePlan.parseWon(verifiedKrwText)
            KrwSource.Acquisition -> acquisitionInput?.let { SharePlan.acquisitionKrw(expense.amountMinor, it.krwPaid, it.foreignMinor) }
            KrwSource.Estimate -> SharePlan.usableEstimate(expense.fxProposal, expense.amountMinor)?.krw
        }
    }

    /** 실제 청구액이 아닌 원화의 근거(서버에 함께 보낸다). KRW 지출과 실제 청구액은 null. */
    fun conversion(expense: LedgerExpense): KrwConversion? {
        if (expense.currency == "KRW") return null
        return when (source(expense)) {
            KrwSource.Actual -> {
                null
            }

            KrwSource.Acquisition -> {
                acquisitionInput?.let { KrwConversion.AcquisitionCost(it) }
            }

            KrwSource.Estimate -> {
                SharePlan.usableEstimate(expense.fxProposal, expense.amountMinor)?.let {
                    KrwConversion.ReferenceEstimate(it.quote.quoteId)
                }
            }
        }
    }

    fun shares(
        expense: LedgerExpense,
        members: List<LedgerMember>,
    ): ShareResult {
        if (payer == null) return ShareResult.Invalid(ShareProblem.PayerMissing)
        val krw =
            krw(expense) ?: return ShareResult.Invalid(
                when (if (expense.currency == "KRW") KrwSource.Actual else source(expense)) {
                    KrwSource.Actual -> ShareProblem.KrwMissing
                    KrwSource.Acquisition -> ShareProblem.AcquisitionInvalid
                    KrwSource.Estimate -> ShareProblem.EstimateUnavailable
                },
            )
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
        /** 이 지출에서 고를 수 있는 원화 기준. 엔화만 환전 원가·기준환율 예상을 쓸 수 있다. */
        fun sources(expense: LedgerExpense): List<KrwSource> =
            when (expense.currency) {
                "JPY" -> KrwSource.entries
                "KRW" -> emptyList()
                else -> listOf(KrwSource.Actual)
            }

        /**
         * 처음 열 때: 이미 포함한 지출이면 그 값, 아니면 결제자 미정·목록 앞 두 명 반씩.
         * 저장된 두 사람 몫이 반씩 규칙과 같을 때만 "둘이 반씩"으로 열고, 그 밖의 몫(예전에 직접 적은 홀수 몫 포함)은
         * "직접 나누기"로 그대로 연다.
         */
        fun of(
            expense: LedgerExpense,
            members: List<LedgerMember>,
        ): ShareForm {
            val base =
                ShareForm(
                    baseVersion = expense.version,
                    payer = expense.payer,
                    pair = members.take(2).map { it.id }.toSet(),
                    one = expense.payer,
                )
            var form =
                when (expense.krwBasis) {
                    KrwBasis.AcquisitionCost -> {
                        base.copy(
                            krwSource = KrwSource.Acquisition,
                            acquisitionKrwText =
                                expense.acquisition
                                    ?.krwPaid
                                    ?.toString()
                                    .orEmpty(),
                            acquisitionForeignText =
                                expense.acquisition
                                    ?.foreignMinor
                                    ?.toString()
                                    .orEmpty(),
                        )
                    }

                    // 예상액은 실제 청구액 칸에 옮기지 않는다(예상을 실제처럼 보이지 않게).
                    KrwBasis.ReferenceEstimate -> {
                        base.copy(krwSource = KrwSource.Estimate)
                    }

                    else -> {
                        base.copy(
                            verifiedKrwText = if (expense.currency != "KRW") expense.krwAmount?.toString().orEmpty() else "",
                        )
                    }
                }
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
