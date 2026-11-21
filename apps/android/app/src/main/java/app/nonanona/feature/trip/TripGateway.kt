package app.nonanona.feature.trip

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

@JvmInline
value class InviteCode(
    val value: String,
) {
    companion object {
        private val pattern = Regex("[A-Za-z0-9_-]{8,64}")

        /** `nonanona://invite/<code>` 링크에서 초대 코드를 꺼낸다. 형식이 맞지 않으면 null. */
        fun fromLink(link: String): InviteCode? {
            val prefix = "nonanona://invite/"
            if (!link.startsWith(prefix)) return null
            val code =
                link
                    .removePrefix(prefix)
                    .substringBefore('?')
                    .substringBefore('#')
                    .trimEnd('/')
            return if (pattern.matches(code)) InviteCode(code) else null
        }
    }
}

@JvmInline
value class TripId(
    val value: String,
)

data class TripMember(
    val displayName: String,
    val isHost: Boolean,
    val isMe: Boolean,
)

data class TripRoom(
    val id: TripId,
    val name: String,
    val members: List<TripMember>,
)

/**
 * 초대 수락 실패. 화면 문구와 다음 동작(다시 로그인, 새 링크 요청, 다시 시도)은 이 값으로만 정한다.
 * 구현체가 서버 오류를 여기로 옮기며, 서버 원문·코드는 담지 않는다.
 */
enum class InviteAcceptFailure {
    /** 로그인 세션이 만료됐다. 다시 로그인하면 같은 초대로 이어서 참여한다. */
    SessionExpired,

    /** 초대가 만료됐다. 다시 시도하지 않고 새 링크를 요청한다. */
    InviteExpired,

    /** 초대를 쓸 수 없다(이미 다른 사람이 썼거나, 방장이 취소했거나, 없는 링크). 다시 시도하지 않고 새 링크를 요청한다. */
    InviteInvalid,

    /** 연결 문제. 보관한 초대로 다시 시도한다. */
    Network,

    /** 여행방 기능을 지금 쓸 수 없다(연결 전 빌드, 서버 점검). */
    Unavailable,

    /** 그 밖의 예상하지 못한 실패. */
    Unknown,
}

class InviteAcceptException(
    val failure: InviteAcceptFailure,
) : Exception("invite accept failed: $failure")

/** 여행방에 올릴 영수증 한 건. 가림을 구운 사본과 허용 필드만 담는다(원본·OCR 전문 없음). */
class ReceiptExpenseUpload(
    /** 같은 여행방에 같은 사본을 다시 올리면 같은 값이 된다. 서버는 이 값으로 중복을 막는다. */
    val requestId: UUID,
    val date: String,
    val amountMinor: Long,
    val currency: String,
    val merchant: String?,
    val artifactPng: ByteArray,
    val artifactSha256: String,
) {
    companion object {
        /** (여행방, 사본 해시)로 정하는 결정적 요청 키. 재시도·다시 열기에도 같다. */
        fun requestId(
            trip: TripId,
            artifactSha256: String,
        ): UUID {
            val b = MessageDigest.getInstance("SHA-256").digest("nonanona.receipt-upload.v1|${trip.value}|$artifactSha256".toByteArray())
            b[6] = ((b[6].toInt() and 0x0F) or 0x50).toByte() // 이름 기반(버전 5 형식)
            b[8] = ((b[8].toInt() and 0x3F) or 0x80).toByte()
            val buffer = ByteBuffer.wrap(b, 0, 16)
            return UUID(buffer.long, buffer.long)
        }
    }
}

data class SubmittedExpense(
    val expenseId: String,
    /** 이미 올라간 요청을 다시 보냈다(새 지출을 만들지 않았다). */
    val replayed: Boolean,
)

/** 영수증 올리기 실패. 화면 문구와 다음 동작은 이 값으로만 정한다. */
enum class ReceiptUploadFailure {
    /** 다시 로그인한 뒤 같은 요청으로 다시 올린다. */
    SessionExpired,

    /** 이 여행방에 올릴 수 없다(구성원이 아니거나 없는 방). 아무것도 만들지 않는다. */
    DestinationUnavailable,

    /** 연결 문제. 같은 요청으로 다시 시도한다. */
    Network,
    Unavailable,
    Unknown,
}

class ReceiptUploadException(
    val failure: ReceiptUploadFailure,
) : Exception("receipt upload failed: $failure")

/**
 * 여행방 데이터 경계. 첫 슬라이스는 초대 수락만 정의한다. 서버 SDK 호출은 구현체 안에 둔다(ADR-0003).
 * 호출자는 로그인한 뒤에 부른다. 구현체는 인증 경계가 가진 세션으로 요청한다.
 */
interface TripGateway {
    /** 실패하면 [InviteAcceptException]을 던진다. 취소되면 CancellationException을 그대로 던진다. */
    suspend fun acceptInvite(code: InviteCode): TripRoom

    /** 확인한 영수증 한 건을 올린다. 실패하면 [ReceiptUploadException]. 취소되면 CancellationException을 그대로 던진다. */
    suspend fun submitReceipt(
        upload: ReceiptExpenseUpload,
        trip: TripId,
    ): SubmittedExpense
}

/** release 빌드의 기본 구현체. 서버를 연결하기 전까지 어떤 초대도 수락하지 않는다. */
object UnavailableTripGateway : TripGateway {
    override suspend fun acceptInvite(code: InviteCode): TripRoom = throw InviteAcceptException(InviteAcceptFailure.Unavailable)

    override suspend fun submitReceipt(
        upload: ReceiptExpenseUpload,
        trip: TripId,
    ): SubmittedExpense = throw ReceiptUploadException(ReceiptUploadFailure.Unavailable)
}
