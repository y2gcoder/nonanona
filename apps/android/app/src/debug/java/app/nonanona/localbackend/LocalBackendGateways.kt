package app.nonanona.localbackend

import app.nonanona.feature.account.AccountId
import app.nonanona.feature.account.AccountSession
import app.nonanona.feature.account.AuthGateway
import app.nonanona.feature.account.SignInException
import app.nonanona.feature.account.SignInFailure
import app.nonanona.feature.account.SignInProvider
import app.nonanona.feature.settlement.ExcludedExpense
import app.nonanona.feature.settlement.ExpenseReview
import app.nonanona.feature.settlement.ExpenseStatus
import app.nonanona.feature.settlement.FinalSettlement
import app.nonanona.feature.settlement.FinalizeResult
import app.nonanona.feature.settlement.KrwBasis
import app.nonanona.feature.settlement.LedgerExpense
import app.nonanona.feature.settlement.LedgerMember
import app.nonanona.feature.settlement.MaskedReceiptImage
import app.nonanona.feature.settlement.MemberId
import app.nonanona.feature.settlement.ReceiptArtifactRef
import app.nonanona.feature.settlement.ReceiptViewException
import app.nonanona.feature.settlement.ReceiptViewFailure
import app.nonanona.feature.settlement.ReviewedExpense
import app.nonanona.feature.settlement.RoomLedger
import app.nonanona.feature.settlement.SettlementException
import app.nonanona.feature.settlement.SettlementFailure
import app.nonanona.feature.settlement.SettlementGateway
import app.nonanona.feature.settlement.SettlementPreview
import app.nonanona.feature.settlement.ShareLine
import app.nonanona.feature.settlement.Transfer
import app.nonanona.feature.trip.InviteAcceptException
import app.nonanona.feature.trip.InviteAcceptFailure
import app.nonanona.feature.trip.InviteCode
import app.nonanona.feature.trip.ManualExpenseUpload
import app.nonanona.feature.trip.ReceiptExpenseUpload
import app.nonanona.feature.trip.ReceiptUploadException
import app.nonanona.feature.trip.ReceiptUploadFailure
import app.nonanona.feature.trip.RoomLoadException
import app.nonanona.feature.trip.RoomLoadFailure
import app.nonanona.feature.trip.SubmittedExpense
import app.nonanona.feature.trip.TripGateway
import app.nonanona.feature.trip.TripId
import app.nonanona.feature.trip.TripMember
import app.nonanona.feature.trip.TripRoom
import app.nonanona.feature.trip.TripSummary
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/** 로컬 debug 모드의 인증 구현체. 실제 소셜 로그인이 아니라, 로컬 스택의 가상 계정으로 비밀번호 로그인한다. */
class LocalAuthGateway(
    private val session: LocalSupabaseSession,
    notice: String,
) : AuthGateway {
    override val providers = listOf(SignInProvider.Google)
    override val testOnlyNotice: String = notice

    override suspend fun restoreSession(): AccountSession? = session.stored()?.let { AccountSession(AccountId(it.userId), it.displayName) }

    override suspend fun signIn(provider: SignInProvider): AccountSession {
        val stored =
            try {
                session.signIn()
            } catch (e: LocalBackendException) {
                throw SignInException(signInFailure(e.outcome))
            } catch (e: JSONException) {
                throw SignInException(SignInFailure.Unknown)
            }
        return AccountSession(AccountId(stored.userId), stored.displayName)
    }

    override suspend fun endSession() = session.clear()

    companion object {
        /** Auth 응답을 로그인 실패로 옮긴다. 정해 둔 코드가 아니면 Unknown이다. */
        fun signInFailure(outcome: Outcome): SignInFailure =
            when {
                outcome is Outcome.Transport -> SignInFailure.Network
                outcome is Outcome.Http && (outcome.status == 429 || outcome.code == "over_request_rate_limit") -> SignInFailure.Unavailable
                outcome is Outcome.Http && outcome.status >= 500 -> SignInFailure.Unavailable
                else -> SignInFailure.Unknown
            }
    }
}

/** 로컬 debug 모드의 여행방 구현체. 실제 Auth 세션으로 accept_invite RPC를 부른다. */
class LocalTripGateway(
    private val session: LocalSupabaseSession,
    /** 검증용: 첫 올리기에서 사본은 올리고 지출 행을 만들기 전에 끊긴 것처럼 실패한다(debug 설정 파일). */
    failOnceAfterStorage: Boolean = false,
) : TripGateway {
    private val failAfterStorage = AtomicBoolean(failOnceAfterStorage)

    /**
     * 1) 사본을 비공개 버킷의 <trip>/<나>/<request_id>.png 로 올리고 2) RPC로 지출 행을 만든다.
     * 두 단계는 한 트랜잭션이 아니다. 1만 되고 끊기면 행 없는 객체가 남고(지출로 보이지 않음),
     * 같은 요청 키로 다시 시도하면 1은 "이미 있음"으로 넘어가고 2가 행을 만든다.
     */
    override suspend fun submitReceipt(
        upload: ReceiptExpenseUpload,
        trip: TripId,
    ): SubmittedExpense {
        val userId = session.stored()?.userId ?: throw ReceiptUploadException(ReceiptUploadFailure.SessionExpired)
        val path = "/storage/v1/object/receipts/${trip.value}/$userId/${upload.requestId}.png"
        try {
            session.authorized(path, upload.artifactPng, "image/png")
        } catch (e: LocalBackendException) {
            val code = (e.outcome as? Outcome.Http)?.code
            when (code) {
                "KeyAlreadyExists" -> {
                    Unit
                }

                // 앞선 시도가 이미 올렸다
                "AccessDenied" -> {
                    throw ReceiptUploadException(
                        if (session.isSessionValid()) ReceiptUploadFailure.DestinationUnavailable else ReceiptUploadFailure.SessionExpired,
                    )
                }

                else -> {
                    throw ReceiptUploadException(uploadFailure(e.outcome))
                }
            }
        }
        if (failAfterStorage.getAndSet(false)) throw ReceiptUploadException(ReceiptUploadFailure.Network)
        val json =
            try {
                session.rpc(
                    "submit_receipt_expense",
                    JSONObject()
                        .put("p_trip", trip.value)
                        .put("p_request_id", upload.requestId.toString())
                        .put("p_expense_date", upload.date)
                        .put("p_amount_minor", upload.amountMinor)
                        .put("p_currency", upload.currency)
                        .put("p_merchant", upload.merchant ?: JSONObject.NULL)
                        .put("p_artifact_sha256", upload.artifactSha256),
                )
            } catch (e: LocalBackendException) {
                throw ReceiptUploadException(uploadFailure(e.outcome))
            } catch (e: JSONException) {
                throw ReceiptUploadException(ReceiptUploadFailure.Unknown)
            }
        return try {
            SubmittedExpense(json.getString("expense_id"), json.getBoolean("replayed"))
        } catch (e: JSONException) {
            throw ReceiptUploadException(ReceiptUploadFailure.Unknown)
        }
    }

    /** 증빙 없는 직접 입력: 사본 없이 허용 필드만 RPC로 보낸다. 같은 요청 키는 같은 지출로 수렴한다. */
    override suspend fun submitManualExpense(
        upload: ManualExpenseUpload,
        trip: TripId,
    ): SubmittedExpense {
        val json =
            try {
                session.rpc(
                    "submit_manual_expense",
                    JSONObject()
                        .put("p_trip", trip.value)
                        .put("p_request_id", upload.requestId.toString())
                        .put("p_expense_date", upload.date)
                        .put("p_amount_minor", upload.amountMinor)
                        .put("p_currency", upload.currency)
                        .put("p_merchant", upload.merchant ?: JSONObject.NULL),
                )
            } catch (e: LocalBackendException) {
                throw ReceiptUploadException(uploadFailure(e.outcome))
            } catch (e: JSONException) {
                throw ReceiptUploadException(ReceiptUploadFailure.Unknown)
            }
        return try {
            SubmittedExpense(json.getString("expense_id"), json.getBoolean("replayed"))
        } catch (e: JSONException) {
            throw ReceiptUploadException(ReceiptUploadFailure.Unknown)
        }
    }

    override suspend fun myTrips(): List<TripSummary> {
        val raw = roomCall { session.rpcRaw("list_my_trips", JSONObject()) }
        return try {
            val rows = JSONArray(raw)
            (0 until rows.length()).map { i ->
                rows.getJSONObject(i).let {
                    TripSummary(
                        TripId(it.getString("trip_id")),
                        it.getString("trip_name"),
                        isHost = it.getString("my_role") == "host",
                        isFinalized = it.getString("status") == "finalized",
                    )
                }
            }
        } catch (e: JSONException) {
            throw RoomLoadException(RoomLoadFailure.Unknown)
        }
    }

    override suspend fun ledger(trip: TripId): RoomLedger {
        val raw = roomCall { session.rpcRaw("get_room_ledger", JSONObject().put("p_trip", trip.value)) }
        return try {
            LocalJson.ledger(JSONObject(raw)) ?: throw RoomLoadException(RoomLoadFailure.Unknown)
        } catch (e: JSONException) {
            throw RoomLoadException(RoomLoadFailure.Unknown)
        }
    }

    /**
     * 비공개 버킷 receipts의 인증 다운로드(/storage/v1/object/authenticated/…). 공개·서명 URL은 쓰지 않는다.
     * 보내기 전에 경로가 이 여행방의 사본 경로인지, 받은 뒤 PNG이고 장부의 해시와 같은지 확인한다.
     */
    override suspend fun maskedReceipt(
        artifact: ReceiptArtifactRef,
        trip: TripId,
    ): MaskedReceiptImage {
        if (!isArtifactPath(artifact.path, trip) || !artifact.sha256.matches(Regex("[0-9a-f]{64}"))) {
            throw ReceiptViewException(ReceiptViewFailure.Mismatch)
        }
        val bytes =
            try {
                session.authorizedGet("/storage/v1/object/authenticated/receipts/${artifact.path}")
            } catch (e: LocalBackendException) {
                throw ReceiptViewException(receiptViewFailure(e.outcome))
            }
        return verified(bytes, artifact)
    }

    private suspend fun roomCall(block: suspend () -> String): String =
        try {
            block()
        } catch (e: LocalBackendException) {
            throw RoomLoadException(roomFailure(e.outcome))
        }

    override suspend fun acceptInvite(code: InviteCode): TripRoom {
        val displayName = session.stored()?.displayName.orEmpty()
        val json =
            try {
                session.rpc("accept_invite", JSONObject().put("p_token", code.value).put("p_display_name", displayName))
            } catch (e: LocalBackendException) {
                throw InviteAcceptException(acceptFailure(e.outcome))
            } catch (e: JSONException) {
                throw InviteAcceptException(InviteAcceptFailure.Unknown)
            }
        return try {
            val members = json.getJSONArray("members")
            TripRoom(
                id = TripId(json.getString("trip_id")),
                name = json.getString("trip_name"),
                members =
                    (0 until members.length()).map { i ->
                        members.getJSONObject(i).let {
                            TripMember(it.getString("display_name"), it.getBoolean("is_host"), it.getBoolean("is_me"))
                        }
                    },
            )
        } catch (e: JSONException) {
            throw InviteAcceptException(InviteAcceptFailure.Unknown)
        }
    }

    companion object {
        /**
         * 갱신 토큰으로 세션을 이어 갈 수 없다는 Auth 오류 코드.
         * https://supabase.com/docs/guides/auth/debugging/error-codes (확인일 2026-11-21)
         */
        internal val sessionEndedCodes =
            setOf(
                "refresh_token_not_found",
                "refresh_token_already_used",
                "session_not_found",
                "session_expired",
                "user_not_found",
                "user_banned",
            )

        /** 서버 결과를 올리기 실패로 옮긴다. 서버가 정한 코드와 정확히 같을 때만 옮기고, 나머지는 Unknown이다. */
        fun uploadFailure(outcome: Outcome): ReceiptUploadFailure {
            if (outcome is Outcome.Transport) return ReceiptUploadFailure.Network
            val http = outcome as Outcome.Http
            return when {
                http.code == "trip_not_found" -> {
                    ReceiptUploadFailure.DestinationUnavailable
                }

                http.code == "trip_finalized" -> {
                    ReceiptUploadFailure.RoomFinalized
                }

                http.code == "not_authenticated" || http.code in sessionEndedCodes || http.status == 401 -> {
                    ReceiptUploadFailure.SessionExpired
                }

                http.status == 429 || http.status >= 500 -> {
                    ReceiptUploadFailure.Unavailable
                }

                else -> {
                    ReceiptUploadFailure.Unknown
                }
            }
        }

        private val uuid = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

        /** <여행방>/<올린 사람>/<요청 키>.png, 첫 칸은 이 여행방. */
        fun isArtifactPath(
            path: String,
            trip: TripId,
        ): Boolean {
            val parts = path.split("/")
            return parts.size == 3 &&
                parts[0] == trip.value.lowercase() &&
                uuid.matches(parts[0]) &&
                uuid.matches(parts[1]) &&
                parts[2].endsWith(".png") &&
                uuid.matches(parts[2].removeSuffix(".png"))
        }

        fun verified(
            bytes: ByteArray,
            artifact: ReceiptArtifactRef,
        ): MaskedReceiptImage {
            val signature = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
            val sha =
                java.security.MessageDigest
                    .getInstance("SHA-256")
                    .digest(bytes)
                    .joinToString("") { "%02x".format(it) }
            if (bytes.size < 8 || !bytes.copyOfRange(0, 8).contentEquals(signature) || sha != artifact.sha256) {
                throw ReceiptViewException(ReceiptViewFailure.Mismatch)
            }
            return MaskedReceiptImage(bytes, sha)
        }

        /** Storage는 없는 객체와 읽을 수 없는 객체를 같은 NoSuchKey로 알린다. */
        fun receiptViewFailure(outcome: Outcome): ReceiptViewFailure {
            if (outcome is Outcome.Transport) return ReceiptViewFailure.Network
            val http = outcome as Outcome.Http
            return when {
                http.code == "NoSuchKey" || http.status == 404 -> ReceiptViewFailure.Missing
                http.code == "AccessDenied" || http.status == 403 -> ReceiptViewFailure.Denied
                http.code == "InvalidJWT" || http.code in sessionEndedCodes || http.status == 401 -> ReceiptViewFailure.SessionExpired
                http.status == 429 || http.status >= 500 -> ReceiptViewFailure.Unavailable
                else -> ReceiptViewFailure.Unknown
            }
        }

        fun roomFailure(outcome: Outcome): RoomLoadFailure {
            if (outcome is Outcome.Transport) return RoomLoadFailure.Network
            val http = outcome as Outcome.Http
            return when {
                http.code == "trip_not_found" -> RoomLoadFailure.NotFound
                http.code == "not_authenticated" || http.code in sessionEndedCodes || http.status == 401 -> RoomLoadFailure.SessionExpired
                http.status == 429 || http.status >= 500 -> RoomLoadFailure.Unavailable
                else -> RoomLoadFailure.Unknown
            }
        }

        /** 서버 결과를 초대 수락 실패로 옮긴다. 서버가 정한 코드와 정확히 같을 때만 옮기고, 나머지는 Unknown이다. */
        fun acceptFailure(outcome: Outcome): InviteAcceptFailure {
            if (outcome is Outcome.Transport) return InviteAcceptFailure.Network
            val http = outcome as Outcome.Http
            return when {
                http.code == "invite_expired" -> {
                    InviteAcceptFailure.InviteExpired
                }

                http.code in setOf("invite_invalid", "invite_revoked", "invite_used") -> {
                    InviteAcceptFailure.InviteInvalid
                }

                http.code == "trip_finalized" -> {
                    InviteAcceptFailure.RoomFinalized
                }

                http.code == "not_authenticated" || http.code in sessionEndedCodes || http.status == 401 -> {
                    InviteAcceptFailure.SessionExpired
                }

                http.status == 429 || http.status >= 500 -> {
                    InviteAcceptFailure.Unavailable
                }

                else -> {
                    InviteAcceptFailure.Unknown
                }
            }
        }
    }
}

/** 로컬 debug 모드의 정산 구현체. 검토·미리보기·확정·확정본 조회 RPC를 부른다. 계산은 서버가 한다. */
class LocalSettlementGateway(
    private val session: LocalSupabaseSession,
) : SettlementGateway {
    override suspend fun review(
        review: ExpenseReview,
        trip: TripId,
    ): ReviewedExpense {
        val body =
            JSONObject()
                .put("p_expense", review.expenseId)
                .put("p_expected_version", review.expectedVersion)
                .put("p_request_id", review.requestId.toString())
        when (val d = review.decision) {
            is ExpenseReview.Decision.Include -> {
                body
                    .put("p_decision", "include")
                    .put("p_payer", d.payer.value)
                    .put("p_krw_amount", d.verifiedKrw ?: JSONObject.NULL)
                    .put("p_shares", JSONArray(d.shares.map { JSONObject().put("user_id", it.member.value).put("krw", it.krw) }))
            }

            is ExpenseReview.Decision.Hold -> {
                body.put("p_decision", "hold").put("p_hold_reason", d.reason)
            }
        }
        val raw = call("review_expense", body)
        // 응답 글자를 객체로 읽는 일도 형식 검사 안에서 한다(깨진 본문·객체가 아닌 성공 응답 → Unknown).
        return parse { JSONObject(raw).let { ReviewedExpense(it.getInt("version"), it.getLong("revision"), it.getBoolean("replayed")) } }
    }

    override suspend fun preview(trip: TripId): SettlementPreview {
        val raw = call("preview_settlement", JSONObject().put("p_trip", trip.value))
        return parse {
            val json = JSONObject(raw)
            SettlementPreview(
                revision = json.getLong("revision"),
                isFinalized = json.getString("status") == "finalized",
                ready = json.getBoolean("ready"),
                pendingCount = json.getJSONArray("pending_expense_ids").length(),
                includedTotalKrw = json.getLong("included_total_krw"),
                transfers = LocalJson.transfers(json.getJSONArray("transfers")),
                excluded = LocalJson.excluded(json.getJSONArray("excluded")) ?: throw JSONException("excluded"),
            )
        }
    }

    override suspend fun finalize(
        trip: TripId,
        reviewedRevision: Long,
        requestId: UUID,
    ): FinalizeResult {
        val raw =
            call(
                "finalize_settlement",
                JSONObject()
                    .put(
                        "p_trip",
                        trip.value,
                    ).put("p_expected_revision", reviewedRevision)
                    .put("p_request_id", requestId.toString()),
            )
        return parse { JSONObject(raw).let { FinalizeResult(it.getString("finalization_id"), it.getBoolean("replayed")) } }
    }

    override suspend fun finalized(trip: TripId): FinalSettlement? {
        val raw = call("get_finalized_settlement", JSONObject().put("p_trip", trip.value)).trim()
        if (raw == "null") return null
        return parse { LocalJson.final(JSONObject(raw)) ?: throw JSONException("final") }
    }

    private suspend fun call(
        name: String,
        body: JSONObject,
    ): String =
        try {
            session.rpcRaw(name, body)
        } catch (e: LocalBackendException) {
            throw SettlementException(failure(e.outcome))
        }

    private inline fun <T> parse(block: () -> T): T =
        try {
            block()
        } catch (e: JSONException) {
            throw SettlementException(SettlementFailure.Unknown)
        }

    companion object {
        private val rejectedCodes =
            setOf(
                "payer_required",
                "krw_unverified",
                "shares_invalid",
                "shares_mismatch",
                "hold_reason_required",
                "decision_invalid",
                "invalid_fields",
            )

        /** 서버가 정한 코드와 정확히 같을 때만 기능 실패로 옮긴다. idempotency_conflict(같은 키, 다른 내용)는 Unknown이다. */
        fun failure(outcome: Outcome): SettlementFailure {
            if (outcome is Outcome.Transport) return SettlementFailure.Network
            val http = outcome as Outcome.Http
            return when {
                http.code == "trip_not_found" -> {
                    SettlementFailure.NotFound
                }

                http.code == "host_only" -> {
                    SettlementFailure.HostOnly
                }

                http.code == "stale_expense" || http.code == "stale_revision" -> {
                    SettlementFailure.Stale
                }

                http.code == "pending_review" -> {
                    SettlementFailure.PendingReview
                }

                http.code == "trip_finalized" -> {
                    SettlementFailure.Finalized
                }

                http.code in rejectedCodes -> {
                    SettlementFailure.Rejected
                }

                http.code == "not_authenticated" || http.code in LocalTripGateway.sessionEndedCodes || http.status == 401 -> {
                    SettlementFailure.SessionExpired
                }

                http.status == 429 || http.status >= 500 -> {
                    SettlementFailure.Unavailable
                }

                else -> {
                    SettlementFailure.Unknown
                }
            }
        }
    }
}

/** 로컬 RPC 응답 모양을 앱 타입으로 옮긴다. 모르는 값이면 null(→ Unknown)이다. */
internal object LocalJson {
    private fun JSONObject.stringOrNull(name: String): String? = if (isNull(name)) null else getString(name)

    private fun JSONObject.longOrNull(name: String): Long? = if (isNull(name)) null else getLong(name)

    /** 없는 키와 null을 같게 본다(장부에만 있는 필드). */
    private fun JSONObject.optStringOrNull(name: String): String? = if (!has(name) || isNull(name)) null else getString(name)

    fun members(array: JSONArray): List<LedgerMember> =
        (0 until array.length()).map { i ->
            array.getJSONObject(i).let {
                LedgerMember(
                    MemberId(it.getString("user_id")),
                    it.getString("display_name"),
                    it.getString("role") == "host",
                )
            }
        }

    fun expense(json: JSONObject): LedgerExpense? {
        val status =
            when (json.getString("status")) {
                "pending" -> ExpenseStatus.Pending
                "included" -> ExpenseStatus.Included
                "held" -> ExpenseStatus.Held(json.stringOrNull("hold_reason") ?: return null)
                else -> return null
            }
        val entry = json.getString("entry")
        if (entry != "receipt" && entry != "manual") return null
        val shares = json.getJSONArray("shares")
        return LedgerExpense(
            id = json.getString("expense_id"),
            version = json.getInt("version"),
            isManual = entry == "manual",
            uploadedBy = MemberId(json.getString("uploaded_by")),
            date = json.getString("expense_date"),
            amountMinor = json.getLong("amount_minor"),
            currency = json.getString("currency"),
            merchant = json.stringOrNull("merchant"),
            status = status,
            payer = json.stringOrNull("payer_id")?.let(::MemberId),
            krwAmount = json.longOrNull("krw_amount"),
            krwBasis = json.stringOrNull("krw_basis")?.let { b -> KrwBasis.entries.firstOrNull { it.wire == b } },
            shares =
                (0 until shares.length()).map { i ->
                    shares.getJSONObject(i).let { ShareLine(MemberId(it.getString("user_id")), it.getLong("krw")) }
                },
            artifact =
                json.optStringOrNull("artifact_path")?.let { path ->
                    json.optStringOrNull("artifact_sha256")?.let { ReceiptArtifactRef(path, it) }
                },
        )
    }

    fun ledger(json: JSONObject): RoomLedger? {
        val raw = json.getJSONArray("expenses")
        val expenses = (0 until raw.length()).map { expense(raw.getJSONObject(it)) ?: return null }
        return RoomLedger(
            tripId = TripId(json.getString("trip_id")),
            name = json.getString("trip_name"),
            isFinalized = json.getString("status") == "finalized",
            revision = json.getLong("revision"),
            isHost = json.getString("my_role") == "host",
            me = MemberId(json.getString("me")),
            members = members(json.getJSONArray("members")),
            expenses = expenses,
        )
    }

    fun transfers(array: JSONArray): List<Transfer> =
        (0 until array.length()).map { i ->
            array.getJSONObject(i).let { Transfer(MemberId(it.getString("from")), MemberId(it.getString("to")), it.getLong("krw")) }
        }

    fun excluded(array: JSONArray): List<ExcludedExpense>? =
        (0 until array.length()).map { i ->
            val x = array.getJSONObject(i)
            val held =
                when (x.getString("kind")) {
                    "held" -> true
                    "personal" -> false
                    else -> return null
                }
            ExcludedExpense(x.getString("expense_id"), held, x.stringOrNull("reason"))
        }

    fun final(json: JSONObject): FinalSettlement? {
        val snapshot = json.getJSONObject("snapshot")
        val inputs = snapshot.getJSONObject("inputs")
        val outputs = snapshot.getJSONObject("outputs")
        val rawExpenses = inputs.getJSONArray("expenses")
        return FinalSettlement(
            id = json.getString("finalization_id"),
            version = json.getInt("version"),
            finalizedAt = json.getString("finalized_at"),
            reviewedRevision = json.getLong("reviewed_revision"),
            ruleVersion = snapshot.getString("rule_version"),
            snapshotSha256 = json.getString("snapshot_sha256"),
            members = members(inputs.getJSONArray("members")),
            expenses =
                (0 until rawExpenses.length()).map { i ->
                    rawExpenses.getJSONObject(i).let {
                        FinalSettlement.Expense(
                            id = it.getString("expense_id"),
                            merchant = it.stringOrNull("merchant"),
                            isManual = it.getString("entry") == "manual",
                            date = it.getString("expense_date"),
                            amountMinor = it.getLong("amount_minor"),
                            currency = it.getString("currency"),
                            krwAmount = it.longOrNull("krw_amount"),
                            kind = it.optString("kind"),
                        )
                    }
                },
            includedTotalKrw = outputs.getLong("included_total_krw"),
            transfers = transfers(outputs.getJSONArray("transfers")),
            excluded = excluded(outputs.getJSONArray("excluded")) ?: return null,
        )
    }
}
