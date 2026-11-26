package app.nonanona

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import app.nonanona.design.NonanonaTheme
import app.nonanona.feature.receiptimport.ItemPlan
import app.nonanona.feature.receiptimport.ItemPlanLine
import app.nonanona.feature.receiptimport.ReceiptDraftStore
import app.nonanona.feature.receiptimport.StoredItemRetranslation
import kotlinx.coroutines.CompletableDeferred
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** 외부 테스트 런타임 없이 실제 Compose 대화상자 창과 Activity 생명주기를 검증한다. */
class ItemRetranslationInstrumentation : Instrumentation() {
    @Volatile private lateinit var activity: Activity

    @Volatile private var restoredActivity: Activity? = null
    private lateinit var receiptRoot: File
    private val receipt = Route.Receipt("test-draft", "photo-01")
    private lateinit var response: CompletableDeferred<List<String?>>
    private val calls = AtomicInteger()

    @Volatile private var readBlocked = false

    @Volatile private var writeBlocked = false
    private var showItemSplit = false

    @Volatile private var holdRead: CountDownLatch? = null
    private val line =
        ItemPlanLine(
            id = "ocr-1",
            kind = ItemPlanLine.Kind.Item,
            sourceLineIds = listOf(1),
            originalText = "焼き鳥 300",
            originalName = "焼き鳥",
            name = "",
            nameSource = ItemPlanLine.NameSource.None,
            amountText = "300",
            flags = emptyList(),
            checked = true,
            excluded = false,
            assignees = emptyList(),
        )

    private val secondLine = line.copy(id = "ocr-2", sourceLineIds = listOf(2), originalText = "枝豆 300", originalName = "枝豆")

    override fun onCreate(arguments: Bundle) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val tests =
            listOf(
                ::outsideAndBackKeepRequestAndResultsOpen,
                ::recreateKeepsRequestAndResultsWithoutResending,
                ::freshSessionRestoresCompletedResult,
                ::freshSessionReportsInterruptionWithoutResending,
                ::interruptedBatchRetryShowsAllEligibleRowsWithTheOriginalSelection,
                ::consentStillDismissesWithOutsideAndBack,
                ::failureDismissesWithOutsideBackAndSwipe,
                ::startButtonsStayDisabledDuringRestoreAndReadFailure,
                ::transientReadFailureOffersReloadAndKeepsTheFile,
                ::markerWriteFailureOffersOnlyTheConsentConfirmation,
            )
        var failures = 0
        for ((index, test) in tests.withIndex()) {
            val result =
                Bundle().apply {
                    putString("id", "ItemRetranslationInstrumentation")
                    putString("class", this@ItemRetranslationInstrumentation.javaClass.name)
                    putString("test", test.name)
                    putInt("current", index + 1)
                    putInt("numtests", tests.size)
                }
            sendStatus(1, Bundle(result))
            try {
                receiptRoot = File(targetContext.cacheDir, "retranslation-test-${UUID.randomUUID()}")
                response = CompletableDeferred()
                calls.set(0)
                readBlocked = false
                writeBlocked = false
                showItemSplit = false
                holdRead = null
                try {
                    launch()
                    test()
                } finally {
                    try {
                        if (::activity.isInitialized) finishActivity()
                    } finally {
                        receiptRoot.deleteRecursively()
                    }
                }
                result.putString("stream", "PASS ${test.name}\n")
                sendStatus(0, result)
            } catch (error: Exception) {
                failures++
                val stack = error.stackTraceToString()
                result.putString("stack", stack)
                result.putString("stream", "FAIL ${test.name}: $stack\n")
                sendStatus(-2, result)
            }
        }
        finish(
            if (failures == 0) Activity.RESULT_OK else Activity.RESULT_CANCELED,
            Bundle().apply { putString("stream", "${tests.size} tests, $failures failures\n") },
        )
    }

    @OptIn(ExperimentalComposeUiApi::class)
    override fun callActivityOnCreate(
        activity: Activity,
        bundle: Bundle?,
    ) {
        super.callActivityOnCreate(activity, bundle)
        this.activity = activity
        val owner =
            ViewModelProvider(
                activity as ComponentActivity,
                viewModelFactory { initializer { TestViewModel() } },
            )[TestViewModel::class.java]
        activity.setContent {
            NonanonaTheme {
                val sessions by owner.retranslation.sessions.collectAsStateWithLifecycle()
                LaunchedEffect(owner) {
                    owner.retranslation.restore(receipt)
                    restoredActivity = activity
                }
                if (showItemSplit) {
                    Box(Modifier.semantics { testTagsAsResourceId = true }) {
                        ItemSplitScreen(
                            plan = owner.plan,
                            people = emptyList(),
                            krw = null,
                            allocation = null,
                            translation = null,
                            translatorIsPreview = true,
                            hasTranslationSettings = false,
                            saveFailed = false,
                            loadFailure = null,
                            edit = {},
                            onRetrySave = {},
                            onRetryLoad = {},
                            onTranslate = {},
                            onOpenTranslationSettings = {},
                            onApply = {},
                            onBack = null,
                            retranslationReceipt = receipt,
                            retranslation = sessions[receipt],
                            retranslationState = owner.retranslation,
                        )
                    }
                } else {
                    TextButton(onClick = { owner.retranslation.open(receipt, listOf(line)) }) { Text("시험 열기") }
                    sessions[receipt]?.let { ItemRetranslationDialog(receipt, it, owner.retranslation) }
                }
            }
        }
    }

    private inner class TestViewModel : ViewModel() {
        var plan = ItemPlan("receipt-items-v1", "JPY", 600, null, emptyList(), listOf(line, secondLine), 1)
            private set
        val retranslation =
            ItemRetranslationState(
                scope = viewModelScope,
                store =
                    ReceiptDraftStore(
                        receiptRoot,
                        readFault = {
                            if ("/retranslations/" in it.path) {
                                holdRead?.let { gate -> check(gate.await(10, TimeUnit.SECONDS)) }
                                readBlocked
                            } else {
                                false
                            }
                        },
                        writeFault = { writeBlocked && "/retranslations/" in it.path },
                    ),
                translate = {
                    calls.incrementAndGet()
                    response.await()
                },
                plan = { plan },
                apply = { _, snapshot, name ->
                    plan = plan.acceptRetranslation(name, snapshot)
                    RetranslationApply.Applied
                },
            )
    }

    private fun outsideAndBackKeepRequestAndResultsOpen() {
        confirm()
        tapOutside()
        requireText(R.string.items_translation_running)
        sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        uiAutomation.waitForIdle(150, 2_000)
        requireText(R.string.items_translation_running)
        response.complete(listOf("닭꼬치"))
        requireText("닭꼬치")
        tapOutside()
        requireText("닭꼬치")
        sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        uiAutomation.waitForIdle(150, 2_000)
        requireText("닭꼬치")
        click(R.string.items_retranslation_close)
        requireAbsent("닭꼬치")
    }

    private fun recreateKeepsRequestAndResultsWithoutResending() {
        confirm()
        recreate()
        requireText(R.string.items_translation_running)
        response.complete(listOf("닭꼬치"))
        requireText("닭꼬치")
        recreate()
        requireText("닭꼬치")
        check(calls.get() == 1)
    }

    private fun freshSessionRestoresCompletedResult() {
        confirm()
        response.complete(listOf("닭꼬치"))
        requireText("닭꼬치")
        finishActivity()
        launch()
        requireText("닭꼬치")
        check(calls.get() == 1)
        click(R.string.items_retranslation_close)
        requireText("시험 열기")
        finishActivity()
        launch()
        requireAbsent("닭꼬치")
        check(ReceiptDraftStore(receiptRoot).loadRetranslation(receipt.draftId, receipt.itemId) == null)
    }

    private fun freshSessionReportsInterruptionWithoutResending() {
        confirm()
        finishActivity()
        launch()
        requireText(R.string.items_retranslation_failed)
        requireText(R.string.items_retranslation_retry)
        check(calls.get() == 1)
        click(R.string.items_retranslation_retry)
        check(calls.get() == 1)
        click(R.string.items_retranslation_confirm)
        requireText(R.string.items_translation_running)
        await("직접 다시 요청") { calls.get().takeIf { it == 2 } }
    }

    private fun interruptedBatchRetryShowsAllEligibleRowsWithTheOriginalSelection() {
        finishActivity()
        ReceiptDraftStore(receiptRoot).saveRetranslation(
            receipt.draftId,
            receipt.itemId,
            StoredItemRetranslation(true, listOf(line), suggestions = null),
        )
        launch()
        click(R.string.items_retranslation_retry)
        requireText(targetContext.getString(R.string.items_retranslation_selection_count, 1, MAXIMUM_RETRANSLATION_SELECTION))
        requireText(line.originalName)
        click(secondLine.originalName)
        requireText(targetContext.getString(R.string.items_retranslation_selection_count, 2, MAXIMUM_RETRANSLATION_SELECTION))
        check(calls.get() == 0)
    }

    private fun consentStillDismissesWithOutsideAndBack() {
        click("시험 열기")
        requireText(R.string.items_retranslation_confirm)
        tapOutside()
        requireText("시험 열기")
        click("시험 열기")
        requireText(R.string.items_retranslation_confirm)
        sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        requireText("시험 열기")
        check(calls.get() == 0)
    }

    private fun failureDismissesWithOutsideBackAndSwipe() {
        response.complete(listOf(null))
        repeat(3) { attempt ->
            click("시험 열기")
            click(R.string.items_retranslation_confirm)
            requireText(R.string.items_retranslation_failed)
            when (attempt) {
                0 -> tapOutside()
                1 -> sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
                else -> swipeTitleDown()
            }
            val gesture = listOf("바깥 터치", "뒤로 가기", "아래로 쓸기")[attempt]
            await("실패 안내 닫힘: $gesture") { node("시험 열기") }
            check(node(targetContext.getString(R.string.items_retranslation_failed)) == null)
        }
        check(calls.get() == 3)
    }

    private fun swipeTitleDown() {
        val titleBounds = Rect()
        requireText(R.string.items_retranslation_title).getBoundsInScreen(titleBounds)
        val x = titleBounds.exactCenterX()
        val y = titleBounds.exactCenterY()
        val downAt = SystemClock.uptimeMillis()
        val stepDistance = targetContext.resources.displayMetrics.density * 12f
        for (step in 0..10) {
            val action =
                when (step) {
                    0 -> MotionEvent.ACTION_DOWN
                    10 -> MotionEvent.ACTION_UP
                    else -> MotionEvent.ACTION_MOVE
                }
            val event = MotionEvent.obtain(downAt, SystemClock.uptimeMillis(), action, x, y + stepDistance * step, 0)
            try {
                event.source = InputDevice.SOURCE_TOUCHSCREEN
                check(uiAutomation.injectInputEvent(event, true))
            } finally {
                event.recycle()
            }
        }
        uiAutomation.waitForIdle(150, 2_000)
    }

    private fun startButtonsStayDisabledDuringRestoreAndReadFailure() {
        finishActivity()
        showItemSplit = true
        readBlocked = true
        val gate = CountDownLatch(1)
        holdRead = gate
        val store = ReceiptDraftStore(receiptRoot)
        val stale = StoredItemRetranslation(false, listOf(line.copy(originalText = "古い")), suggestions = null)
        store.saveRetranslation(receipt.draftId, receipt.itemId, stale)
        val buttons = listOf("items_retranslate_batch", "item_${line.id}_retranslate")
        try {
            launch(waitForRestore = false)
            buttons.forEach { tag ->
                check(!requireTagged(tag).isEnabled) { "복원 끝나기 전에 켜진 단추: $tag" }
            }
        } finally {
            gate.countDown()
        }

        requireText(R.string.items_retranslation_load_failed)
        buttons.forEach { check(!requireTagged(it).isEnabled) }
        check(store.loadRetranslation(receipt.draftId, receipt.itemId) == stale)
        readBlocked = false
        click(R.string.items_load_retry)
        buttons.forEach { tag ->
            await<AccessibilityNodeInfo>("복원 뒤 켜진 단추: $tag") { findNode { it.viewIdResourceName == tag && it.isEnabled } }
        }
        check(calls.get() == 0)
    }

    private fun transientReadFailureOffersReloadAndKeepsTheFile() {
        confirm()
        response.complete(listOf("닭꼬치"))
        requireText("닭꼬치")
        finishActivity()
        readBlocked = true
        showItemSplit = true
        launch()
        requireText(R.string.items_retranslation_load_failed)
        requireText(R.string.items_load_retry)
        check(node(targetContext.getString(R.string.items_retranslation_failed)) == null)
        check(node(targetContext.getString(R.string.items_retranslation_retry)) == null)
        readBlocked = false
        check(ReceiptDraftStore(receiptRoot).loadRetranslation(receipt.draftId, receipt.itemId)?.suggestions == mapOf(line.id to "닭꼬치"))
        click(R.string.items_load_retry)
        requireText("닭꼬치")
        check(calls.get() == 1)
    }

    private fun markerWriteFailureOffersOnlyTheConsentConfirmation() {
        writeBlocked = true
        click("시험 열기")
        click(R.string.items_retranslation_confirm)
        requireText(R.string.items_save_failed)
        requireText(R.string.items_retranslation_confirm)
        check(node(targetContext.getString(R.string.items_retry_save)) == null) { "요청 표시 쓰기 실패에 ‘다시 저장’이 보였어요" }
        check(calls.get() == 0)

        writeBlocked = false
        click(R.string.items_retranslation_confirm)
        requireText(R.string.items_translation_running)
        await("동의 확인 뒤 가짜 번역 요청") { calls.get().takeIf { it == 1 } }
        response.complete(listOf("닭꼬치"))
        requireText("닭꼬치")
    }

    private fun confirm() {
        click("시험 열기")
        click(R.string.items_retranslation_confirm)
        requireText(R.string.items_translation_running)
        await("가짜 번역 요청") { calls.get().takeIf { it == 1 } }
    }

    private fun launch(waitForRestore: Boolean = true) {
        val intent = Intent(targetContext, ItemRetranslationTestActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val started = startActivitySync(intent)
        if (waitForRestore) await("복원 완료") { true.takeIf { restoredActivity === started } }
        waitForIdleSync()
    }

    private fun finishActivity() {
        val previous = activity
        runOnMainSync { if (!previous.isFinishing) previous.finish() }
        await("Activity 종료", timeoutMillis = 15_000) { true.takeIf { isDestroyedOnMain(previous) } }
    }

    private fun recreate() {
        val previous = activity
        runOnMainSync { previous.recreate() }
        await("Activity 재생성", timeoutMillis = 15_000) {
            true.takeIf { activity !== previous && isDestroyedOnMain(previous) }
        }
        waitForIdleSync()
    }

    private fun isDestroyedOnMain(activity: Activity): Boolean {
        var destroyed = false
        runOnMainSync { destroyed = activity.isDestroyed }
        return destroyed
    }

    private fun tapOutside() {
        val titleBounds = Rect()
        requireText(R.string.items_retranslation_title).getBoundsInScreen(titleBounds)
        val downAt = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(downAt, SystemClock.uptimeMillis(), action, 12f, titleBounds.exactCenterY(), 0)
            try {
                event.source = InputDevice.SOURCE_TOUCHSCREEN
                check(uiAutomation.injectInputEvent(event, true))
            } finally {
                event.recycle()
            }
        }
        uiAutomation.waitForIdle(150, 2_000)
    }

    private fun click(id: Int) = click(targetContext.getString(id))

    private fun click(text: String) {
        val button = generateSequence(requireText(text)) { it.parent }.firstOrNull { it.isClickable }
        check(button?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) { "버튼을 누르지 못했어요: $text" }
        waitForIdleSync()
    }

    private fun requireTagged(tag: String) = await(tag) { findNode { it.viewIdResourceName == tag } }

    private fun requireText(id: Int) = requireText(targetContext.getString(id))

    private fun requireText(text: String) = await(text) { node(text) }

    private fun requireAbsent(text: String) = await("$text 사라짐") { true.takeIf { node(text) == null } }

    private fun node(text: String) = findNode { it.text?.toString() == text }

    private fun findNode(matches: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        fun find(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (matches(node)) return node
            return (0 until node.childCount).firstNotNullOfOrNull { node.getChild(it)?.let(::find) }
        }
        return uiAutomation.rootInActiveWindow?.let(::find)
    }

    private fun <T : Any> await(
        label: String,
        timeoutMillis: Long = 5_000,
        value: () -> T?,
    ): T {
        val deadline = SystemClock.uptimeMillis() + timeoutMillis
        do {
            value()?.let { return it }
            SystemClock.sleep(25)
        } while (SystemClock.uptimeMillis() < deadline)

        fun summary(
            node: AccessibilityNodeInfo?,
            depth: Int,
        ): String =
            if (node == null || depth == 0) {
                ""
            } else {
                "${node.className}(${node.text},${node.contentDescription}) " +
                    (0 until node.childCount).joinToString { summary(node.getChild(it), depth - 1) }
            }
        error("기다리던 상태가 없어요: $label, 화면: ${summary(uiAutomation.rootInActiveWindow, 10)}")
    }
}
