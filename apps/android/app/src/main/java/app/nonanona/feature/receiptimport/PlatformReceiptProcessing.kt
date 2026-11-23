package app.nonanona.feature.receiptimport

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.media.ExifInterface
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ExecutionException

/**
 * 영수증 사진 디코딩은 이것 하나다: OCR, 가림 굽기, 검토 화면의 원본·가림 표시, 목록 미리보기가 모두 쓴다.
 * EXIF 방향(회전·뒤집기 8가지)을 적용한 똑바로 선 픽셀을 돌려주므로, OCR 좌표(0~1)가 화면과 구운 사본에 같은 자리로 맞는다.
 * 긴 변이 [maxPx] 이하가 되도록 2의 거듭제곱으로 줄여 읽는다(가로세로 비율은 그대로).
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
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > maxPx) sample *= 2
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

/** ML Kit 번들 일본어 모델. 기기 안에서만 동작한다(native-batch-import 실험에서 옮김). */
class MlKitReceiptRecognizer : ReceiptRecognizer {
    private val client = TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build())

    override fun recognize(file: File): OcrResult {
        val bitmap = ReceiptImages.decode(file)
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
                .mapNotNull { line -> line.boundingBox?.let { line.text to it } }
                .sortedBy { it.second.top }
                .mapIndexed { i, (text, b) -> OcrLine(i, text, b.left / w, b.top / h, b.width() / w, b.height() / h) }
        return OcrResult(bitmap.width, bitmap.height, lines)
    }
}

/** 새 ARGB 비트맵에 검은 사각형을 굽는다. 확인한 경우에만 불린다. */
object CanvasReceiptFlattener : ReceiptFlattener {
    override fun flatten(
        original: File,
        rects: List<IntArray>,
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
        rects.forEach { (l, t, r, b) -> canvas.drawRect(l.toFloat(), t.toFloat(), r.toFloat(), b.toFloat(), paint) }
        return ByteArrayOutputStream().also { check(output.compress(Bitmap.CompressFormat.PNG, 100, it)) }.toByteArray()
    }
}
