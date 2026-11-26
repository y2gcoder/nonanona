package app.nonanona

import app.nonanona.feature.receiptimport.MaskShape
import app.nonanona.feature.receiptimport.ReceiptFlattener
import java.awt.Color
import java.awt.RenderingHints
import java.awt.geom.Path2D
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import javax.imageio.ImageIO

/** JVM 시험용 굽기(Android Canvas 대신 ImageIO, 계단 없이 채우기). 원본 메타데이터를 옮기지 않는다. */
object JvmFlattener : ReceiptFlattener {
    override fun flatten(
        original: java.io.File,
        shapes: (width: Int, height: Int) -> List<MaskShape>,
    ): ByteArray {
        val source = ImageIO.read(original)
        val image = BufferedImage(source.width, source.height, BufferedImage.TYPE_INT_RGB)
        val g = image.createGraphics()
        g.drawImage(source, 0, 0, null)
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_OFF)
        g.color = Color.BLACK

        fun path(shape: MaskShape): java.awt.Shape =
            when (shape) {
                is MaskShape.Rect -> {
                    java.awt.Rectangle(shape.left, shape.top, shape.right - shape.left, shape.bottom - shape.top)
                }

                is MaskShape.Quad -> {
                    Path2D.Double().apply {
                        moveTo(shape.xs[0], shape.ys[0])
                        for (i in 1 until 4) lineTo(shape.xs[i], shape.ys[i])
                        closePath()
                    }
                }

                is MaskShape.Restore -> {
                    path(shape.area)
                }
            }
        // 칠하는 순서대로: 되돌림 영역은 원본 픽셀을 다시 그린다.
        for (shape in shapes(source.width, source.height)) {
            if (shape is MaskShape.Restore) {
                g.clip = path(shape.area)
                g.drawImage(source, 0, 0, null)
                g.clip = null
            } else {
                g.fill(path(shape))
            }
        }
        g.dispose()
        return ByteArrayOutputStream().also { ImageIO.write(image, "png", it) }.toByteArray()
    }
}
