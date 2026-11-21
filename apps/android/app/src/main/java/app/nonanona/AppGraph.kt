package app.nonanona

import android.content.ContentResolver
import android.content.Context
import app.nonanona.feature.account.AuthGateway
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.trip.TripGateway
import java.io.File

/** 빌드 종류마다 다른 경계 구현체. debug는 src/debug, release는 src/release의 `createAdapters`가 만든다. */
class Adapters(
    val auth: AuthGateway,
    val trips: TripGateway,
)

/** 앱 시작 지점. 저장소와 경계 구현체를 한 번만 만들어 연결한다. */
class AppGraph(
    context: Context,
) {
    private val appContext = context.applicationContext
    val adapters: Adapters = createAdapters(appContext)
    val contentResolver: ContentResolver = appContext.contentResolver
    val drafts = ReceiptDraftStore(File(appContext.filesDir, "receipt-import"))
    val joinFlow =
        JoinFlow(
            auth = adapters.auth,
            trips = adapters.trips,
            pendingInvites = PendingInviteStore(File(appContext.filesDir, "account/pending-invite.properties")),
        )
}
