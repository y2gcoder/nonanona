package app.nonanona

import app.nonanona.feature.account.SignInFailure
import app.nonanona.feature.trip.InviteAcceptFailure
import app.nonanona.localbackend.LocalAuthGateway
import app.nonanona.localbackend.LocalBackendConfig
import app.nonanona.localbackend.LocalTripGateway
import app.nonanona.localbackend.Outcome
import app.nonanona.localbackend.isRejectedJwt
import app.nonanona.localbackend.serverCode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 로컬 Supabase 응답 → 기능 실패 매핑. 코드 값은 로컬 스택에서 실제로 받은 응답에서 가져왔다. */
class LocalBackendMappingTest {
    @Test
    fun inviteAcceptMapping() {
        val cases =
            mapOf(
                Outcome.Http(410, "invite_expired") to InviteAcceptFailure.InviteExpired,
                Outcome.Http(410, "invite_revoked") to InviteAcceptFailure.InviteInvalid,
                Outcome.Http(410, "invite_used") to InviteAcceptFailure.InviteInvalid,
                Outcome.Http(404, "invite_invalid") to InviteAcceptFailure.InviteInvalid,
                Outcome.Http(400, "refresh_token_not_found") to InviteAcceptFailure.SessionExpired,
                Outcome.Http(401, "PGRST301") to InviteAcceptFailure.SessionExpired,
                Outcome.Http(503, null) to InviteAcceptFailure.Unavailable,
                Outcome.Http(429, null) to InviteAcceptFailure.Unavailable,
                Outcome.Transport to InviteAcceptFailure.Network,
                Outcome.Http(409, "trip_finalized") to InviteAcceptFailure.Unknown,
                Outcome.Http(400, "invite_expired_soon") to InviteAcceptFailure.Unknown,
                Outcome.Http(410, null) to InviteAcceptFailure.Unknown,
            )
        cases.forEach { (outcome, expected) -> assertEquals("$outcome", expected, LocalTripGateway.acceptFailure(outcome)) }
    }

    @Test
    fun signInMapping() {
        assertEquals(SignInFailure.Network, LocalAuthGateway.signInFailure(Outcome.Transport))
        assertEquals(SignInFailure.Unavailable, LocalAuthGateway.signInFailure(Outcome.Http(429, "over_request_rate_limit")))
        assertEquals(SignInFailure.Unavailable, LocalAuthGateway.signInFailure(Outcome.Http(500, null)))
        assertEquals(SignInFailure.Unknown, LocalAuthGateway.signInFailure(Outcome.Http(400, "invalid_credentials")))
    }

    @Test
    fun serverCodeReadsOnlyMachineFields() {
        assertEquals("refresh_token_not_found", serverCode("refresh_token_not_found", null, null))
        assertEquals("invite_expired", serverCode(null, "PT410", "invite_expired"))
        // PTxxx가 아닌 Data API 오류는 사람이 읽는 message 대신 code를 쓴다.
        assertEquals("PGRST301", serverCode(null, "PGRST301", "Expected 3 parts in JWT; got 1"))
        assertNull(serverCode(null, null, "anything"))
    }

    @Test
    fun onlyRejectedJwtTriggersRefresh() {
        assertTrue(isRejectedJwt(Outcome.Http(401, "PGRST303")))
        assertFalse(isRejectedJwt(Outcome.Http(401, "42501")))
        assertFalse(isRejectedJwt(Outcome.Http(410, "invite_expired")))
    }

    @Test
    fun configAcceptsOnlyLocalStack() {
        fun config(url: String) = LocalBackendConfig.of(url, "k", "e", "p")
        assertNotNull(config("http://10.0.2.2:54321"))
        assertNull(config("https://example.supabase.co"))
        assertNull(config("http://192.168.0.10:54321"))
        assertNull(config("http://10.0.2.2:54321/rest/v1"))
        assertNull(LocalBackendConfig.of("http://10.0.2.2:54321", "", "e", "p"))
    }
}
