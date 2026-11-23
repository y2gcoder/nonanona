package app.nonanona

import app.nonanona.feature.account.SignInFailure
import app.nonanona.feature.settlement.SettlementFailure
import app.nonanona.feature.trip.InviteAcceptFailure
import app.nonanona.feature.trip.ManualExpenseUpload
import app.nonanona.feature.trip.ReceiptExpenseUpload
import app.nonanona.feature.trip.ReceiptUploadFailure
import app.nonanona.feature.trip.TripId
import app.nonanona.localbackend.LocalAuthGateway
import app.nonanona.localbackend.LocalBackendConfig
import app.nonanona.localbackend.LocalSettlementGateway
import app.nonanona.localbackend.LocalTripGateway
import app.nonanona.localbackend.Outcome
import app.nonanona.localbackend.isRejectedJwt
import app.nonanona.localbackend.serverCode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
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
    fun uploadMapping() {
        val cases =
            mapOf(
                Outcome.Transport to ReceiptUploadFailure.Network,
                Outcome.Http(404, "trip_not_found") to ReceiptUploadFailure.DestinationUnavailable,
                Outcome.Http(400, "refresh_token_not_found") to ReceiptUploadFailure.SessionExpired,
                Outcome.Http(401, "not_authenticated") to ReceiptUploadFailure.SessionExpired,
                Outcome.Http(503, null) to ReceiptUploadFailure.Unavailable,
                Outcome.Http(409, "artifact_missing") to ReceiptUploadFailure.Unknown,
                Outcome.Http(409, "idempotency_conflict") to ReceiptUploadFailure.Unknown,
            )
        cases.forEach { (outcome, expected) -> assertEquals("$outcome", expected, LocalTripGateway.uploadFailure(outcome)) }
    }

    @Test
    fun settlementMapping() {
        val cases =
            mapOf(
                Outcome.Http(404, "trip_not_found") to SettlementFailure.NotFound,
                Outcome.Http(403, "host_only") to SettlementFailure.HostOnly,
                Outcome.Http(409, "stale_expense") to SettlementFailure.Stale,
                Outcome.Http(409, "stale_revision") to SettlementFailure.Stale,
                Outcome.Http(409, "pending_review") to SettlementFailure.PendingReview,
                Outcome.Http(409, "trip_finalized") to SettlementFailure.Finalized,
                Outcome.Http(400, "shares_mismatch") to SettlementFailure.Rejected,
                Outcome.Http(400, "krw_unverified") to SettlementFailure.Rejected,
                Outcome.Http(409, "idempotency_conflict") to SettlementFailure.Unknown,
                Outcome.Http(401, "PGRST303") to SettlementFailure.SessionExpired,
                Outcome.Http(500, "unbalanced") to SettlementFailure.Unavailable,
                Outcome.Transport to SettlementFailure.Network,
                Outcome.Http(400, "shares_mismatch_v2") to SettlementFailure.Unknown,
            )
        cases.forEach { (outcome, expected) -> assertEquals("$outcome", expected, LocalSettlementGateway.failure(outcome)) }
        assertEquals(ReceiptUploadFailure.RoomFinalized, LocalTripGateway.uploadFailure(Outcome.Http(409, "trip_finalized")))
    }

    /** 직접 입력 요청 키는 (여행방, 초안, 사진)으로 정해지고 iOS와 같은 값이다. */
    @Test
    fun manualRequestKeyIsStableAndMatchesIos() {
        val trip = TripId("00000000-0000-4000-8000-000000000001")
        assertEquals("ad99df87-7dd2-54c7-aedd-106734663b6d", ManualExpenseUpload.requestId(trip, "d", "i").toString())
        assertNotEquals(ManualExpenseUpload.requestId(trip, "d", "i"), ManualExpenseUpload.requestId(trip, "d", "j"))
    }

    /** 같은 여행방·같은 사본이면 같은 요청 키(두 플랫폼이 같은 값을 만든다), 다른 여행방이면 다른 키. */
    @Test
    fun uploadRequestIdIsDeterministicAndSharedAcrossPlatforms() {
        val sha = "a".repeat(64)
        val key = ReceiptExpenseUpload.requestId(TripId("trip-1"), sha)
        assertEquals("a58ef2bd-d738-5416-93a2-4dd4a40cb4d1", key.toString())
        assertEquals(key, ReceiptExpenseUpload.requestId(TripId("trip-1"), sha))
        assertNotEquals(key, ReceiptExpenseUpload.requestId(TripId("trip-2"), sha))
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
