package app.nonanona

import android.content.Context
import app.nonanona.testing.TestAuthGateway
import app.nonanona.testing.TestTripGateway
import java.io.File

/** debug 빌드 전용 연결. 가상 계정과 가상 여행방만 쓰고 네트워크를 부르지 않는다. */
internal fun createAdapters(context: Context): Adapters {
    val auth =
        TestAuthGateway(
            sessionFile = File(context.noBackupFilesDir, "test-auth/session.properties"),
            notice = context.getString(R.string.test_login_notice),
        )
    return Adapters(auth = auth, trips = TestTripGateway(auth))
}
