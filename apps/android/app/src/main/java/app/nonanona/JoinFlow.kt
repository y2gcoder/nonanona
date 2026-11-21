package app.nonanona

import app.nonanona.feature.account.AccountSession
import app.nonanona.feature.account.AuthGateway
import app.nonanona.feature.account.SignInException
import app.nonanona.feature.account.SignInFailure
import app.nonanona.feature.account.SignInProvider
import app.nonanona.feature.trip.InviteAcceptException
import app.nonanona.feature.trip.InviteAcceptFailure
import app.nonanona.feature.trip.InviteCode
import app.nonanona.feature.trip.TripGateway
import app.nonanona.feature.trip.TripRoom
import kotlin.coroutines.cancellation.CancellationException

sealed interface SignInResult {
    data class SignedIn(
        val session: AccountSession,
    ) : SignInResult

    data class Failed(
        val failure: SignInFailure,
    ) : SignInResult
}

sealed interface JoinResult {
    data class Joined(
        val room: TripRoom,
    ) : JoinResult

    data object NoPendingInvite : JoinResult

    data class Failed(
        val failure: InviteAcceptFailure,
    ) : JoinResult
}

/**
 * 계정과 여행방 기능 사이의 순서를 맡는다. 초대는 받자마자 디스크에 쓰고,
 * 로그인이 끝나면 여행방 기능에 넘긴 뒤 수락이 성공했을 때만 지운다.
 * 실패해도 기기에 저장한 초안은 건드리지 않는다.
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

    /** 실패해도 보관한 초대는 그대로 둔다. 예상하지 못한 예외는 [SignInFailure.Unknown]이 된다. */
    suspend fun signIn(provider: SignInProvider): SignInResult =
        try {
            SignInResult.SignedIn(auth.signIn(provider))
        } catch (e: CancellationException) {
            throw e
        } catch (e: SignInException) {
            SignInResult.Failed(e.failure)
        } catch (e: Exception) {
            SignInResult.Failed(SignInFailure.Unknown)
        }

    /**
     * 보관한 초대를 수락한다. 세션 만료면 세션만 지우고 초대는 남겨 다시 로그인한 뒤 이어 가게 한다.
     * 초대 만료·사용 불가면 다시 시도해도 소용없으므로 초대를 지운다. 그 밖의 실패는 초대를 남겨 다시 시도하게 한다.
     */
    suspend fun joinPendingInvite(): JoinResult {
        val invite = pendingInvites.load() ?: return JoinResult.NoPendingInvite
        val failure =
            try {
                val room = trips.acceptInvite(invite.code)
                pendingInvites.clear()
                return JoinResult.Joined(room)
            } catch (e: CancellationException) {
                throw e
            } catch (e: InviteAcceptException) {
                e.failure
            } catch (e: Exception) {
                InviteAcceptFailure.Unknown
            }
        when (failure) {
            InviteAcceptFailure.SessionExpired -> auth.endSession()
            InviteAcceptFailure.InviteExpired, InviteAcceptFailure.InviteInvalid -> pendingInvites.clear()
            InviteAcceptFailure.Network, InviteAcceptFailure.Unavailable, InviteAcceptFailure.Unknown -> Unit
        }
        return JoinResult.Failed(failure)
    }
}
