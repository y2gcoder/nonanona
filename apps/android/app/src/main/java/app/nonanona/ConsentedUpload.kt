package app.nonanona

import app.nonanona.feature.receiptimport.OutboundReceipt
import app.nonanona.feature.trip.ReceiptExpenseUpload
import app.nonanona.feature.trip.ReceiptUploadException
import app.nonanona.feature.trip.ReceiptUploadFailure
import app.nonanona.feature.trip.TripGateway
import app.nonanona.feature.trip.TripRoom

/**
 * 사용자가 최종 확인에서 동의한 영수증만 올린다. 여행방이 동의한 곳과 다르거나, 지금 경계를 지난 영수증이 동의한
 * 스냅샷(사진 ID·사본 해시·값)과 하나라도 다르면 게이트웨이를 한 번도 부르지 않는다. 한 장이라도 실패하면 거기서 멈춘다.
 */
class ConsentedUpload(
    private val trips: TripGateway,
) {
    suspend fun send(
        confirmation: UploadConfirmation,
        room: TripRoom,
        outbound: List<OutboundReceipt>,
    ): UploadState {
        if (room.id != confirmation.tripId) return UploadState.ContentChanged
        val approved = confirmation.approved(outbound) ?: return UploadState.ContentChanged
        var created = 0
        var replayed = 0
        for (item in approved) {
            val fields = item.receipt.fields
            val upload =
                ReceiptExpenseUpload(
                    requestId = ReceiptExpenseUpload.requestId(room.id, item.artifactSha256),
                    date = fields.date,
                    amountMinor = fields.amountMinor,
                    currency = fields.currency,
                    merchant = fields.merchant,
                    artifactPng = item.artifactPng,
                    artifactSha256 = item.artifactSha256,
                )
            try {
                val result = trips.submitReceipt(upload, room.id)
                if (result.replayed) replayed++ else created++
            } catch (e: ReceiptUploadException) {
                return UploadState.Failed(e.failure, created + replayed)
            }
        }
        return UploadState.Done(created, replayed)
    }

    companion object {
        /** 세션만 지워야 하는 실패(다시 로그인한 뒤 같은 요청 키로 다시 올린다). */
        fun endsSession(state: UploadState) = state is UploadState.Failed && state.failure == ReceiptUploadFailure.SessionExpired
    }
}
