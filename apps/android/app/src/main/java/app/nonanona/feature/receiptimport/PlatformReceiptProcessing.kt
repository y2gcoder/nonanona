package app.nonanona.feature.receiptimport

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.media.ExifInterface
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ExecutionException

/**
 * 영수증 사진 디코딩은 이것 하나다: OCR, 가림 굽기, 검토 화면의 원본·가림 표시, 목록 미리보기가 모두 쓴다.
 * EXIF 방향(회전·뒤집기 8가지)을 적용한 똑바로 선 픽셀을 돌려주므로, OCR 좌표(0~1)가 화면과 구운 사본에 같은 자리로 맞는다.
 * 긴 변이 [maxPx] 이하가 되도록 2의 거듭제곱으로 줄여 읽는다(가로세로 비율은 그대로).
 * 세로로 긴 영수증(긴 변이 짧은 변의 2배 이상)은 글자가 작아지지 않게 짧은 변 [maxPx]/2, 긴 변 [maxPx]×3까지 둔다.
 */
internal object ReceiptImages {
    fun decode(
        file: File,
        maxPx: Int = 3000,
    ): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw ProcessingException(ProcessingFailure.InvalidImage)
        var sample = 1
        val long = maxOf(bounds.outWidth, bounds.outHeight)
        val short = minOf(bounds.outWidth, bounds.outHeight)
        if (long >= 2 * short) {
            while (short / sample > maxPx / 2 || long / sample > maxPx * 3) sample *= 2
        } else {
            while (long / sample > maxPx) sample *= 2
        }
        val decoded =
            BitmapFactory.decodeFile(
                file.path,
                BitmapFactory.Options().apply {
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                },
            ) ?: throw ProcessingException(ProcessingFailure.InvalidImage)
        val orientation =
            runCatching { ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) }
                .getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        val matrix = orientationMatrix(orientation) ?: return decoded
        return Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
    }

    /** EXIF 방향 값 → 똑바로 세우는 변환. 1(그대로)이거나 모르는 값이면 null. */
    private fun orientationMatrix(orientation: Int): Matrix? =
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> {
                Matrix().apply { postScale(-1f, 1f) }
            }

            ExifInterface.ORIENTATION_ROTATE_180 -> {
                Matrix().apply { postRotate(180f) }
            }

            ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
                Matrix().apply { postScale(1f, -1f) }
            }

            ExifInterface.ORIENTATION_TRANSPOSE -> {
                Matrix().apply {
                    postRotate(90f)
                    postScale(-1f, 1f)
                }
            }

            ExifInterface.ORIENTATION_ROTATE_90 -> {
                Matrix().apply { postRotate(90f) }
            }

            ExifInterface.ORIENTATION_TRANSVERSE -> {
                Matrix().apply {
                    postRotate(-90f)
                    postScale(-1f, 1f)
                }
            }

            ExifInterface.ORIENTATION_ROTATE_270 -> {
                Matrix().apply { postRotate(270f) }
            }

            else -> {
                null
            }
        }
}

/**
 * ML Kit 번들 일본어·한국어 모델(ADR-0013). 기기 안에서만 동작하고 모델을 내려받지 않는다.
 * 사진마다 두 모델로 모두 읽고 [OcrLanguageChoice.choose]로 한쪽 결과를 고른다. 일본어 모델은 한글을 가나·한자로,
 * 한국어 모델은 한자·가나를 한글로 잘못 읽어 한 모델의 결과만으로는 다른 언어 사진을 가려낼 수 없었다(ADR-0013의 측정).
 * 모델은 처음 쓸 때 만들고, 한 모델의 준비·읽기가 실패해도 다른 모델의 결과를 쓴다.
 */
class MlKitReceiptRecognizer : ReceiptRecognizer {
    private val japanese by lazy { TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build()) }
    private val korean by lazy { TextRecognition.getClient(KoreanTextRecognizerOptions.Builder().build()) }

    override fun recognize(file: File): OcrResult {
        val bitmap = ReceiptImages.decode(file)
        val lines = OcrLanguageChoice.choose({ read(bitmap, OcrScript.Japanese) }, { read(bitmap, OcrScript.Korean) }).lines
        OcrLanguageChoice.checkInterrupted()
        val perLine =
            PhotoQuality.measureLines(lines, bitmap.width, bitmap.height) { x, y, rw, rh ->
                val argb = IntArray(rw * rh)
                bitmap.getPixels(argb, 0, rw, x, y, rw, rh)
                IntArray(argb.size) { i ->
                    val p = argb[i]
                    (((p shr 16) and 255) * 299 + ((p shr 8) and 255) * 587 + (p and 255) * 114) / 1000
                }
            }
        return OcrResult(bitmap.width, bitmap.height, lines, PhotoQuality.median(perLine.values), perLine)
    }

    /**
     * 한 모델로 사진 전체를 읽는다(품질 측정 전). 긴 영수증은 겹치는 타일로 나눠 읽고 합친다
     * (한 번에 읽으면 엔진이 한 구간을 통째로 건너뛸 수 있다). 측정 하네스도 이 함수로 모델별 결과와 시간을 잰다.
     */
    internal fun read(
        bitmap: Bitmap,
        script: OcrScript,
    ): OcrResult {
        val client =
            when (script) {
                OcrScript.Japanese -> japanese
                OcrScript.Korean -> korean
            }
        return OcrTiles.read(bitmap.width, bitmap.height) { tile ->
            val whole = tile.top == 0 && tile.height == bitmap.height
            read(if (whole) bitmap else Bitmap.createBitmap(bitmap, 0, tile.top, bitmap.width, tile.height), client)
        }
    }

    /** 비트맵 하나(사진 전체 또는 타일)를 읽어 그 비트맵 안 0~1 좌표로. */
    private fun read(
        bitmap: Bitmap,
        client: TextRecognizer,
    ): OcrResult {
        val result =
            try {
                Tasks.await(client.process(InputImage.fromBitmap(bitmap, 0)))
            } catch (e: ExecutionException) {
                throw ProcessingException(ProcessingFailure.RecognitionError)
            }
        val w = bitmap.width.toDouble()
        val h = bitmap.height.toDouble()
        val lines =
            result.textBlocks
                .flatMap { it.lines }
                .mapNotNull { line -> line.boundingBox?.let { line to it } }
                .sortedBy { it.second.top }
                .mapIndexed { i, (line, b) ->
                    // 기울어진 글자 상자의 네 모서리(왼위부터 시계 방향). 가림 띠를 줄 방향으로 굽는 데 쓴다.
                    val corners =
                        line.cornerPoints
                            ?.takeIf { it.size == 4 }
                            ?.flatMap { listOf(it.x / w, it.y / h) }
                    // 가격·날짜가 섞인 줄은 낱말 상자로 번호 부분만 덮을 수 있는지 본다.
                    val numberBox =
                        if (SensitiveText.isMixed(line.text)) {
                            NumberSpan.box(
                                line.elements.mapNotNull { e ->
                                    e.boundingBox?.let { eb -> e.text to listOf(eb.left / w, eb.top / h, eb.right / w, eb.bottom / h) }
                                },
                            )
                        } else {
                            null
                        }
                    OcrLine(
                        i,
                        line.text,
                        b.left / w,
                        b.top / h,
                        b.width() / w,
                        b.height() / h,
                        corners,
                        numberBox,
                        line.confidence.toDouble(),
                    )
                }
        return OcrResult(bitmap.width, bitmap.height, lines)
    }
}

/** 새 ARGB 비트맵에 검은 사각형을 굽는다. 확인한 경우에만 불린다. */
object CanvasReceiptFlattener : ReceiptFlattener {
    override fun flatten(
        original: File,
        shapes: (width: Int, height: Int) -> List<MaskShape>,
    ): ByteArray {
        val source = ReceiptImages.decode(original)
        val output = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        canvas.drawColor(Color.WHITE)
        canvas.drawBitmap(source, 0f, 0f, null)
        val paint =
            Paint().apply {
                color = Color.BLACK
                style = Paint.Style.FILL
                isAntiAlias = false
            }
        shapes(source.width, source.height).forEach { shape ->
            when (shape) {
                is MaskShape.Rect -> {
                    canvas.drawRect(shape.left.toFloat(), shape.top.toFloat(), shape.right.toFloat(), shape.bottom.toFloat(), paint)
                }

                is MaskShape.Quad -> {
                    val path = Path()
                    path.moveTo(shape.xs[0].toFloat(), shape.ys[0].toFloat())
                    for (i in 1 until 4) path.lineTo(shape.xs[i].toFloat(), shape.ys[i].toFloat())
                    path.close()
                    canvas.drawPath(path, paint)
                }
            }
        }
        return ByteArrayOutputStream().also { check(output.compress(Bitmap.CompressFormat.PNG, 100, it)) }.toByteArray()
    }
}
