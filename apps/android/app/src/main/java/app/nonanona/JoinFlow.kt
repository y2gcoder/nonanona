package app.nonanona

import app.nonanona.feature.account.AccountSession
import app.nonanona.feature.account.AuthGateway
import app.nonanona.feature.account.SignInProvider
import app.nonanona.feature.trip.InviteCode
import app.nonanona.feature.trip.TripGateway
import app.nonanona.feature.trip.TripRoom

/**
 * 계정과 여행방 기능 사이의 순서를 맡는다. 초대는 받자마자 디스크에 쓰고,
 * 로그인이 끝나면 여행방 기능에 넘긴 뒤 수락이 성공했을 때만 지운다.
 */
class JoinFlow(
    private val auth: AuthGateway,
    private val trips: TripGateway,
    private val pendingInvites: PendingInviteStore,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    fun receiveInvite(code: InviteCode): PendingInvite = PendingInvite(code, clock()).also(pendingInvites::save)

    fun pendingInvite(): PendingInvite? = pendingInvites.load()

    suspend fun restoreSession(): AccountSession? = auth.restoreSession()

    suspend fun signIn(provider: SignInProvider): AccountSession = auth.signIn(provider)

    /** 보관한 초대가 없으면 null. 수락에 실패하면 초대를 그대로 두고 예외를 던진다. */
    suspend fun joinPendingInvite(): TripRoom? {
        val invite = pendingInvites.load() ?: return null
        val room = trips.acceptInvite(invite.code)
        pendingInvites.clear()
        return room
    }
}
