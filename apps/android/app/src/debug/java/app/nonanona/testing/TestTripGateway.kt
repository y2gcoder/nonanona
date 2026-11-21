package app.nonanona.testing

import app.nonanona.feature.account.AuthGateway
import app.nonanona.feature.trip.InviteCode
import app.nonanona.feature.trip.TripException
import app.nonanona.feature.trip.TripGateway
import app.nonanona.feature.trip.TripId
import app.nonanona.feature.trip.TripMember
import app.nonanona.feature.trip.TripRoom
import kotlinx.coroutines.delay

/** debug 빌드 전용 여행방 구현체. 어떤 초대든 가상 여행방 하나로 수락한다. 로그인 전에는 거절한다. */
class TestTripGateway(
    private val auth: AuthGateway,
) : TripGateway {
    override suspend fun acceptInvite(code: InviteCode): TripRoom {
        val session = auth.restoreSession() ?: throw TripException("sign in first")
        delay(SIMULATED_LATENCY_MILLIS)
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

    private companion object {
        const val SIMULATED_LATENCY_MILLIS = 400L
    }
}
