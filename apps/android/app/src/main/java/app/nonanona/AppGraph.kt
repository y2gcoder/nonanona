package app.nonanona

import android.content.ContentResolver
import android.content.Context
import androidx.compose.runtime.Composable
import app.nonanona.feature.account.AuthGateway
import app.nonanona.feature.receiptimport.CanvasReceiptFlattener
import app.nonanona.feature.receiptimport.ItemNameTranslator
import app.nonanona.feature.receiptimport.MlKitReceiptRecognizer
import app.nonanona.feature.receiptimport.ProcessingHooks
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.receiptimport.ReceiptFlattener
import app.nonanona.feature.receiptimport.ReceiptProcessor
import app.nonanona.feature.receiptimport.ReceiptRecognizer
import app.nonanona.feature.receiptimport.platformItemTranslator
import app.nonanona.feature.settlement.SettlementGateway
import app.nonanona.feature.settlement.UnavailableSettlementGateway
import app.nonanona.feature.trip.TripGateway
import app.nonanona.feature.trip.TripRoom
import java.io.File

/** 빌드 종류마다 다른 경계 구현체. debug는 src/debug, release는 src/release의 `createAdapters`가 만든다. */
class Adapters(
    val auth: AuthGateway,
    val trips: TripGateway,
    /** 정산 경계. 테스트 구현체와 release는 아직 연결하지 않는다. */
    val settlement: SettlementGateway = UnavailableSettlementGateway,
    /** 검증용 처리 속도·실패 주입. release는 항상 꺼짐. */
    val processingHooks: ProcessingHooks = ProcessingHooks(),
    /** 검토 화면이 정해지기 전의 개발용 확인. release는 null이라 화면에 버튼이 없다. */
    val debugReceiptConfirm: DebugReceiptConfirm? = null,
    /** 개발용 올리기 화면. release는 null이라 올리기 동작이 화면에 없다. */
    val debugUploadUi: DebugUploadUi? = null,
    /** 검증용 저장 실패 주입. release는 null. */
    val writeFault: ((File) -> Boolean)? = null,
    /** 검증용 읽기 실패 주입. release는 null. */
    val readFault: ((File) -> Boolean)? = null,
    /** 품목 이름 번역. null이면 기기 번역 서비스(release와 debug 기본값). debug는 미리보기 대역을 고를 수 있다. */
    val itemTranslator: ItemNameTranslator? = null,
)

/** 초안 화면이 개발용 올리기 화면에 넘기는 값. */
class DraftUploadContext(
    val destination: TripRoom?,
    val confirmedCount: Int,
    /** 직접 입력으로 확인한 건수(사본 없이 따로 묻고 따로 올린다). */
    val manualEntryCount: Int,
    val state: UploadState,
    val signedIn: Boolean,
    val onRequest: () -> Unit,
    val onLogin: () -> Unit,
    val manualState: UploadState = UploadState.Idle,
    val onRequestManual: () -> Unit = {},
)

/** debug 빌드만 제공하는 올리기 화면(문구도 debug 리소스). */
interface DebugUploadUi {
    @Composable
    fun Section(context: DraftUploadContext)

    /**
     * 올릴 곳·장수 최종 확인. 앱 맨 위(NonanonaApp)에서 한 번만 띄운다(iOS와 같은 구조). 창 크기·접기로 장면(한 칸↔두 칸)이
     * 바뀌어 초안 화면이 다시 그려져도 확인 창은 그대로 남는다.
     */
    @Composable
    fun Confirmation(
        confirmation: UploadConfirmation,
        onConfirm: (UploadConfirmation) -> Unit,
        onCancel: () -> Unit,
    )
}

/** debug 빌드만 제공하는 개발용 확인. 버튼 문구도 debug 리소스에서 온다. */
interface DebugReceiptConfirm {
    val label: String

    suspend fun confirm(
        processor: ReceiptProcessor,
        itemId: String,
    )
}

/** 앱 시작 지점. 저장소와 경계 구현체를 한 번만 만들어 연결한다. */
class AppGraph(
    context: Context,
) {
    private val appContext = context.applicationContext
    val adapters: Adapters = createAdapters(appContext)
    val contentResolver: ContentResolver = appContext.contentResolver
    val drafts =
        ReceiptDraftStore(
            File(appContext.filesDir, "receipt-import"),
            writeFault = adapters.writeFault,
            readFault = adapters.readFault,
        )

    /** ML Kit 번들 일본어 모델. 처음 쓸 때 만든다. */
    val recognizer: ReceiptRecognizer by lazy { MlKitReceiptRecognizer() }
    val flattener: ReceiptFlattener = CanvasReceiptFlattener

    /** 품목 이름 번역(기기 안). */
    val itemTranslator: ItemNameTranslator = adapters.itemTranslator ?: platformItemTranslator(appContext)
    val joinFlow =
        JoinFlow(
            auth = adapters.auth,
            trips = adapters.trips,
            pendingInvites = PendingInviteStore(File(appContext.filesDir, "account/pending-invite.properties")),
        )
}
