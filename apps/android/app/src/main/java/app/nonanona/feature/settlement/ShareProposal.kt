package app.nonanona.feature.settlement

import app.nonanona.feature.receiptimport.ItemAllocation
import java.util.UUID

/**
 * 올린 사람이 보낸 품목 나누기 제안 몫(ADR-0011). 사람마다 원 단위 몫만 있고 품목 정보는 없다.
 * 장부가 올린 사람과 방장에게만 지출마다 가장 최근 제안을 준다. 제안은 장부 몫을 바꾸지 않는다(방장이 검토로 포함해야 한다).
 */
data class ShareProposal(
    val id: String,
    val proposedBy: MemberId,
    val expenseVersion: Int,
    val basis: KrwBasis,
    val krwTotal: Long,
    /** 기준환율 예상액에 묶인 고시값(그 기준일 때만). */
    val fxQuoteId: String?,
    val shares: List<ShareLine>,
    val state: State,
) {
    enum class State(
        val wire: String,
    ) {
        /** 그 지출 버전·원화 기준 그대로다. 방장이 검토에 채울 수 있다. */
        Current("current"),

        /** 지출이 그 뒤 다시 검토됐다. 올린 사람이 새 값으로 다시 보내야 한다. */
        StaleExpense("stale_expense"),

        /** 원화 기준이 바뀌었다(기준환율 정정 등). 올린 사람이 새 값으로 다시 보내야 한다. */
        StaleBasis("stale_basis"),

        /** 포함한 원화와 몫이 제안과 같다. */
        Applied("applied"),

        /** 확정된 방에서 적용되지 않은 제안. */
        Closed("closed"),
        ;

        companion object {
            fun of(wire: String): State? = entries.firstOrNull { it.wire == wire }
        }
    }
}

/** 올린 사람이 보내는 제안. 이 값만 서버로 간다. 품목 이름·품목 금액·OCR 줄·조정 줄·사진은 이 타입에 없다. */
data class ShareProposalRequest(
    val expenseId: String,
    /** 올린 사람이 본 지출 버전. 그사이 방장이 검토했으면 서버가 거절한다(Stale). */
    val expectedVersion: Int,
    val basis: KrwBasis,
    val krwTotal: Long,
    val fxQuoteId: String?,
    val shares: List<ShareLine>,
)

/**
 * 동의한 보내기 하나(요청과 그 요청 키). 요청 키는 동의할 때마다 새로 만들고, 응답이 불확실해 같은 요청을 다시 보낼 때만
 * 같은 키를 쓴다. 그래서 A→B→A에서 마지막 A는 새 제안이 되어 가장 최근이 된다(내용으로 키를 정하면 옛 A의 재시도가 된다).
 */
data class ProposalOperation(
    val request: ShareProposalRequest,
    val requestId: UUID,
)

/** 동의 창을 열 때 고정한 보낼 값. 창은 이 값을 그리고, "보내기"를 누를 때 지금 값과 같아야 보낸다. */
data class ProposalConsent(
    val target: ExpenseTarget,
    val request: ShareProposalRequest,
)

data class SubmittedProposal(
    val proposalId: String,
    val replayed: Boolean,
    /** 그 제안이 지금도 그 지출의 가장 최근 제안인가(재시도한 옛 제안이면 false). 예전 서버는 보내지 않아 true로 본다. */
    val latest: Boolean = true,
)

/** 올린 사람이 제안을 묶을 원화 기준. 방장도 장부에서 같은 값을 볼 수 있는 기준만 고른다. */
sealed interface ProposalBasis {
    data class Ready(
        val basis: KrwBasis,
        val krw: Long,
        val quote: ReferenceQuote?,
    ) : ProposalBasis

    data class Unavailable(
        val reason: Reason,
    ) : ProposalBasis

    enum class Reason {
        Finalized,

        /** 엔화인데 방장이 아직 원화를 정하지 않았고 쓸 수 있는 기준환율 고시값도 없다(확인 못 함·고시 없음). */
        NoKrwBasis,

        /** 원화·엔화 밖의 통화는 품목 계획이 없다. */
        UnsupportedCurrency,
    }

    companion object {
        /**
         * KRW는 원래 금액. 엔화는 방장이 실제 청구액·환전 원가로 포함했으면 그 원화(올린 사람이 바꾸지 않는다), 아니면 지금의
         * 기준환율 예상액(앱이 고시값으로 다시 계산해 서버 값과 같을 때만). 둘 다 없으면 제안하지 않는다(기준을 새로 만들지 않는다).
         */
        fun of(
            expense: LedgerExpense,
            finalized: Boolean,
        ): ProposalBasis {
            if (finalized) return Unavailable(Reason.Finalized)
            return when (expense.currency) {
                "KRW" -> {
                    Ready(KrwBasis.KrwOriginal, expense.amountMinor, null)
                }

                "JPY" -> {
                    val krw = expense.krwAmount
                    val basis = expense.krwBasis
                    if (expense.status == ExpenseStatus.Included && krw != null &&
                        (basis == KrwBasis.VerifiedCharge || basis == KrwBasis.AcquisitionCost)
                    ) {
                        return Ready(basis, krw, null)
                    }
                    SharePlan.usableEstimate(expense.fxProposal, expense.amountMinor)?.let {
                        Ready(KrwBasis.ReferenceEstimate, it.krw, it.quote)
                    } ?: Unavailable(Reason.NoKrwBasis)
                }

                else -> {
                    Unavailable(Reason.UnsupportedCurrency)
                }
            }
        }
    }
}

/**
 * 방장이 "제안 몫 채우기"를 눌렀을 때: 직접 나누기에 제안 몫을 채우고, 엔화 예상액 제안이면 원화 기준을 기준환율 예상으로 둔다.
 * 서버에는 아무것도 보내지 않는다(방장이 결제자를 고르고 "포함하기"를 눌러야 간다). 지금 제안이 아니거나 방장이 볼 수 있는
 * 원화와 맞지 않으면 null(입력을 바꾸지 않는다).
 */
fun ShareForm.filledFrom(
    proposal: ShareProposal,
    expense: LedgerExpense,
    members: List<LedgerMember>,
): ShareForm? {
    if (proposal.state != ShareProposal.State.Current || proposal.expenseVersion != expense.version) return null
    if (!proposal.shares.all { line -> members.any { it.id == line.member } }) return null
    val source =
        when (proposal.basis) {
            KrwBasis.KrwOriginal -> {
                if (expense.currency != "KRW" || proposal.krwTotal != expense.amountMinor) return null
                krwSource
            }

            KrwBasis.ReferenceEstimate -> {
                val usable = SharePlan.usableEstimate(expense.fxProposal, expense.amountMinor) ?: return null
                if (usable.krw != proposal.krwTotal) return null
                KrwSource.Estimate
            }

            KrwBasis.VerifiedCharge, KrwBasis.AcquisitionCost -> {
                if (expense.status != ExpenseStatus.Included || expense.krwBasis != proposal.basis ||
                    expense.krwAmount != proposal.krwTotal
                ) {
                    return null
                }
                if (proposal.basis == KrwBasis.VerifiedCharge) KrwSource.Actual else KrwSource.Acquisition
            }
        }
    val next =
        copy(
            krwSource = source,
            mode = ShareMode.Exact,
            exact =
                members.associate { m ->
                    m.id to (
                        proposal.shares
                            .firstOrNull { it.member == m.id }
                            ?.krw
                            ?.toString() ?: ""
                    )
                },
        )
    return next.takeIf { it.krw(expense) == proposal.krwTotal }
}

/** 제안 몫과 방장 쪽 몫(지금 입력 또는 포함한 몫)을 사람마다 나란히 보인다. */
data class ProposalComparison(
    val rows: List<Row>,
) {
    data class Row(
        val member: MemberId,
        val proposed: Long?,
        val other: Long?,
    )

    val matches: Boolean get() = rows.all { it.proposed == it.other }

    companion object {
        fun of(
            proposal: ShareProposal,
            other: List<ShareLine>,
            members: List<LedgerMember>,
        ) = ProposalComparison(
            members.mapNotNull { m ->
                val p = proposal.shares.firstOrNull { it.member == m.id }?.krw
                val o = other.firstOrNull { it.member == m.id }?.krw
                if (p == null && o == null) null else Row(m.id, p, o)
            },
        )
    }
}

/**
 * 품목 계산 결과에서 보낼 몫을 만든다. 정확히 나눠떨어지면 그대로, 남은 원이 있으면 올린 사람이 고른 사람(그 영수증에
 * 몫이 있는 사람)에게만 더한다. 고르지 않았으면 null(저절로 정하지 않는다). 0원 이하 몫이 있으면 null(보내지 않는다).
 */
object ProposalShares {
    fun from(
        allocation: ItemAllocation,
        remainderTo: MemberId?,
    ): List<ShareLine>? {
        val shares =
            when (allocation) {
                is ItemAllocation.Exact -> {
                    allocation.shares.map { ShareLine(MemberId(it.member), it.krw) }
                }

                is ItemAllocation.PairRule -> {
                    allocation.shares.map { ShareLine(MemberId(it.member), it.krw) }
                }

                is ItemAllocation.Remainder -> {
                    val chosen = remainderTo ?: return null
                    if (allocation.floors.none { it.member == chosen.value }) return null
                    allocation.floors.map {
                        ShareLine(MemberId(it.member), it.krw + if (it.member == chosen.value) allocation.remaining else 0)
                    }
                }
            }
        return shares.takeIf { it.isNotEmpty() && it.all { s -> s.krw > 0 } }
    }
}
