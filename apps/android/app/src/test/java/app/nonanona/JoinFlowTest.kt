package app.nonanona

import app.nonanona.feature.account.AccountId
import app.nonanona.feature.account.AccountSession
import app.nonanona.feature.account.AuthGateway
import app.nonanona.feature.account.SignInException
import app.nonanona.feature.account.SignInFailure
import app.nonanona.feature.account.SignInProvider
import app.nonanona.feature.receiptimport.DraftSource
import app.nonanona.feature.receiptimport.IncomingPhoto
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.trip.InviteAcceptException
import app.nonanona.feature.trip.InviteAcceptFailure
import app.nonanona.feature.trip.InviteCode
import app.nonanona.feature.trip.TripGateway
import app.nonanona.feature.trip.TripId
import app.nonanona.feature.trip.TripRoom
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import kotlin.coroutines.cancellation.CancellationException

class JoinFlowTest {
    @get:Rule val tmp = TemporaryFolder()

    private val code = InviteCode("SYNTHINVITE01")
    private val session = AccountSession(AccountId("account-1"), "가나")
    private val room = TripRoom(TripId("trip-1"), "가상 여행", emptyList())

    /** 다음 로그인 시도의 결과를 차례로 정하는 가짜 인증 경계. */
    private inner class FakeAuth(
        vararg outcomes: Any,
    ) : AuthGateway {
        private val queue = ArrayDeque(outcomes.toList())
        var endedSessions = 0
        override val providers = listOf(SignInProvider.Google)
        override val testOnlyNotice: String? = null

        override suspend fun restoreSession(): AccountSession? = null

        override suspend fun signIn(provider: SignInProvider): AccountSession =
            when (val next = queue.removeFirstOrNull() ?: session) {
                is SignInFailure -> throw SignInException(next)
                is Exception -> throw next
                else -> next as AccountSession
            }

        override suspend fun endSession() {
            endedSessions++
        }
    }

    /** 다음 수락 시도의 결과를 차례로 정하는 가짜 여행방 경계. 비면 수락한다. */
    private inner class FakeTrips(
        vararg outcomes: Any,
    ) : TripGateway {
        private val queue = ArrayDeque(outcomes.toList())
        val attempts = mutableListOf<InviteCode>()

        override suspend fun acceptInvite(code: InviteCode): TripRoom {
            attempts += code
            return when (val next = queue.removeFirstOrNull()) {
                null -> room
                is InviteAcceptFailure -> throw InviteAcceptException(next)
                else -> throw next as Exception
            }
        }
    }

    private val inviteFile get() = File(tmp.root, "account/pending-invite.properties")

    private fun flow(
        auth: AuthGateway = FakeAuth(),
        trips: TripGateway = FakeTrips(),
    ) = JoinFlow(auth, trips, PendingInviteStore(inviteFile)) { 42L }

    @Test
    fun pendingInviteSurvivesRestartBeforeSignIn() {
        flow().receiveInvite(code)

        assertEquals(PendingInvite(code, 42L), flow().pendingInvite())
    }

    @Test
    fun failedOrCancelledSignInKeepsPendingInviteAndRetrySignsIn() =
        runBlocking {
            val auth = FakeAuth(SignInFailure.Cancelled, SignInFailure.Network, IllegalStateException("provider detail"))
            val joinFlow = flow(auth = auth)
            joinFlow.receiveInvite(code)

            assertEquals(SignInResult.Failed(SignInFailure.Cancelled), joinFlow.signIn(SignInProvider.Google))
            assertEquals(SignInResult.Failed(SignInFailure.Network), joinFlow.signIn(SignInProvider.Google))
            // 예상하지 못한 예외는 원문 없이 Unknown이 된다.
            assertEquals(SignInResult.Failed(SignInFailure.Unknown), joinFlow.signIn(SignInProvider.Google))
            assertEquals(code, flow().pendingInvite()?.code)

            assertEquals(SignInResult.SignedIn(session), joinFlow.signIn(SignInProvider.Google))
        }

    @Test
    fun sessionExpiredEndsSessionKeepsInviteAndDraftThenJoinsAfterSignIn() =
        runBlocking {
            val drafts = ReceiptDraftStore(File(tmp.root, "receipt-import"))
            val draft = drafts.create(DraftSource.Share, listOf(IncomingPhoto("png") { ByteArrayInputStream(byteArrayOf(1)) }))
            val auth = FakeAuth()
            val trips = FakeTrips(InviteAcceptFailure.SessionExpired)
            val joinFlow = flow(auth, trips)
            joinFlow.receiveInvite(code)

            assertEquals(JoinResult.Failed(InviteAcceptFailure.SessionExpired), joinFlow.joinPendingInvite())
            assertEquals(1, auth.endedSessions)
            assertEquals(code, flow().pendingInvite()?.code)
            assertEquals(listOf(draft.id), drafts.list().map { it.id })

            joinFlow.signIn(SignInProvider.Google)
            assertEquals(JoinResult.Joined(room), joinFlow.joinPendingInvite())
            assertEquals(listOf(code, code), trips.attempts)
            assertNull(flow().pendingInvite())
            assertEquals(listOf(draft.id), drafts.list().map { it.id })
        }

    @Test
    fun deadInviteIsClearedAndNotRetried() =
        runBlocking {
            for (failure in listOf(InviteAcceptFailure.InviteExpired, InviteAcceptFailure.InviteInvalid)) {
                val auth = FakeAuth()
                val trips = FakeTrips(failure)
                val joinFlow = flow(auth, trips)
                joinFlow.receiveInvite(code)

                assertEquals(JoinResult.Failed(failure), joinFlow.joinPendingInvite())
                assertNull(flow().pendingInvite())
                assertEquals(0, auth.endedSessions)
                assertEquals(JoinResult.NoPendingInvite, joinFlow.joinPendingInvite())
                assertEquals(1, trips.attempts.size)
            }
        }

    @Test
    fun cancellationPropagatesAndKeepsInvite() =
        runBlocking {
            val joinFlow = flow(trips = FakeTrips(CancellationException("left the screen")))
            joinFlow.receiveInvite(code)

            assertThrows(CancellationException::class.java) { runBlocking { joinFlow.joinPendingInvite() } }
            assertEquals(code, flow().pendingInvite()?.code)
        }

    @Test
    fun retryableFailuresKeepInviteForRetry() =
        runBlocking {
            val trips =
                FakeTrips(InviteAcceptFailure.Network, InviteAcceptFailure.Unavailable, IllegalStateException("server detail"))
            val joinFlow = flow(trips = trips)
            joinFlow.receiveInvite(code)

            assertEquals(JoinResult.Failed(InviteAcceptFailure.Network), joinFlow.joinPendingInvite())
            assertEquals(JoinResult.Failed(InviteAcceptFailure.Unavailable), joinFlow.joinPendingInvite())
            assertEquals(JoinResult.Failed(InviteAcceptFailure.Unknown), joinFlow.joinPendingInvite())
            assertEquals(code, flow().pendingInvite()?.code)

            assertEquals(JoinResult.Joined(room), joinFlow.joinPendingInvite())
            assertNull(flow().pendingInvite())
        }

    @Test
    fun noPendingInviteMeansNothingToJoin() =
        runBlocking {
            assertEquals(JoinResult.NoPendingInvite, flow().joinPendingInvite())
        }
}
