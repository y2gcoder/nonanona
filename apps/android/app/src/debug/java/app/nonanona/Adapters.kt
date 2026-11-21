package app.nonanona

import android.content.Context
import app.nonanona.localbackend.LocalAuthGateway
import app.nonanona.localbackend.LocalBackendConfig
import app.nonanona.localbackend.LocalSupabaseSession
import app.nonanona.localbackend.LocalTripGateway
import app.nonanona.testing.TestAuthGateway
import app.nonanona.testing.TestTripGateway
import java.io.File

/**
 * debug 빌드 전용 연결. 기본은 가상 계정·가상 여행방을 돌려주는 테스트 구현체다.
 * scripts/local-backend.py가 만든 local-backend.properties로 빌드하면 로컬 Supabase에 붙는 로컬 모드가 된다.
 */
internal fun createAdapters(context: Context): Adapters {
    val local =
        LocalBackendConfig.of(
            baseUrl = BuildConfig.LOCAL_SUPABASE_URL,
            publishableKey = BuildConfig.LOCAL_PUBLISHABLE_KEY,
            testEmail = BuildConfig.LOCAL_TEST_EMAIL,
            testPassword = BuildConfig.LOCAL_TEST_PASSWORD,
        )
    if (local != null) {
        val session = LocalSupabaseSession(local, File(context.noBackupFilesDir, "local-auth/session.properties"))
        return Adapters(
            auth = LocalAuthGateway(session, context.getString(R.string.local_login_notice)),
            trips = LocalTripGateway(session),
        )
    }
    val auth =
        TestAuthGateway(
            sessionFile = File(context.noBackupFilesDir, "test-auth/session.properties"),
            notice = context.getString(R.string.test_login_notice),
        )
    return Adapters(auth = auth, trips = TestTripGateway(auth))
}
