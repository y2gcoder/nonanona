package app.nonanona

import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ImageBitmapConfig
import androidx.compose.ui.graphics.colorspace.ColorSpace
import app.nonanona.feature.settlement.PngCheck
import app.nonanona.feature.settlement.ReceiptDecoder
import java.io.ByteArrayInputStream
import java.io.File
import java.security.MessageDigest
import javax.imageio.ImageIO

/** JVM 시험용 그림·고정 값. 실제 가상 영수증 PNG와 앞 절반만 남긴 잘린 PNG. */
object TestImages {
    val png: ByteArray =
        generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "apps/fixtures/receipts/receipt-r01.png") }
            .first { it.isFile }
            .readBytes()
    val truncated: ByteArray = png.copyOf(png.size / 2)

    fun sha(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /** 앱과 같은 구조 검사(PngCheck) 뒤 JVM의 실제 PNG 디코더(ImageIO)로 끝까지 푼다. 앱은 그 자리에 BitmapFactory를 쓴다. */
    val decoder =
        ReceiptDecoder { bytes ->
            if (!PngCheck.isComplete(bytes)) {
                null
            } else {
                ImageIO.read(ByteArrayInputStream(bytes))?.let { FakeBitmap(it.width, it.height) }
            }
        }

    class FakeBitmap(
        override val width: Int,
        override val height: Int,
    ) : ImageBitmap {
        override val colorSpace: ColorSpace get() = throw UnsupportedOperationException()
        override val hasAlpha: Boolean = false
        override val config: ImageBitmapConfig = ImageBitmapConfig.Argb8888

        override fun readPixels(
            buffer: IntArray,
            startX: Int,
            startY: Int,
            width: Int,
            height: Int,
            bufferOffset: Int,
            stride: Int,
        ) = Unit

        override fun prepareToDraw() = Unit
    }
}
