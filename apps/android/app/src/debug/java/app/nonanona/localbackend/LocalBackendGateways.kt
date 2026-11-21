package app.nonanona.localbackend

import app.nonanona.feature.account.AccountId
import app.nonanona.feature.account.AccountSession
import app.nonanona.feature.account.AuthGateway
import app.nonanona.feature.account.SignInException
import app.nonanona.feature.account.SignInFailure
import app.nonanona.feature.account.SignInProvider
import app.nonanona.feature.trip.InviteAcceptException
import app.nonanona.feature.trip.InviteAcceptFailure
import app.nonanona.feature.trip.InviteCode
import app.nonanona.feature.trip.TripGateway
import app.nonanona.feature.trip.TripId
import app.nonanona.feature.trip.TripMember
import app.nonanona.feature.trip.TripRoom
import org.json.JSONException
import org.json.JSONObject

/** 로컬 debug 모드의 인증 구현체. 실제 소셜 로그인이 아니라, 로컬 스택의 가상 계정으로 비밀번호 로그인한다. */
class LocalAuthGateway(
    private val session: LocalSupabaseSession,
    notice: String,
) : AuthGateway {
    override val providers = listOf(SignInProvider.Google)
    override val testOnlyNotice: String = notice

    override suspend fun restoreSession(): AccountSession? = session.stored()?.let { AccountSession(AccountId(it.userId), it.displayName) }

    override suspend fun signIn(provider: SignInProvider): AccountSession {
        val stored =
            try {
                session.signIn()
            } catch (e: LocalBackendException) {
                throw SignInException(signInFailure(e.outcome))
            } catch (e: JSONException) {
                throw SignInException(SignInFailure.Unknown)
            }
        return AccountSession(AccountId(stored.userId), stored.displayName)
    }

    override suspend fun endSession() = session.clear()

    companion object {
        /** Auth 응답을 로그인 실패로 옮긴다. 정해 둔 코드가 아니면 Unknown이다. */
        fun signInFailure(outcome: Outcome): SignInFailure =
            when {
                outcome is Outcome.Transport -> SignInFailure.Network
                outcome is Outcome.Http && (outcome.status == 429 || outcome.code == "over_request_rate_limit") -> SignInFailure.Unavailable
                outcome is Outcome.Http && outcome.status >= 500 -> SignInFailure.Unavailable
                else -> SignInFailure.Unknown
            }
    }
}

/** 로컬 debug 모드의 여행방 구현체. 실제 Auth 세션으로 accept_invite RPC를 부른다. */
class LocalTripGateway(
    private val session: LocalSupabaseSession,
) : TripGateway {
    override suspend fun acceptInvite(code: InviteCode): TripRoom {
        val displayName = session.stored()?.displayName.orEmpty()
        val json =
            try {
                session.rpc("accept_invite", JSONObject().put("p_token", code.value).put("p_display_name", displayName))
            } catch (e: LocalBackendException) {
                throw InviteAcceptException(acceptFailure(e.outcome))
            } catch (e: JSONException) {
                throw InviteAcceptException(InviteAcceptFailure.Unknown)
            }
        return try {
            val members = json.getJSONArray("members")
            TripRoom(
                id = TripId(json.getString("trip_id")),
                name = json.getString("trip_name"),
                members =
                    (0 until members.length()).map { i ->
                        members.getJSONObject(i).let {
                            TripMember(it.getString("display_name"), it.getBoolean("is_host"), it.getBoolean("is_me"))
                        }
                    },
            )
        } catch (e: JSONException) {
            throw InviteAcceptException(InviteAcceptFailure.Unknown)
        }
    }

    companion object {
        /**
         * 갱신 토큰으로 세션을 이어 갈 수 없다는 Auth 오류 코드.
         * https://supabase.com/docs/guides/auth/debugging/error-codes (확인일 2026-11-21)
         */
        private val sessionEndedCodes =
            setOf(
                "refresh_token_not_found",
                "refresh_token_already_used",
                "session_not_found",
                "session_expired",
                "user_not_found",
                "user_banned",
            )

        /** 서버 결과를 초대 수락 실패로 옮긴다. 서버가 정한 코드와 정확히 같을 때만 옮기고, 나머지는 Unknown이다. */
        fun acceptFailure(outcome: Outcome): InviteAcceptFailure {
            if (outcome is Outcome.Transport) return InviteAcceptFailure.Network
            val http = outcome as Outcome.Http
            return when {
                http.code == "invite_expired" -> {
                    InviteAcceptFailure.InviteExpired
                }

                http.code in setOf("invite_invalid", "invite_revoked", "invite_used") -> {
                    InviteAcceptFailure.InviteInvalid
                }

                http.code == "not_authenticated" || http.code in sessionEndedCodes || http.status == 401 -> {
                    InviteAcceptFailure.SessionExpired
                }

                http.status == 429 || http.status >= 500 -> {
                    InviteAcceptFailure.Unavailable
                }

                else -> {
                    InviteAcceptFailure.Unknown
                }
            }
        }
    }
}
