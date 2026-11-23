package app.nonanona

import app.nonanona.feature.settlement.RoomLedger
import app.nonanona.feature.trip.ManualExpenseUpload
import app.nonanona.feature.trip.ReceiptUploadException
import app.nonanona.feature.trip.ReceiptUploadFailure
import app.nonanona.feature.trip.RoomLoadException
import app.nonanona.feature.trip.RoomLoadFailure
import app.nonanona.feature.trip.SubmittedExpense
import app.nonanona.feature.trip.TripGateway
import app.nonanona.feature.trip.TripId
import app.nonanona.feature.trip.TripSummary

/** 테스트 대역의 바탕. 초대·올리기 시험은 장부·직접 입력을 쓰지 않는다. */
abstract class TripGatewayStub : TripGateway {
    override suspend fun submitManualExpense(
        upload: ManualExpenseUpload,
        trip: TripId,
    ): SubmittedExpense = throw ReceiptUploadException(ReceiptUploadFailure.Unavailable)

    override suspend fun myTrips(): List<TripSummary> = emptyList()

    override suspend fun ledger(trip: TripId): RoomLedger = throw RoomLoadException(RoomLoadFailure.Unavailable)

    override suspend fun maskedReceipt(
        artifact: app.nonanona.feature.settlement.ReceiptArtifactRef,
        trip: TripId,
    ): app.nonanona.feature.settlement.MaskedReceiptImage =
        throw app.nonanona.feature.settlement
            .ReceiptViewException(app.nonanona.feature.settlement.ReceiptViewFailure.Unavailable)
}
