package app.nonanona

import android.content.Context
import app.nonanona.feature.receiptimport.ProcessingHooks
import app.nonanona.feature.receiptimport.ReceiptProcessor
import app.nonanona.localbackend.LocalAuthGateway
import app.nonanona.localbackend.LocalBackendConfig
import app.nonanona.localbackend.LocalSettlementGateway
import app.nonanona.localbackend.LocalSupabaseSession
import app.nonanona.localbackend.LocalTripGateway
import app.nonanona.testing.PreviewItemTranslator
import app.nonanona.testing.TestAuthGateway
import app.nonanona.testing.TestTripGateway
import java.io.File
import java.util.Properties

/**
 * debug 빌드 전용 연결. 기본은 가상 계정·가상 여행방을 돌려주는 테스트 구현체다.
 * scripts/local-backend.py가 만든 local-backend.properties로 빌드하면 로컬 Supabase에 붙는 로컬 모드가 된다.
 */
internal fun createAdapters(context: Context): Adapters {
    // 검증용: files/debug-processing.properties의 localAccount=host이면 가상 방장 계정으로 로그인한다.
    val host = debugValue(context, "localAccount") == "host"
    val local =
        LocalBackendConfig.of(
            baseUrl = BuildConfig.LOCAL_SUPABASE_URL,
            publishableKey = BuildConfig.LOCAL_PUBLISHABLE_KEY,
            testEmail = if (host) BuildConfig.LOCAL_HOST_EMAIL else BuildConfig.LOCAL_TEST_EMAIL,
            testPassword = if (host) BuildConfig.LOCAL_HOST_PASSWORD else BuildConfig.LOCAL_TEST_PASSWORD,
        )
    if (local != null) {
        val session = LocalSupabaseSession(local, File(context.noBackupFilesDir, "local-auth/session.properties"))
        return Adapters(
            auth = LocalAuthGateway(session, context.getString(R.string.local_login_notice)),
            trips = LocalTripGateway(session, failOnceAfterStorage = debugFlag(context, "uploadFailAfterStorageOnce")),
            settlement = LocalSettlementGateway(session),
            processingHooks = processingHooks(context),
            debugUploadUi = DebugUploadSection,
            debugReceiptConfirm = confirmWithSuggestions(context),
            writeFault = writeFault(context),
            itemTranslator = itemTranslator(context),
        )
    }
    val auth =
        TestAuthGateway(
            sessionFile = File(context.noBackupFilesDir, "test-auth/session.properties"),
            notice = context.getString(R.string.test_login_notice),
        )
    return Adapters(
        auth = auth,
        trips = TestTripGateway(auth),
        processingHooks = processingHooks(context),
        debugReceiptConfirm = confirmWithSuggestions(context),
        debugUploadUi = DebugUploadSection,
        writeFault = writeFault(context),
        itemTranslator = itemTranslator(context),
    )
}

/**
 * 검증용: files/debug-processing.properties의 itemTranslation=preview(또는 preview-fail-once)면 미리보기 대역(정해 둔 사전,
 * 실제 번역 아님)을 쓴다. 없으면 기기 번역 서비스(null).
 */
private fun itemTranslator(context: Context) =
    debugValue(context, "itemTranslation")?.takeIf { it.startsWith("preview") }?.let {
        PreviewItemTranslator(
            failOnce =
                it == "preview-fail-once",
        )
    }

/**
 * 검증용 저장 실패 주입: files/receipt-import/debug-fail-writes에 적힌 경로 조각(줄마다, 예: processing.json, reviews/)이
 * 들어간 파일 쓰기를 실패시킨다. 파일을 지우면 바로 돌아온다(iOS와 같은 규칙, E2E가 run-as로 만들고 지운다).
 */
private fun writeFault(context: Context): (File) -> Boolean {
    val flag = File(context.filesDir, "receipt-import/debug-fail-writes")
    return { file ->
        flag.isFile && flag.readLines().any { it.isNotBlank() && file.path.contains(it.trim()) }
    }
}

/** 검증용: files/debug-processing.properties의 참/거짓 설정을 읽는다. */
private fun debugFlag(
    context: Context,
    name: String,
): Boolean = debugValue(context, name) == "true"

private fun debugValue(
    context: Context,
    name: String,
): String? {
    val file = File(context.filesDir, "debug-processing.properties")
    if (!file.isFile) return null
    return Properties().apply { file.reader(Charsets.UTF_8).use { load(it) } }.getProperty(name)
}

/** 검증용: files/debug-processing.properties(delayMillisPerItem, failFirstAttemptAtPosition, dropSuggestionsAtPosition)가 있으면 읽는다. */
private fun processingHooks(context: Context): ProcessingHooks {
    val file = File(context.filesDir, "debug-processing.properties")
    if (!file.isFile) return ProcessingHooks()
    val p = Properties().apply { file.reader(Charsets.UTF_8).use { load(it) } }
    return ProcessingHooks(
        delayMillisPerItem = p.getProperty("delayMillisPerItem")?.toLongOrNull() ?: 0,
        failFirstAttemptAtPosition = p.getProperty("failFirstAttemptAtPosition")?.toIntOrNull(),
        dropSuggestionsAtPosition = p.getProperty("dropSuggestionsAtPosition")?.toIntOrNull(),
    )
}

/** 제안된 값과 가림을 그대로 확인한다. */
private fun confirmWithSuggestions(context: Context) =
    object : DebugReceiptConfirm {
        override val label: String = context.getString(R.string.debug_receipt_confirm)

        override suspend fun confirm(
            processor: ReceiptProcessor,
            itemId: String,
        ) {
            val proposal = processor.proposal(itemId)
            processor.confirm(itemId, proposal.fields, proposal.suggestedMaskLineIds.toSet())
        }
    }
