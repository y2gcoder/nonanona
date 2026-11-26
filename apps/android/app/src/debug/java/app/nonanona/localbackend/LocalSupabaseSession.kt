package app.nonanona.localbackend

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.util.Properties

/** 로컬 debug 모드 설정. 로컬 스택(에뮬레이터에서 본 호스트 10.0.2.2)만 받아들인다. */
class LocalBackendConfig private constructor(
    val baseUrl: String,
    val publishableKey: String,
    val testEmail: String,
    val testPassword: String,
) {
    companion object {
        private val allowedHosts = setOf("10.0.2.2", "127.0.0.1", "localhost")

        fun of(
            baseUrl: String,
            publishableKey: String,
            testEmail: String,
            testPassword: String,
        ): LocalBackendConfig? {
            if (listOf(baseUrl, publishableKey, testEmail, testPassword).any { it.isBlank() }) return null
            val uri = runCatching { URI(baseUrl) }.getOrNull() ?: return null
            val pathless = uri.rawPath.isNullOrEmpty() || uri.rawPath == "/"
            if (uri.scheme != "http" || uri.host !in allowedHosts || !pathless || uri.rawQuery != null) return null
            return LocalBackendConfig(baseUrl.trimEnd('/'), publishableKey, testEmail, testPassword)
        }
    }
}

/** 서버 응답을 기능 실패로 옮기기 전의 중립 결과. 상태 코드와 서버가 정한 코드만 담는다. */
sealed interface Outcome {
    data object Transport : Outcome

    data class Http(
        val status: Int,
        val code: String?,
    ) : Outcome
}

class LocalBackendException(
    val outcome: Outcome,
) : Exception("local backend request failed")

/**
 * Auth는 `error_code`, Data API는 `code`·`message`에 서버가 정한 코드를 담는다.
 * 여행방 RPC는 message에 고정 코드(invite_expired 등)를 담으므로 PTxxx일 때만 message를 쓴다.
 */
fun serverCode(
    errorCode: String?,
    code: String?,
    message: String?,
): String? =
    when {
        errorCode != null -> errorCode
        code != null && code.startsWith("PT") -> message
        else -> code
    }

/** PostgREST가 JWT를 받아들이지 않은 경우(PGRST301 잘못된 JWT, PGRST303 만료). */
fun isRejectedJwt(outcome: Outcome): Boolean =
    outcome is Outcome.Http && outcome.status == 401 && outcome.code in setOf("PGRST301", "PGRST303")

/**
 * 로컬 Supabase Auth 세션. 비밀번호 로그인, 토큰 갱신, 세션 저장을 맡고 Data API 호출에 토큰을 붙인다.
 * 토큰과 응답 원문은 로그로 남기지 않는다.
 */
class LocalSupabaseSession(
    val config: LocalBackendConfig,
    private val file: File,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    data class Stored(
        val accessToken: String,
        val refreshToken: String,
        val expiresAtMillis: Long,
        val userId: String,
        val displayName: String,
    )

    private val lock = Mutex()

    suspend fun stored(): Stored? = lock.withLock { read() }

    suspend fun signIn(): Stored =
        lock.withLock {
            token("password", JSONObject().put("email", config.testEmail).put("password", config.testPassword))
        }

    suspend fun clear() {
        lock.withLock { runInterruptible(Dispatchers.IO) { file.delete() } }
    }

    /** 만료가 가까우면 먼저 갱신한 뒤 Data API RPC를 부른다. 401(JWT 거절)이면 한 번 갱신하고 다시 부른다. */
    suspend fun rpc(
        name: String,
        body: JSONObject,
    ): JSONObject = JSONObject(String(authorized("/rest/v1/rpc/$name", body.toString().toByteArray(), "application/json")))

    /** 응답이 객체가 아닐 수 있는 RPC(배열·null). 본문 글자를 그대로 돌려준다. */
    suspend fun rpcRaw(
        name: String,
        body: JSONObject,
    ): String = String(authorized("/rest/v1/rpc/$name", body.toString().toByteArray(), "application/json"))

    /** 인증한 요청. 만료가 가까우면 먼저 갱신하고, JWT를 거절하면 한 번 갱신해 다시 보낸다. */
    suspend fun authorized(
        path: String,
        body: ByteArray,
        contentType: String,
    ): ByteArray =
        lock.withLock {
            var session = read() ?: throw LocalBackendException(Outcome.Http(401, null))
            if (session.expiresAtMillis - clock() < 5_000) session = refresh(session)
            try {
                send(path, body, contentType, session.accessToken)
            } catch (e: LocalBackendException) {
                if (!isRejectedJwt(e.outcome)) throw e
                send(path, body, contentType, refresh(session).accessToken)
            }
        }

    /**
     * 비공개 Storage 객체를 인증해 받는다(메모리로만, HTTP 캐시를 쓰지 않는다). 공개 URL은 쓰지 않는다.
     *
     * Storage는 토큰 문제를 둘로 알린다. InvalidJWT는 토큰 문제가 분명하므로 한 번 갱신해 다시 받는다.
     * AccessDenied는 잘못되거나 만료된 토큰과 정책 거절이 같은 코드라(로컬 스택에서 확인) Auth(/auth/v1/user)에 지금 토큰을
     * 물어 가른다: Auth가 받으면 진짜 거절, 거절하면 한 번 갱신해 다시 받기, 닿지 않으면 연결 실패.
     * 갱신은 많아야 한 번이고, 갱신 뒤에도 토큰 거절이면 세션 만료(session_expired)로 끝낸다(iOS storageGet과 같은 규칙).
     */
    suspend fun storageGet(path: String): ByteArray =
        lock.withLock {
            var session = read() ?: throw LocalBackendException(Outcome.Http(401, null))
            if (session.expiresAtMillis - clock() < 5_000) session = refresh(session)
            var refreshed = false
            while (true) {
                try {
                    return@withLock send(path, null, null, session.accessToken, method = "GET")
                } catch (e: LocalBackendException) {
                    val code = (e.outcome as? Outcome.Http)?.code
                    if (code != "InvalidJWT" && code != "AccessDenied" && !isRejectedJwt(e.outcome)) throw e
                    if (code == "AccessDenied") {
                        when (probe(session)) {
                            Probe.Accepted -> throw e

                            // 토큰은 유효하다: 정책 거절
                            Probe.Unreachable -> throw LocalBackendException(Outcome.Transport)

                            Probe.Rejected -> Unit
                        }
                    }
                    if (refreshed) throw LocalBackendException(Outcome.Http(401, "session_expired"))
                    session = refresh(session)
                    refreshed = true
                }
            }
            @Suppress("UNREACHABLE_CODE")
            throw IllegalStateException()
        }

    private enum class Probe { Accepted, Rejected, Unreachable }

    /** Auth가 이 토큰을 받는지 묻는다. 200이면 받음, 401·403이면 거절, 연결 실패·그 밖이면 닿지 않음(잠금 안에서 부른다). */
    private suspend fun probe(session: Stored): Probe =
        try {
            runInterruptible(Dispatchers.IO) {
                val connection = URI(config.baseUrl + "/auth/v1/user").toURL().openConnection() as HttpURLConnection
                try {
                    connection.connectTimeout = TIMEOUT_MILLIS
                    connection.readTimeout = TIMEOUT_MILLIS
                    connection.useCaches = false
                    connection.setRequestProperty("apikey", config.publishableKey)
                    connection.setRequestProperty("Authorization", "Bearer ${session.accessToken}")
                    when (connection.responseCode) {
                        200 -> Probe.Accepted
                        401, 403 -> Probe.Rejected
                        else -> Probe.Unreachable
                    }
                } finally {
                    connection.disconnect()
                }
            }
        } catch (e: IOException) {
            currentCoroutineContext().ensureActive()
            Probe.Unreachable
        }

    /** Auth가 지금 세션을 받아들이는지 확인한다(Storage는 잘못된 토큰과 권한 없음을 같은 코드로 알리므로 구분용). */
    suspend fun isSessionValid(): Boolean {
        val token = stored()?.accessToken ?: return false
        return try {
            runInterruptible(Dispatchers.IO) {
                val connection = URI(config.baseUrl + "/auth/v1/user").toURL().openConnection() as HttpURLConnection
                try {
                    connection.connectTimeout = TIMEOUT_MILLIS
                    connection.readTimeout = TIMEOUT_MILLIS
                    connection.setRequestProperty("apikey", config.publishableKey)
                    connection.setRequestProperty("Authorization", "Bearer $token")
                    connection.responseCode == 200
                } finally {
                    connection.disconnect()
                }
            }
        } catch (e: IOException) {
            currentCoroutineContext().ensureActive()
            true
        }
    }

    private suspend fun refresh(session: Stored): Stored = token("refresh_token", JSONObject().put("refresh_token", session.refreshToken))

    private suspend fun token(
        grant: String,
        body: JSONObject,
    ): Stored {
        val json =
            JSONObject(String(send("/auth/v1/token?grant_type=$grant", body.toString().toByteArray(), "application/json", bearer = null)))
        val user = json.getJSONObject("user")
        val session =
            Stored(
                accessToken = json.getString("access_token"),
                refreshToken = json.getString("refresh_token"),
                expiresAtMillis = json.getLong("expires_at") * 1000,
                userId = user.getString("id"),
                displayName = user.optJSONObject("user_metadata")?.optString("display_name").orEmpty(),
            )
        runInterruptible(Dispatchers.IO) { write(session) }
        return session
    }

    private suspend fun send(
        path: String,
        body: ByteArray?,
        contentType: String?,
        bearer: String?,
        method: String = "POST",
    ): ByteArray {
        val result =
            try {
                runInterruptible(Dispatchers.IO) {
                    val connection = URI(config.baseUrl + path).toURL().openConnection() as HttpURLConnection
                    try {
                        connection.requestMethod = method
                        connection.connectTimeout = TIMEOUT_MILLIS
                        connection.readTimeout = TIMEOUT_MILLIS
                        connection.useCaches = false
                        contentType?.let { connection.setRequestProperty("Content-Type", it) }
                        connection.setRequestProperty("apikey", config.publishableKey)
                        bearer?.let { connection.setRequestProperty("Authorization", "Bearer $it") }
                        if (body != null) {
                            connection.doOutput = true
                            connection.outputStream.use { it.write(body) }
                        }
                        val status = connection.responseCode
                        val stream = if (status in 200..299) connection.inputStream else connection.errorStream
                        status to (stream?.use { it.readBytes() } ?: ByteArray(0))
                    } finally {
                        connection.disconnect()
                    }
                }
            } catch (e: IOException) {
                // 취소로 끊긴 입출력은 연결 실패가 아니라 취소로 전한다.
                currentCoroutineContext().ensureActive()
                throw LocalBackendException(Outcome.Transport)
            }
        val (status, bytes) = result
        if (status in 200..299) return bytes
        val error = runCatching { JSONObject(String(bytes)) }.getOrNull()
        val code =
            serverCode(
                errorCode = error?.optString("error_code")?.takeIf { it.isNotEmpty() },
                code = error?.opt("code")?.takeIf { it is String } as String?,
                message = error?.optString("message")?.takeIf { it.isNotEmpty() },
            )
        throw LocalBackendException(Outcome.Http(status, code))
    }

    private fun read(): Stored? {
        if (!file.isFile) return null
        val p = Properties().apply { file.reader(Charsets.UTF_8).use { load(it) } }
        return Stored(
            accessToken = p.getProperty("accessToken") ?: return null,
            refreshToken = p.getProperty("refreshToken") ?: return null,
            expiresAtMillis = p.getProperty("expiresAt")?.toLongOrNull() ?: return null,
            userId = p.getProperty("userId") ?: return null,
            displayName = p.getProperty("displayName").orEmpty(),
        )
    }

    private fun write(session: Stored) {
        file.parentFile?.mkdirs()
        val staging = File(file.parentFile, ".${file.name}.partial")
        Properties()
            .apply {
                setProperty("accessToken", session.accessToken)
                setProperty("refreshToken", session.refreshToken)
                setProperty("expiresAt", session.expiresAtMillis.toString())
                setProperty("userId", session.userId)
                setProperty("displayName", session.displayName)
            }.let { props -> staging.writer(Charsets.UTF_8).use { props.store(it, null) } }
        if (!staging.renameTo(file)) throw IOException("cannot save session")
    }

    private companion object {
        const val TIMEOUT_MILLIS = 10_000
    }
}
