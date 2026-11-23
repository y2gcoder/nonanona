package app.nonanona

import app.nonanona.feature.settlement.ReceiptArtifactRef
import app.nonanona.feature.settlement.ReceiptViewException
import app.nonanona.feature.settlement.ReceiptViewFailure
import app.nonanona.feature.trip.TripId
import app.nonanona.localbackend.LocalBackendConfig
import app.nonanona.localbackend.LocalSupabaseSession
import app.nonanona.localbackend.LocalTripGateway
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.net.InetSocketAddress

/**
 * 루프백 HTTP 서버로 Storage 응답에 따른 세션 복구를 본다(가상 토큰·가상 PNG, iOS StorageSessionTests와 같은 시나리오).
 * 응답 모양은 로컬 스택에서 받은 것과 같다: 잘못되거나 만료된 토큰도 Storage는 400 AccessDenied, Auth /user는 403.
 */
class StorageSessionTest {
    @get:Rule val folder = TemporaryFolder()
    private lateinit var server: HttpServer
    private val storage = ArrayDeque<Pair<Int, String?>>() // 본문이 null이면 PNG
    private val auth = ArrayDeque<Int?>() // null이면 연결을 끊는다
    private val token = ArrayDeque<Pair<Int, String>>()
    private val log = mutableListOf<String>()
    private lateinit var gateway: LocalTripGateway

    private val trip = TripId("11111111-1111-4111-8111-111111111111")
    private val artifact =
        ReceiptArtifactRef(
            "${trip.value}/22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333.png",
            TestImages.sha(TestImages.png),
        )

    private fun storageError(code: String) = 400 to """{"statusCode":"403","error":"x","message":"x","code":"$code"}"""

    private val accessDenied = storageError("AccessDenied")
    private val invalidJwt = storageError("InvalidJWT")
    private val refreshed =
        200 to
            """{"access_token":"t2","refresh_token":"r2","expires_at":${System.currentTimeMillis() / 1000 + 3600},"user":{"id":"h","user_metadata":{"display_name":"다라"}}}"""
    private val refreshRejected = 400 to """{"code":400,"error_code":"refresh_token_not_found","msg":"x"}"""

    @Before
    fun start() {
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            val path = exchange.requestURI.path
            val bearer = exchange.requestHeaders.getFirst("Authorization")?.removePrefix("Bearer ") ?: "-"
            synchronized(log) { log += "${exchange.requestMethod} $path $bearer" }
            val answer: Pair<Int, ByteArray>? =
                when {
                    path.startsWith("/storage/") -> {
                        storage.removeFirstOrNull()?.let { (s, b) -> s to (b?.toByteArray() ?: TestImages.png) }
                    }

                    path == "/auth/v1/user" -> {
                        auth.removeFirstOrNull()?.let {
                            it to
                                (if (it == 200) """{"id":"h"}""" else """{"error_code":"bad_jwt"}""").toByteArray()
                        }
                    }

                    path == "/auth/v1/token" -> {
                        token.removeFirstOrNull()?.let { (s, b) -> s to b.toByteArray() }
                    }

                    else -> {
                        null
                    }
                }
            if (answer == null) {
                exchange.close() // 연결을 끊는다(닿지 않음)
            } else {
                exchange.sendResponseHeaders(answer.first, answer.second.size.toLong())
                exchange.responseBody.use { it.write(answer.second) }
            }
        }
        server.start()
        val file = folder.newFile("session.properties")
        file.writeText("accessToken=t1\nrefreshToken=r1\nexpiresAt=${System.currentTimeMillis() + 3_600_000}\nuserId=h\ndisplayName=다라\n")
        val config = LocalBackendConfig.of("http://127.0.0.1:${server.address.port}", "synthetic", "h@example.com", "synthetic")!!
        gateway = LocalTripGateway(LocalSupabaseSession(config, file))
    }

    @After
    fun stop() = server.stop(0)

    private fun fetch(): Result<ByteArray> =
        runBlocking {
            try {
                Result.success(gateway.maskedReceipt(artifact, trip).png)
            } catch (e: ReceiptViewException) {
                Result.failure(e)
            }
        }

    private fun failureOf(result: Result<ByteArray>) = (result.exceptionOrNull() as? ReceiptViewException)?.failure

    private fun count(part: String) = log.count { part in it }

    private fun onlyAuthenticatedStorage() =
        log.filter { "/storage/" in it }.forEach {
            assertTrue(
                "공개·서명 URL을 쓰지 않는다: $it",
                "/storage/v1/object/authenticated/receipts/" in it,
            )
        }

    @Test
    fun invalidJwtRefreshesOnceThenGetsTheCopy() {
        storage += listOf(invalidJwt, 200 to null)
        token += refreshed
        assertArrayEquals(TestImages.png, fetch().getOrThrow())
        assertEquals(listOf("GET", "POST", "GET"), log.map { it.split(" ")[0] })
        assertTrue("처음엔 옛 토큰", log[0].endsWith(" t1"))
        assertTrue("다시 받을 때 새 토큰", log[2].endsWith(" t2"))
        assertEquals(0, count("/auth/v1/user"))
        onlyAuthenticatedStorage()
    }

    @Test
    fun accessDeniedWithAValidSessionIsARealDenial() {
        storage += accessDenied
        auth += 200
        assertEquals(ReceiptViewFailure.Denied, failureOf(fetch()))
        assertEquals("유효한 세션이면 갱신하지 않는다", 0, count("/auth/v1/token"))
        assertEquals(1, count("/storage/"))
    }

    @Test
    fun accessDeniedWithARejectedTokenRefreshesOnceAndRetries() {
        storage += listOf(accessDenied, 200 to null)
        auth += 403
        token += refreshed
        assertArrayEquals(TestImages.png, fetch().getOrThrow())
        assertEquals(1, count("/auth/v1/token"))
        onlyAuthenticatedStorage()
    }

    @Test
    fun accessDeniedAndRefreshRejectedEndsTheSession() {
        storage += accessDenied
        auth += 403
        token += refreshRejected
        assertEquals(ReceiptViewFailure.SessionExpired, failureOf(fetch()))
    }

    @Test
    fun recoveryIsBoundedToOneRefresh() {
        storage += listOf(accessDenied, accessDenied)
        auth += listOf(403, 403)
        token += listOf(refreshed, refreshed)
        assertEquals(ReceiptViewFailure.SessionExpired, failureOf(fetch()))
        assertEquals(1, count("/auth/v1/token"))
        assertEquals(2, count("/storage/"))
    }

    @Test
    fun invalidJwtTwiceEndsTheSessionAfterOneRefresh() {
        storage += listOf(invalidJwt, invalidJwt)
        token += listOf(refreshed, refreshed)
        assertEquals(ReceiptViewFailure.SessionExpired, failureOf(fetch()))
        assertEquals(1, count("/auth/v1/token"))
    }

    @Test
    fun accessDeniedWithAuthUnreachableIsANetworkFailure() {
        storage += accessDenied
        auth += null as Int?
        assertEquals(ReceiptViewFailure.Network, failureOf(fetch()))
        assertFalse(log.any { "/auth/v1/token" in it })
    }

    @Test
    fun missingObjectIsNotProbedOrRefreshed() {
        storage += storageError("NoSuchKey")
        assertEquals(ReceiptViewFailure.Missing, failureOf(fetch()))
        assertEquals(1, log.size)
    }
}
