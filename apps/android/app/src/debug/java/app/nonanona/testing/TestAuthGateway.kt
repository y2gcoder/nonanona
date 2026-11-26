package app.nonanona.testing

import app.nonanona.feature.account.AccountId
import app.nonanona.feature.account.AccountSession
import app.nonanona.feature.account.AuthGateway
import app.nonanona.feature.account.SignInException
import app.nonanona.feature.account.SignInFailure
import app.nonanona.feature.account.SignInProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Properties

/**
 * debug 빌드 전용 인증 구현체. 실제 소셜 로그인을 부르지 않고 가상 계정 하나로 로그인한다.
 * 세션은 앱 전용 폴더에 남겨 다시 열어도 로그인 상태가 이어진다.
 */
class TestAuthGateway(
    private val sessionFile: File,
    notice: String,
) : AuthGateway {
    override val providers = listOf(SignInProvider.Google)
    override val testOnlyNotice: String = notice

    override suspend fun restoreSession(): AccountSession? =
        withContext(Dispatchers.IO) {
            if (!sessionFile.isFile) return@withContext null
            val props = Properties().apply { sessionFile.reader(Charsets.UTF_8).use { load(it) } }
            val id = props.getProperty("accountId") ?: return@withContext null
            AccountSession(AccountId(id), props.getProperty("displayName").orEmpty())
        }

    override suspend fun signIn(provider: SignInProvider): AccountSession {
        if (provider !in providers) throw SignInException(SignInFailure.Unavailable)
        delay(SIMULATED_LATENCY_MILLIS)
        val session = AccountSession(AccountId("test-account-0001"), "가나")
        withContext(Dispatchers.IO) {
            sessionFile.parentFile?.mkdirs()
            val props =
                Properties().apply {
                    setProperty("accountId", session.accountId.value)
                    setProperty("displayName", session.displayName)
                }
            sessionFile.writer(Charsets.UTF_8).use { props.store(it, null) }
        }
        return session
    }

    override suspend fun endSession() {
        withContext(Dispatchers.IO) { sessionFile.delete() }
    }

    private companion object {
        const val SIMULATED_LATENCY_MILLIS = 600L
    }
}
