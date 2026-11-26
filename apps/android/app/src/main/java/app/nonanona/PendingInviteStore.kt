package app.nonanona

import app.nonanona.feature.trip.InviteCode
import java.io.File
import java.io.IOException
import java.util.Properties

data class PendingInvite(
    val code: InviteCode,
    val receivedAtEpochMillis: Long,
)

/**
 * 로그인하는 동안 연 초대를 기기에 보관한다. 앱이 중간에 종료돼도 다시 열면 같은 초대로 돌아간다(ADR-0002).
 */
class PendingInviteStore(
    private val file: File,
) {
    fun load(): PendingInvite? {
        if (!file.isFile) return null
        val props = Properties().apply { file.reader(Charsets.UTF_8).use { load(it) } }
        val code = props.getProperty("code")?.let(::InviteCode) ?: return null
        val receivedAt = props.getProperty("receivedAt")?.toLongOrNull() ?: return null
        return PendingInvite(code, receivedAt)
    }

    fun save(invite: PendingInvite) {
        file.parentFile?.mkdirs()
        val staging = File(file.parentFile, ".${file.name}.partial")
        val props =
            Properties().apply {
                setProperty("code", invite.code.value)
                setProperty("receivedAt", invite.receivedAtEpochMillis.toString())
            }
        staging.writer(Charsets.UTF_8).use { props.store(it, null) }
        if (!staging.renameTo(file)) throw IOException("cannot save pending invite")
    }

    fun clear() {
        file.delete()
    }
}
