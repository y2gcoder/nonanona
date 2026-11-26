package app.nonanona

import app.nonanona.feature.receiptimport.OcrLanguageChoice
import app.nonanona.feature.receiptimport.OcrLine
import app.nonanona.feature.receiptimport.OcrResult
import app.nonanona.feature.receiptimport.OcrTiles
import app.nonanona.feature.receiptimport.ProcessingException
import app.nonanona.feature.receiptimport.ProcessingFailure
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test
import kotlin.coroutines.cancellation.CancellationException

/** 두 모델의 실패를 따로 처리하는지(ADR-0013). iOS `RecognitionChoiceTests`와 같은 사례다. */
class RecognitionChoiceTest {
    private fun result(vararg texts: String) =
        OcrResult(800, 1200, texts.mapIndexed { i, t -> OcrLine(i, t, 0.1, i * 0.05, 0.5, 0.03, confidence = 1.0) })

    private val japanese = result("合計 1,408円", "カード番号")
    private val korean = result("합계 6,900원", "카드번호 4521", "승인번호 52906634")

    @After
    fun clearInterrupt() {
        Thread.interrupted()
    }

    @Test
    fun japaneseFailureFallsBackToKorean() {
        assertSame(korean, OcrLanguageChoice.choose({ throw ProcessingException(ProcessingFailure.RecognitionError) }, { korean }))
        // 모델 준비(클라이언트 생성)가 동기 예외로 실패해도 같다.
        assertSame(korean, OcrLanguageChoice.choose({ throw IllegalStateException("model") }, { korean }))
    }

    @Test
    fun koreanFailureFallsBackToJapanese() {
        assertSame(japanese, OcrLanguageChoice.choose({ japanese }, { throw IllegalStateException("model") }))
    }

    @Test
    fun tileFailureFailsOnlyThatModel() {
        // 긴 사진(세로 > 가로 2배)의 두 번째 타일에서 실패한 모델은 전체가 실패하고 다른 모델의 결과를 쓴다.
        val tiles = mutableListOf<Int>()
        val chosen =
            OcrLanguageChoice.choose(
                { japanese },
                {
                    OcrTiles.read(720, 1560) { tile ->
                        tiles += tile.top
                        if (tiles.size == 2) throw ProcessingException(ProcessingFailure.RecognitionError)
                        OcrResult(720, tile.height, emptyList())
                    }
                },
            )
        assertSame(japanese, chosen)
        assertEquals(2, tiles.size)
    }

    @Test
    fun bothSucceedUsesScore() {
        assertSame(korean, OcrLanguageChoice.choose({ japanese }, { korean }))
    }

    @Test
    fun bothFailThrowsJapaneseFailure() {
        val e =
            assertThrows(ProcessingException::class.java) {
                OcrLanguageChoice.choose(
                    { throw ProcessingException(ProcessingFailure.InvalidImage) },
                    { throw ProcessingException(ProcessingFailure.RecognitionError) },
                )
            }
        assertEquals(ProcessingFailure.InvalidImage, e.failure)
        val other =
            assertThrows(ProcessingException::class.java) {
                OcrLanguageChoice.choose({ throw IllegalStateException("a") }, { throw IllegalStateException("b") })
            }
        assertEquals(ProcessingFailure.RecognitionError, other.failure)
    }

    @Test
    fun cancellationIsNotAFallback() {
        var koreanCalls = 0
        assertThrows(CancellationException::class.java) {
            OcrLanguageChoice.choose({ throw CancellationException("cancelled") }, {
                koreanCalls++
                korean
            })
        }
        assertThrows(InterruptedException::class.java) {
            OcrLanguageChoice.choose({ throw InterruptedException() }, {
                koreanCalls++
                korean
            })
        }
        // 일본어 읽기가 끝난 뒤 인터럽트가 걸리면 한국어 모델로 넘어가지 않는다.
        assertThrows(InterruptedException::class.java) {
            OcrLanguageChoice.choose({
                Thread.currentThread().interrupt()
                japanese
            }, {
                koreanCalls++
                korean
            })
        }
        assertEquals(0, koreanCalls)
    }

    @Test
    fun interruptStopsBeforeNextTile() {
        val tiles = mutableListOf<Int>()
        assertThrows(InterruptedException::class.java) {
            OcrTiles.read(720, 1560) { tile ->
                tiles += tile.top
                Thread.currentThread().interrupt()
                OcrResult(720, tile.height, emptyList())
            }
        }
        assertEquals(1, tiles.size)
    }
}
