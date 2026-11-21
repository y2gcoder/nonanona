package app.nonanona

import app.nonanona.feature.account.AccountId
import app.nonanona.feature.account.AccountSession
import app.nonanona.feature.account.AuthGateway
import app.nonanona.feature.account.SignInException
import app.nonanona.feature.account.SignInProvider
import app.nonanona.feature.trip.InviteCode
import app.nonanona.feature.trip.TripException
import app.nonanona.feature.trip.TripGateway
import app.nonanona.feature.trip.TripId
import app.nonanona.feature.trip.TripRoom
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class JoinFlowTest {
    @get:Rule val tmp = TemporaryFolder()

    private val code = InviteCode("SYNTHINVITE01")
    private val session = AccountSession(AccountId("account-1"), "가나")

    private class FakeAuth(
        var fail: Boolean = false,
    ) : AuthGateway {
        override val providers = listOf(SignInProvider.Google)
        override val testOnlyNotice: String? = null

        override suspend fun restoreSession(): AccountSession? = null

        override suspend fun signIn(provider: SignInProvider): AccountSession =
            if (fail) throw SignInException("cancelled") else AccountSession(AccountId("account-1"), "가나")
    }

    private class FakeTrips(
        var fail: Boolean = false,
    ) : TripGateway {
        val accepted = mutableListOf<InviteCode>()

        override suspend fun acceptInvite(code: InviteCode): TripRoom {
            if (fail) throw TripException("offline")
            accepted += code
            return TripRoom(TripId("trip-1"), "가상 여행", emptyList())
        }
    }

    private fun flow(
        file: File,
        auth: AuthGateway = FakeAuth(),
        trips: TripGateway = FakeTrips(),
    ) = JoinFlow(auth, trips, PendingInviteStore(file)) { 42L }

    @Test
    fun pendingInviteSurvivesRestartBeforeSignIn() {
        val file = File(tmp.root, "account/pending-invite.properties")
        flow(file).receiveInvite(code)

        val afterRestart = flow(file).pendingInvite()

        assertEquals(PendingInvite(code, 42L), afterRestart)
    }

    @Test
    fun failedSignInKeepsPendingInvite() =
        runBlocking {
            val file = File(tmp.root, "pending.properties")
            val joinFlow = flow(file, auth = FakeAuth(fail = true))
            joinFlow.receiveInvite(code)

            assertTrue(runCatching { joinFlow.signIn(SignInProvider.Google) }.isFailure)
            assertEquals(code, flow(file).pendingInvite()?.code)
        }

    @Test
    fun failedAcceptKeepsPendingInvite() =
        runBlocking {
            val file = File(tmp.root, "pending.properties")
            val joinFlow = flow(file, trips = FakeTrips(fail = true))
            joinFlow.receiveInvite(code)
            joinFlow.signIn(SignInProvider.Google)

            assertTrue(runCatching { joinFlow.joinPendingInvite() }.isFailure)
            assertEquals(code, flow(file).pendingInvite()?.code)
        }

    @Test
    fun acceptedInviteIsClearedAndReturnsRoom() =
        runBlocking {
            val file = File(tmp.root, "pending.properties")
            val trips = FakeTrips()
            val joinFlow = flow(file, trips = trips)
            joinFlow.receiveInvite(code)
            assertEquals(session, joinFlow.signIn(SignInProvider.Google))

            val room = joinFlow.joinPendingInvite()

            assertEquals(TripId("trip-1"), room?.id)
            assertEquals(listOf(code), trips.accepted)
            assertNull(flow(file).pendingInvite())
        }

    @Test
    fun noPendingInviteMeansNothingToJoin() =
        runBlocking {
            assertNull(flow(File(tmp.root, "none.properties")).joinPendingInvite())
        }
}
