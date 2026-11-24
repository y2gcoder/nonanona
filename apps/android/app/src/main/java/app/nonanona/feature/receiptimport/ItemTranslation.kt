package app.nonanona.feature.receiptimport

import android.app.PendingIntent
import android.content.Context
import android.icu.util.ULocale
import android.os.Build
import android.os.CancellationSignal
import android.util.Log
import android.view.translation.TranslationCapability
import android.view.translation.TranslationContext
import android.view.translation.TranslationManager
import android.view.translation.TranslationRequest
import android.view.translation.TranslationRequestValue
import android.view.translation.TranslationResponse
import android.view.translation.TranslationSpec
import android.view.translation.Translator
import androidx.annotation.RequiresApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.util.concurrent.Executors
import kotlin.coroutines.resume

/** 일본어→한국어 기기 번역을 지금 쓸 수 있는가. 화면은 이 값으로 버튼과 안내를 정한다. */
enum class ItemTranslationAvailability {
    /** 언어가 기기에 있다. 번역할 수 있다. */
    Ready,

    /** 지원하지만 언어를 받아야 한다(기기 번역 설정에서 받는다). */
    NeedsDownload,

    /** 이 기기·OS에서는 쓸 수 없다(번역 서비스가 없거나 언어 쌍이 없음). 이름을 직접 적는다. */
    Unsupported,
}

class ItemTranslationException : Exception("item translation failed")

/**
 * 품목 이름 번역 제공자. 품목 글자는 기기 밖으로 보내지 않는다: 실제 구현은 기기 안 번역(Android 기기 번역 서비스)뿐이고,
 * debug 미리보기 대역은 정해 둔 사전이다. 결과는 사용자가 고칠 수 있는 제안일 뿐이다.
 */
interface ItemNameTranslator {
    /** 계획에 남길 이름 출처(OnDevice 또는 Preview). 화면이 "미리보기 대역"을 따로 표시한다. */
    val source: ItemPlanLine.NameSource

    suspend fun availability(): ItemTranslationAvailability

    /** 들어온 순서대로 번역을 돌려준다. 하나라도 실패하면 던진다(부분 결과를 쓰지 않는다). */
    suspend fun translate(texts: List<String>): List<String>

    /** 언어를 받거나 관리하는 시스템 화면(있으면). */
    fun settingsIntent(): PendingIntent? = null
}

/** API 31 미만 등 기기 번역을 쓸 수 없을 때. */
object UnavailableItemTranslator : ItemNameTranslator {
    override val source = ItemPlanLine.NameSource.OnDevice

    override suspend fun availability() = ItemTranslationAvailability.Unsupported

    override suspend fun translate(texts: List<String>): List<String> = throw ItemTranslationException()
}

fun platformItemTranslator(context: Context): ItemNameTranslator =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PlatformItemTranslator(context.applicationContext) else UnavailableItemTranslator

/**
 * Android 기기 번역(android.view.translation, API 31+). 기기 제조사가 넣은 기기 안 번역 서비스(TranslationService)를 쓰고,
 * 앱은 새 의존성·네트워크 권한을 더하지 않는다. 서비스가 없는 기기(예: 서비스 없는 에뮬레이터)는 Unsupported다.
 * 언어 받기는 앱이 하지 않는다: 지원하지만 받지 않은 언어는 NeedsDownload로 알리고 시스템 설정 화면을 연다.
 */
@RequiresApi(Build.VERSION_CODES.S)
class PlatformItemTranslator(
    private val context: Context,
) : ItemNameTranslator {
    override val source = ItemPlanLine.NameSource.OnDevice
    private val executor = Executors.newSingleThreadExecutor()
    private val manager: TranslationManager? get() = context.getSystemService(TranslationManager::class.java)
    private val ja = TranslationSpec(ULocale.JAPANESE, TranslationSpec.DATA_FORMAT_TEXT)
    private val ko = TranslationSpec(ULocale.KOREAN, TranslationSpec.DATA_FORMAT_TEXT)

    override suspend fun availability(): ItemTranslationAvailability =
        withContext(Dispatchers.IO) {
            // 몇 초 걸릴 수 있어 작업 스레드에서 부른다(문서).
            val capabilities =
                runCatching {
                    manager?.getOnDeviceTranslationCapabilities(TranslationSpec.DATA_FORMAT_TEXT, TranslationSpec.DATA_FORMAT_TEXT)
                }.onFailure { Log.i("ItemTranslation", "capabilities failed: ${it.javaClass.simpleName}") }
                    .getOrNull() ?: return@withContext ItemTranslationAvailability.Unsupported.also {
                    Log.i("ItemTranslation", "no TranslationManager or capabilities")
                }
            // 진단: 언어 쌍과 상태만 남긴다(영수증 글자는 남기지 않는다).
            Log.i(
                "ItemTranslation",
                "on-device capabilities=${capabilities.size} " +
                    capabilities.joinToString { "${it.sourceSpec.locale.language}>${it.targetSpec.locale.language}:${it.state}" },
            )
            val pair =
                capabilities.firstOrNull {
                    it.sourceSpec.locale.language == "ja" && it.targetSpec.locale.language == "ko"
                } ?: return@withContext ItemTranslationAvailability.Unsupported
            when (pair.state) {
                TranslationCapability.STATE_ON_DEVICE -> ItemTranslationAvailability.Ready

                TranslationCapability.STATE_AVAILABLE_TO_DOWNLOAD,
                TranslationCapability.STATE_DOWNLOADING,
                -> ItemTranslationAvailability.NeedsDownload

                else -> ItemTranslationAvailability.Unsupported
            }
        }

    override fun settingsIntent(): PendingIntent? = runCatching { manager?.onDeviceTranslationSettingsActivityIntent }.getOrNull()

    override suspend fun translate(texts: List<String>): List<String> {
        val manager = manager ?: throw ItemTranslationException()
        val translator =
            suspendCancellableCoroutine<Translator?> { cont ->
                manager.createOnDeviceTranslator(TranslationContext.Builder(ja, ko).build(), executor) { cont.resume(it) }
            } ?: throw ItemTranslationException()
        try {
            val request =
                TranslationRequest
                    .Builder()
                    .setTranslationRequestValues(texts.map { TranslationRequestValue.forText(it) })
                    .build()
            val response =
                suspendCancellableCoroutine<TranslationResponse> { cont ->
                    val signal = CancellationSignal()
                    cont.invokeOnCancellation { signal.cancel() }
                    translator.translate(request, signal, executor) { cont.resume(it) }
                }
            if (response.translationStatus != TranslationResponse.TRANSLATION_STATUS_SUCCESS) throw ItemTranslationException()
            val values = response.translationResponseValues
            return texts.indices.map { i -> values.get(i)?.text?.toString() ?: throw ItemTranslationException() }
        } finally {
            translator.destroy()
        }
    }
}
