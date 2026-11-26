package app.nonanona.feature.receiptimport

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.webkit.MimeTypeMap

/** 공유 메뉴(ACTION_SEND, ACTION_SEND_MULTIPLE)로 받은 이미지 URI를 꺼낸다. */
fun Intent.sharedImageUris(): List<Uri> {
    if (type?.startsWith("image/") != true) return emptyList()
    return when (action) {
        Intent.ACTION_SEND -> listOfNotNull(streamExtra())
        Intent.ACTION_SEND_MULTIPLE -> streamListExtra()
        else -> emptyList()
    }
}

private fun Intent.streamExtra(): Uri? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
    } else {
        @Suppress("DEPRECATION")
        getParcelableExtra(Intent.EXTRA_STREAM)
    }

private fun Intent.streamListExtra(): List<Uri> =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
    } else {
        @Suppress("DEPRECATION")
        getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
    }

fun ContentResolver.incomingPhoto(uri: Uri): IncomingPhoto {
    val extension = getType(uri)?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) } ?: "img"
    return IncomingPhoto(extension) { openInputStream(uri) ?: error("cannot open shared photo") }
}
