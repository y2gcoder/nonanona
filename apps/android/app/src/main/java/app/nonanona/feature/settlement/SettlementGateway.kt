package app.nonanona.feature.settlement

import app.nonanona.feature.trip.TripId
import app.nonanona.feature.trip.TripMember
import app.nonanona.feature.trip.TripRoom
import java.util.UUID

/** 여행방 구성원의 서버 ID. 결제자·부담자를 가리킬 때만 쓴다(화면에는 표시 이름을 보인다). */
@JvmInline
value class MemberId(
    val value: String,
)

data class LedgerMember(
    val id: MemberId,
    val displayName: String,
    val isHost: Boolean,
)

/** 한 사람의 부담 몫(원). */
data class ShareLine(
    val member: MemberId,
    val krw: Long,
)

/** 지출의 원화 기준. 기준환율 자동 환산은 없다(ADR-0001의 제공처·반올림이 정해지기 전까지). */
enum class KrwBasis(
    val wire: String,
) {
    /** 원화로 결제한 금액 그대로. */
    KrwOriginal("krw_original"),

    /** 방장이 확인한 실제 원화 청구액(외화 지출). */
    VerifiedCharge("verified_krw_charge"),
}

sealed interface ExpenseStatus {
    /** 방장 확인 전. 확정할 수 없다. */
    data object Pending : ExpenseStatus

    data object Included : ExpenseStatus

    data class Held(
        val reason: String,
    ) : ExpenseStatus
}

/** 여행방에 공유한 가림 사본 한 장의 위치와 해시(장부가 알려 준다). 원본 사진·OCR 글자는 가리키지 않는다. */
data class ReceiptArtifactRef(
    val path: String,
    val sha256: String,
)

/** 받은 가림 사본. 장부의 해시와 같은 바이트만 만든다(구현체가 검사한다). */
class MaskedReceiptImage(
    val png: ByteArray,
    val sha256: String,
) {
    override fun equals(other: Any?) = other is MaskedReceiptImage && other.sha256 == sha256 && other.png.contentEquals(png)

    override fun hashCode() = sha256.hashCode()
}

/** 가림 사본 받기 실패. 모두 다시 시도할 수 있고, 지출 검토는 막지 않는다. */
enum class ReceiptViewFailure {
    SessionExpired,

    /** 저장소가 읽기를 거절했다. */
    Denied,

    /** 사본이 없거나 이 계정으로 볼 수 없다. 저장소는 둘을 구분해 알리지 않는다. */
    Missing,

    /** 받은 바이트가 장부의 사본(해시·PNG·이 여행방 경로)과 다르다. 보여 주지 않는다. */
    Mismatch,

    /** 해시는 맞지만 그림으로 끝까지 풀리지 않는다(잘린·깨진 PNG). 보여 주지 않는다. */
    Undecodable,
    Network,
    Unavailable,
    Unknown,
}

class ReceiptViewException(
    val failure: ReceiptViewFailure,
) : Exception("receipt view failed: $failure")

/** 여행방에 올라간 지출 한 건. 올린 사람, 결제자, 부담 몫을 따로 둔다. */
data class LedgerExpense(
    val id: String,
    val version: Int,
    val isManual: Boolean,
    val uploadedBy: MemberId,
    val date: String,
    val amountMinor: Long,
    val currency: String,
    val merchant: String?,
    val status: ExpenseStatus,
    val payer: MemberId?,
    val krwAmount: Long?,
    val krwBasis: KrwBasis?,
    val shares: List<ShareLine>,
    /** 공유한 가림 사본(사본으로 올린 지출만). 직접 입력은 null. */
    val artifact: ReceiptArtifactRef? = null,
)

/** 여행방 장부. revision은 방의 입력이 바뀔 때마다 서버가 올리고, 확정은 방장이 본 revision으로만 한다. */
data class RoomLedger(
    val tripId: TripId,
    val name: String,
    val isFinalized: Boolean,
    val revision: Long,
    val isHost: Boolean,
    val me: MemberId,
    val members: List<LedgerMember>,
    val expenses: List<LedgerExpense>,
) {
    fun nameOf(id: MemberId?): String = id?.let { m -> members.firstOrNull { it.id == m }?.displayName ?: "알 수 없는 구성원" }.orEmpty()

    val room: TripRoom get() = TripRoom(tripId, name, members.map { TripMember(it.displayName, it.isHost, it.id == me) })
}

/** 방장 검토 한 건. requestId는 같은 검토를 다시 보낼 때 그대로 쓴다. */
data class ExpenseReview(
    val expenseId: String,
    val expectedVersion: Int,
    val requestId: UUID,
    val decision: Decision,
) {
    sealed interface Decision {
        /** 포함: 결제자, 확인한 원화(KRW 지출은 null), 원 단위 몫(합이 원화와 같아야 한다). */
        data class Include(
            val payer: MemberId,
            val verifiedKrw: Long?,
            val shares: List<ShareLine>,
        ) : Decision

        data class Hold(
            val reason: String,
        ) : Decision
    }
}

data class ReviewedExpense(
    val version: Int,
    val revision: Long,
    val replayed: Boolean,
)

data class Transfer(
    val from: MemberId,
    val to: MemberId,
    val krw: Long,
)

/** 송금에서 빠진 지출: 보류(사유) 또는 결제자 혼자 부담한 개인 지출. */
data class ExcludedExpense(
    val expenseId: String,
    val held: Boolean,
    val reason: String?,
)

/** 서버가 지금 입력으로 계산한 송금표. 기기는 다시 계산하지 않는다. */
data class SettlementPreview(
    val revision: Long,
    val isFinalized: Boolean,
    /** 확인 필요 지출이 없고 방이 열려 있다(확정할 수 있다). */
    val ready: Boolean,
    val pendingCount: Int,
    val includedTotalKrw: Long,
    val transfers: List<Transfer>,
    val excluded: List<ExcludedExpense>,
)

/** 확정한 정산. 서버가 확정 순간의 입력(구성원·지출·몫)과 결과(송금)를 고정한 스냅숏을 그대로 그린다. */
data class FinalSettlement(
    val id: String,
    val version: Int,
    val finalizedAt: String,
    val reviewedRevision: Long,
    val ruleVersion: String,
    val snapshotSha256: String,
    val members: List<LedgerMember>,
    val expenses: List<Expense>,
    val includedTotalKrw: Long,
    val transfers: List<Transfer>,
    val excluded: List<ExcludedExpense>,
) {
    data class Expense(
        val id: String,
        val merchant: String?,
        val isManual: Boolean,
        val date: String,
        val amountMinor: Long,
        val currency: String,
        val krwAmount: Long?,
        val kind: String,
    )

    fun nameOf(id: MemberId): String = members.firstOrNull { it.id == id }?.displayName ?: "알 수 없는 구성원"

    fun expense(id: String): Expense? = expenses.firstOrNull { it.id == id }
}

data class FinalizeResult(
    val finalizationId: String,
    val replayed: Boolean,
)

/** 정산 실패. 화면 문구와 다음 동작은 이 값으로만 정한다. 서버 원문·코드는 담지 않는다. */
enum class SettlementFailure {
    SessionExpired,

    /** 구성원이 아니거나 없는 방·지출. */
    NotFound,

    /** 방장만 할 수 있다. */
    HostOnly,

    /** 다른 변경이 먼저 들어왔다(지출 버전 또는 방 revision). 다시 불러와 확인한다. */
    Stale,

    /** 확인 필요 지출이 남아 확정할 수 없다. */
    PendingReview,

    /** 이미 확정된 방이다. 확정본을 본다. */
    Finalized,

    /** 서버가 값을 받지 않았다(결제자·원화·몫·사유). */
    Rejected,
    Network,
    Unavailable,
    Unknown,
}

class SettlementException(
    val failure: SettlementFailure,
) : Exception("settlement failed: $failure")

/**
 * 정산 데이터 경계: 분담 검토·보류, 송금표 미리보기, 검토한 revision으로 확정, 확정 결과 조회(ADR-0003).
 * 서버 SDK 호출은 구현체 안에 둔다. 실패는 [SettlementException]으로만 던지고 취소는 그대로 던진다.
 */
interface SettlementGateway {
    suspend fun review(
        review: ExpenseReview,
        trip: TripId,
    ): ReviewedExpense

    suspend fun preview(trip: TripId): SettlementPreview

    suspend fun finalize(
        trip: TripId,
        reviewedRevision: Long,
        requestId: UUID,
    ): FinalizeResult

    /** 확정본이 없으면 null. */
    suspend fun finalized(trip: TripId): FinalSettlement?
}

object UnavailableSettlementGateway : SettlementGateway {
    override suspend fun review(
        review: ExpenseReview,
        trip: TripId,
    ): ReviewedExpense = throw SettlementException(SettlementFailure.Unavailable)

    override suspend fun preview(trip: TripId): SettlementPreview = throw SettlementException(SettlementFailure.Unavailable)

    override suspend fun finalize(
        trip: TripId,
        reviewedRevision: Long,
        requestId: UUID,
    ): FinalizeResult = throw SettlementException(SettlementFailure.Unavailable)

    override suspend fun finalized(trip: TripId): FinalSettlement? = throw SettlementException(SettlementFailure.Unavailable)
}
