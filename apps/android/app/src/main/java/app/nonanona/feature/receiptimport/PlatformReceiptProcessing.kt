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

/** OCR과 가림 굽기가 같은 디코딩(방향 적용, 긴 변 3000px 이하)을 써서 OCR 좌표가 픽셀과 맞게 한다. */
private object ReceiptImages {
    fun decode(file: File): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw ProcessingException(ProcessingFailure.InvalidImage)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 3000) sample *= 2
        val decoded =
            BitmapFactory.decodeFile(
                file.path,
                BitmapFactory.Options().apply {
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                },
            ) ?: throw ProcessingException(ProcessingFailure.InvalidImage)
        val degrees =
            when (runCatching { ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }.getOrDefault(1)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        if (degrees == 0f) return decoded
        return Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, Matrix().apply { postRotate(degrees) }, true)
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
