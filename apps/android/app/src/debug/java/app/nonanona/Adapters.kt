package app.nonanona

import android.content.Context
import app.nonanona.feature.receiptimport.ProcessingHooks
import app.nonanona.feature.receiptimport.ReceiptProcessor
import app.nonanona.localbackend.LocalAuthGateway
import app.nonanona.localbackend.LocalBackendConfig
import app.nonanona.localbackend.LocalSupabaseSession
import app.nonanona.localbackend.LocalTripGateway
import app.nonanona.testing.TestAuthGateway
import app.nonanona.testing.TestTripGateway
import java.io.File
import java.util.Properties

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
            trips = LocalTripGateway(session, failOnceAfterStorage = debugFlag(context, "uploadFailAfterStorageOnce")),
            processingHooks = processingHooks(context),
            debugUploadUi = DebugUploadSection,
            debugReceiptConfirm = confirmWithSuggestions(context),
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
    )
}

/** 검증용: files/debug-processing.properties의 참/거짓 설정을 읽는다. */
private fun debugFlag(
    context: Context,
    name: String,
): Boolean {
    val file = File(context.filesDir, "debug-processing.properties")
    if (!file.isFile) return false
    return Properties().apply { file.reader(Charsets.UTF_8).use { load(it) } }.getProperty(name) == "true"
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
