package app.nonanona

import app.nonanona.feature.settlement.ExpenseReview
import app.nonanona.feature.settlement.ExpenseStatus
import app.nonanona.feature.settlement.ExpenseTarget
import app.nonanona.feature.settlement.LedgerExpense
import app.nonanona.feature.settlement.LedgerMember
import app.nonanona.feature.settlement.MemberId
import app.nonanona.feature.settlement.ReviewSaveState
import app.nonanona.feature.settlement.RoomController
import app.nonanona.feature.settlement.RoomLedger
import app.nonanona.feature.settlement.SettlementException
import app.nonanona.feature.settlement.SettlementFailure
import app.nonanona.feature.settlement.ShareLine
import app.nonanona.feature.settlement.ShareMode
import app.nonanona.feature.trip.RoomLoadException
import app.nonanona.feature.trip.RoomLoadFailure
import app.nonanona.feature.trip.TripId
import app.nonanona.localbackend.LocalBackendConfig
import app.nonanona.localbackend.LocalSettlementGateway
import app.nonanona.localbackend.LocalSupabaseSession
import app.nonanona.localbackend.LocalTripGateway
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.net.InetSocketAddress
import java.util.UUID

/**
 * 로컬 구현체가 성공 응답(HTTP 200)의 본문이 깨졌거나 객체가 아닐 때 형식 검사 안에서 Unknown으로 옮기는지,
 * 그 실패가 다시 시도할 수 있는 상태(같은 요청 키)로 남는지. 실제 HTTP로 루프백의 작은 서버에 보낸다(가상 값).
 */
class LocalSettlementParseTest {
    @get:Rule val folder = TemporaryFolder()
    private lateinit var server: HttpServer
    private val bodies = ArrayDeque<String>()
    private val requests = mutableListOf<JSONObject>()
    private lateinit var session: LocalSupabaseSession

    @Before
    fun start() {
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/rest/v1/rpc/") { exchange ->
            requests += JSONObject(exchange.requestBody.readBytes().decodeToString())
            val body = (bodies.removeFirstOrNull() ?: "{}").toByteArray()
            exchange.sendResponseHeaders(200, body.size.toLong())
            exchange.responseBody.use { it.write(body) }
        }
        server.start()
        val file = folder.newFile("session.properties")
        file.writeText(
            "accessToken=synthetic\nrefreshToken=synthetic\nexpiresAt=${System.currentTimeMillis() + 3_600_000}\nuserId=h\ndisplayName=다라\n",
        )
        val config = LocalBackendConfig.of("http://127.0.0.1:${server.address.port}", "synthetic-key", "host@example.com", "synthetic")!!
        session = LocalSupabaseSession(config, file)
    }

    @After
    fun stop() = server.stop(0)

    private val review =
        ExpenseReview(
            "e",
            1,
            UUID.randomUUID(),
            ExpenseReview.Decision.Include(MemberId("h"), null, listOf(ShareLine(MemberId("h"), 38000))),
        )

    @Test
    fun malformedOrNonObjectSuccessBodiesBecomeUnknown() =
        runBlocking {
            val gateway = LocalSettlementGateway(session)
            for (body in listOf("[]", "not json", "", "null", """{"version":"x"}""")) {
                bodies.addLast(body)
                try {
                    gateway.review(review, TripId("t"))
                    fail("expected failure for ${body.ifEmpty { "<empty>" }}")
                } catch (e: SettlementException) {
                    assertEquals(body, SettlementFailure.Unknown, e.failure)
                }
            }
            bodies.addLast("[]")
            try {
                LocalTripGateway(session).ledger(TripId("t"))
                fail("expected failure")
            } catch (e: RoomLoadException) {
                assertEquals(RoomLoadFailure.Unknown, e.failure)
            }
        }

    @Test
    fun unknownReviewResponseLeavesARetryableFailedStateWithTheSameRequestKey() {
        val host = LedgerMember(MemberId("h"), "다라", true)
        val trip = TripId("t")
        val ledger =
            RoomLedger(
                trip,
                "가상",
                false,
                1,
                true,
                host.id,
                listOf(host),
                listOf(
                    LedgerExpense(
                        "e",
                        1,
                        true,
                        host.id,
                        "2026-11-08",
                        38000,
                        "KRW",
                        "ticket",
                        ExpenseStatus.Pending,
                        null,
                        null,
                        null,
                        emptyList(),
                    ),
                ),
            )
        val trips =
            object : TripGatewayStub() {
                override suspend fun acceptInvite(code: app.nonanona.feature.trip.InviteCode) = throw UnsupportedOperationException()

                override suspend fun submitReceipt(
                    upload: app.nonanona.feature.trip.ReceiptExpenseUpload,
                    trip: TripId,
                ) = throw UnsupportedOperationException()

                override suspend fun ledger(trip: TripId) = ledger
            }
        var saved = 0
        val controller =
            RoomController(CoroutineScope(Dispatchers.Unconfined), trips, LocalSettlementGateway(session), onSessionExpired = {
            }, onReviewSaved = { saved++ })
        runBlocking { controller.loadLedger(trip) }
        val target = ExpenseTarget(trip, "e")
        assertTrue(controller.prepareReview(target))
        controller.editForm(target) { it.copy(payer = host.id, mode = ShareMode.One, one = host.id) }

        bodies.addLast("[]")
        runBlocking { controller.include(target) }
        waitUntil { controller.state.value.reviewState[target] is ReviewSaveState.Failed }
        assertEquals(ReviewSaveState.Failed(SettlementFailure.Unknown), controller.state.value.reviewState[target])

        bodies.addLast("""{"expense_id":"e","version":2,"status":"included","revision":2,"replayed":false}""")
        runBlocking { controller.include(target) }
        waitUntil { saved == 1 }
        assertNull(controller.state.value.reviewState[target])
        val keys = requests.filter { it.has("p_expense") }.map { it.getString("p_request_id") }
        assertEquals(2, keys.size)
        assertEquals("다시 보내면 같은 요청 키", keys[0], keys[1])
    }

    private fun waitUntil(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition()) {
            if (System.currentTimeMillis() > deadline) fail("condition not met")
            Thread.sleep(20)
        }
    }
}
