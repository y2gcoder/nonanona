package app.nonanona.testing

import app.nonanona.feature.account.AuthGateway
import app.nonanona.feature.trip.InviteAcceptException
import app.nonanona.feature.trip.InviteAcceptFailure
import app.nonanona.feature.trip.InviteCode
import app.nonanona.feature.trip.ReceiptExpenseUpload
import app.nonanona.feature.trip.ReceiptUploadException
import app.nonanona.feature.trip.ReceiptUploadFailure
import app.nonanona.feature.trip.SubmittedExpense
import app.nonanona.feature.trip.TripGateway
import app.nonanona.feature.trip.TripId
import app.nonanona.feature.trip.TripMember
import app.nonanona.feature.trip.TripRoom
import kotlinx.coroutines.delay
import java.util.UUID

/**
 * debug 빌드 전용 여행방 구현체. 가상 여행방 하나로 초대를 수락한다. 로그인 전에는 세션 만료로 거절한다.
 *
 * 실패와 복구를 기기에서 확인하기 위한 가상 초대 코드(iOS 테스트 구현체와 같다):
 * - `SYNTHEXPIRED01`: 항상 초대 만료
 * - `SYNTHOFFLINE01`: 앱 실행마다 첫 시도만 연결 실패, 다시 시도하면 수락
 * - `SYNTHSESSION01`: 앱 실행마다 첫 시도만 세션 만료, 다시 로그인하면 수락
 */
class TestTripGateway(
    private val auth: AuthGateway,
) : TripGateway {
    private val failedOnce = mutableSetOf<InviteCode>()

    override suspend fun acceptInvite(code: InviteCode): TripRoom {
        val session = auth.restoreSession() ?: throw InviteAcceptException(InviteAcceptFailure.SessionExpired)
        delay(SIMULATED_LATENCY_MILLIS)
        fixtureFailure(code)?.let { throw InviteAcceptException(it) }
        return TripRoom(
            id = TripId("test-trip-${code.value.lowercase()}"),
            name = "가상 도쿄 여행",
            members =
                listOf(
                    TripMember(displayName = "다라", isHost = true, isMe = false),
                    TripMember(displayName = session.displayName, isHost = false, isMe = true),
                ),
        )
    }

    private val uploads = mutableMapOf<UUID, String>()

    /** 가상 여행방에 기기 안에서만 기록한다. 같은 요청 키는 같은 결과를 돌려준다. */
    override suspend fun submitReceipt(
        upload: ReceiptExpenseUpload,
        trip: TripId,
    ): SubmittedExpense {
        auth.restoreSession() ?: throw ReceiptUploadException(ReceiptUploadFailure.SessionExpired)
        delay(200)
        return synchronized(uploads) {
            uploads[upload.requestId]?.let { SubmittedExpense(it, replayed = true) }
                ?: SubmittedExpense("test-expense-${uploads.size + 1}", replayed = false).also { uploads[upload.requestId] = it.expenseId }
        }
    }

    private fun fixtureFailure(code: InviteCode): InviteAcceptFailure? =
        when (code.value) {
            "SYNTHEXPIRED01" -> InviteAcceptFailure.InviteExpired
            "SYNTHOFFLINE01" -> InviteAcceptFailure.Network.takeIf { failedOnce.add(code) }
            "SYNTHSESSION01" -> InviteAcceptFailure.SessionExpired.takeIf { failedOnce.add(code) }
            else -> null
        }

    private companion object {
        const val SIMULATED_LATENCY_MILLIS = 400L
    }
}
