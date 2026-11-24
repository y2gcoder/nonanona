#if DEBUG
  import CryptoKit
  import Foundation
  import os

  /// 로컬 debug 모드의 인증 구현체. 실제 소셜 로그인이 아니라, 로컬 스택의 가상 계정으로 비밀번호 로그인한다.
  struct LocalAuthGateway: AuthGateway {
    let session: LocalSupabaseSession

    var providers: [SignInProvider] { [.apple, .google] }
    var testOnlyNotice: String? { "로컬 테스트 계정 · 실제 소셜 로그인이 아니에요" }

    func restoreSession() async -> AccountSession? {
      await session.stored().map { AccountSession(accountID: AccountID(value: $0.userID), displayName: $0.displayName) }
    }

    func signIn(with provider: SignInProvider) async throws -> AccountSession {
      do {
        let stored = try await session.signIn()
        return AccountSession(accountID: AccountID(value: stored.userID), displayName: stored.displayName)
      } catch let failure as LocalSupabaseSession.Failure {
        throw Self.signInFailure(failure.outcome)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw SignInFailure.unknown
      }
    }

    func endSession() async {
      await session.clear()
    }

    /// Auth 응답을 로그인 실패로 옮긴다. 정해 둔 코드가 아니면 `.unknown`이다.
    static func signInFailure(_ outcome: LocalSupabaseSession.Outcome) -> SignInFailure {
      switch outcome {
      case .transport: .network
      case .http(429, _), .http(_, "over_request_rate_limit"): .unavailable
      case .http(let status, _) where status >= 500: .unavailable
      case .http: .unknown
      }
    }
  }

  /// 로컬 debug 모드의 여행방 구현체. 실제 Auth 세션으로 `accept_invite` RPC를 부른다.
  struct LocalTripGateway: TripGateway {
    let session: LocalSupabaseSession
    /// 검증용: 첫 올리기에서 사본은 올리고 지출 행을 만들기 전에 끊긴 것처럼 실패한다(debug 실행 환경 변수).
    var failOnceAfterStorage: FailOnce?

    final class FailOnce: Sendable {
      private let armed = OSAllocatedUnfairLock(initialState: true)
      func consume() -> Bool {
        armed.withLock {
          let was = $0; $0 = false; return was
        }
      }
    }

    func acceptInvite(_ code: InviteCode) async throws -> TripRoom {
      let displayName = await session.stored()?.displayName ?? ""
      let data: Data
      do {
        data = try await session.rpc("accept_invite", body: ["p_token": code.value, "p_display_name": displayName])
      } catch let failure as LocalSupabaseSession.Failure {
        throw Self.acceptFailure(failure.outcome)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw InviteAcceptFailure.unknown
      }
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      guard let room = try? decoder.decode(AcceptedRoom.self, from: data) else { throw InviteAcceptFailure.unknown }
      return TripRoom(
        id: TripID(value: room.tripId), name: room.tripName,
        members: room.members.map { TripMember(displayName: $0.displayName, isHost: $0.isHost, isMe: $0.isMe) })
    }

    /// 1) 사본을 비공개 버킷의 <trip>/<나>/<request_id>.png 로 올리고 2) RPC로 지출 행을 만든다.
    /// 두 단계는 한 트랜잭션이 아니다. 1만 되고 끊기면 행 없는 객체가 남고(지출로 보이지 않음),
    /// 같은 요청 키로 다시 시도하면 1은 "이미 있음"으로 넘어가고 2가 행을 만든다.
    func submitReceipt(_ upload: ReceiptExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
      guard let userID = await session.stored()?.userID else { throw ReceiptUploadFailure.sessionExpired }
      let objectPath =
        "storage/v1/object/receipts/\(trip.value)/\(userID)/\(upload.requestID.uuidString.lowercased()).png"
      do {
        _ = try await session.authorized(objectPath, body: upload.artifactPNG, contentType: "image/png")
      } catch let failure as LocalSupabaseSession.Failure {
        switch failure.outcome {
        case .http(_, "KeyAlreadyExists"): break  // 앞선 시도가 이미 올렸다
        case .http(_, "AccessDenied"):
          throw await session.isSessionValid() ? ReceiptUploadFailure.destinationUnavailable : .sessionExpired
        default: throw Self.uploadFailure(failure.outcome)
        }
      }
      if failOnceAfterStorage?.consume() == true { throw ReceiptUploadFailure.network }
      let data: Data
      do {
        data = try await session.rpc(
          "submit_receipt_expense",
          body: [
            "p_trip": trip.value, "p_request_id": upload.requestID.uuidString.lowercased(),
            "p_expense_date": upload.date, "p_amount_minor": String(upload.amountMinor), "p_currency": upload.currency,
            "p_merchant": upload.merchant, "p_artifact_sha256": upload.artifactSHA256,
          ])
      } catch let failure as LocalSupabaseSession.Failure {
        throw Self.uploadFailure(failure.outcome)
      }
      guard let submitted = try? LocalJSON.decoder.decode(LocalJSON.Submitted.self, from: data) else {
        throw ReceiptUploadFailure.unknown
      }
      return SubmittedExpense(expenseID: submitted.expenseId, replayed: submitted.replayed)
    }

    /// 증빙 없는 직접 입력: 사본 없이 허용 필드만 RPC로 보낸다. 같은 요청 키는 같은 지출로 수렴한다.
    func submitManualExpense(_ upload: ManualExpenseUpload, to trip: TripID) async throws -> SubmittedExpense {
      let data: Data
      do {
        data = try await session.rpc(
          "submit_manual_expense",
          body: [
            "p_trip": trip.value, "p_request_id": upload.requestID.uuidString.lowercased(),
            "p_expense_date": upload.date, "p_amount_minor": String(upload.amountMinor), "p_currency": upload.currency,
            "p_merchant": upload.merchant,
          ])
      } catch let failure as LocalSupabaseSession.Failure {
        throw Self.uploadFailure(failure.outcome)
      }
      guard let submitted = try? LocalJSON.decoder.decode(LocalJSON.Submitted.self, from: data) else {
        throw ReceiptUploadFailure.unknown
      }
      return SubmittedExpense(expenseID: submitted.expenseId, replayed: submitted.replayed)
    }

    func myTrips() async throws -> [TripSummary] {
      let data = try await roomCall { try await session.rpc("list_my_trips", body: [:]) }
      guard let rows = try? LocalJSON.decoder.decode([LocalJSON.TripRow].self, from: data) else {
        throw RoomLoadFailure.unknown
      }
      return rows.map {
        TripSummary(
          id: TripID(value: $0.tripId), name: $0.tripName, isHost: $0.myRole == "host",
          isFinalized: $0.status == "finalized")
      }
    }

    func ledger(_ trip: TripID) async throws -> RoomLedger {
      let data = try await roomCall { try await session.rpc("get_room_ledger", body: ["p_trip": trip.value]) }
      guard let raw = try? LocalJSON.decoder.decode(LocalJSON.Ledger.self, from: data), let ledger = raw.ledger else {
        throw RoomLoadFailure.unknown
      }
      return ledger
    }

    /// 비공개 버킷 receipts의 인증 다운로드(`/storage/v1/object/authenticated/…`). 공개·서명 URL은 쓰지 않는다.
    /// 보내기 전에 경로가 이 여행방의 사본 경로인지, 받은 뒤 PNG이고 장부의 해시와 같은지 확인한다.
    func maskedReceipt(_ artifact: ReceiptArtifactRef, in trip: TripID) async throws -> MaskedReceiptImage {
      guard Self.isArtifactPath(artifact.path, in: trip),
        artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
      else { throw ReceiptViewFailure.mismatch }
      let data: Data
      do {
        data = try await session.storageGet("storage/v1/object/authenticated/receipts/\(artifact.path)")
      } catch let failure as LocalSupabaseSession.Failure {
        throw Self.receiptViewFailure(failure.outcome)
      }
      return try Self.verified(data, artifact)
    }

    /// `<여행방>/<올린 사람>/<요청 키>.png`, 첫 칸은 이 여행방.
    static func isArtifactPath(_ path: String, in trip: TripID) -> Bool {
      let parts = path.split(separator: "/", omittingEmptySubsequences: false)
      let uuid = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
      return parts.count == 3 && parts[0] == trip.value.lowercased()
        && String(parts[0]).range(of: uuid, options: .regularExpression) != nil
        && String(parts[1]).range(of: uuid, options: .regularExpression) != nil
        && parts[2].hasSuffix(".png")
        && String(parts[2].dropLast(4)).range(of: uuid, options: .regularExpression) != nil
    }

    static func verified(_ data: Data, _ artifact: ReceiptArtifactRef) throws -> MaskedReceiptImage {
      let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      guard data.prefix(8) == signature, sha == artifact.sha256 else { throw ReceiptViewFailure.mismatch }
      return MaskedReceiptImage(png: data, sha256: sha)
    }

    /// Storage는 없는 객체와 읽을 수 없는 객체를 같은 NoSuchKey로 알린다.
    static func receiptViewFailure(_ outcome: LocalSupabaseSession.Outcome) -> ReceiptViewFailure {
      switch outcome {
      case .transport: return .network
      case .http(_, "NoSuchKey"), .http(404, _): return .missing
      // 세션 경계가 Auth로 토큰을 확인한 뒤에만 AccessDenied를 넘긴다(진짜 거절).
      case .http(_, "AccessDenied"), .http(403, _): return .denied
      case .http(_, "InvalidJWT"), .http(401, _): return .sessionExpired
      case .http(_, let code?) where sessionEndedCodes.contains(code): return .sessionExpired
      case .http(429, _): return .unavailable
      case .http(let status, _) where status >= 500: return .unavailable
      case .http: return .unknown
      }
    }

    private func roomCall(_ call: () async throws -> Data) async throws -> Data {
      do {
        return try await call()
      } catch let failure as LocalSupabaseSession.Failure {
        throw Self.roomFailure(failure.outcome)
      }
    }

    static func roomFailure(_ outcome: LocalSupabaseSession.Outcome) -> RoomLoadFailure {
      switch outcome {
      case .transport: return .network
      case .http(_, "trip_not_found"): return .notFound
      case .http(_, "not_authenticated"): return .sessionExpired
      case .http(_, let code?) where sessionEndedCodes.contains(code): return .sessionExpired
      case .http(401, _): return .sessionExpired
      case .http(429, _): return .unavailable
      case .http(let status, _) where status >= 500: return .unavailable
      case .http: return .unknown
      }
    }

    /// 서버 결과를 올리기 실패로 옮긴다. 서버가 정한 코드와 정확히 같을 때만 옮기고, 나머지는 `.unknown`이다.
    static func uploadFailure(_ outcome: LocalSupabaseSession.Outcome) -> ReceiptUploadFailure {
      switch outcome {
      case .transport: return .network
      case .http(_, "trip_not_found"): return .destinationUnavailable
      case .http(_, "trip_finalized"): return .roomFinalized
      case .http(_, "not_authenticated"): return .sessionExpired
      case .http(_, let code?) where sessionEndedCodes.contains(code): return .sessionExpired
      case .http(401, _): return .sessionExpired
      case .http(429, _): return .unavailable
      case .http(let status, _) where status >= 500: return .unavailable
      case .http: return .unknown
      }
    }

    /// 서버 결과를 초대 수락 실패로 옮긴다. 서버가 정한 코드와 정확히 같을 때만 옮기고, 나머지는 `.unknown`이다.
    static func acceptFailure(_ outcome: LocalSupabaseSession.Outcome) -> InviteAcceptFailure {
      switch outcome {
      case .transport: return .network
      case .http(_, "invite_expired"): return .inviteExpired
      case .http(_, "invite_invalid"), .http(_, "invite_revoked"), .http(_, "invite_used"): return .inviteInvalid
      case .http(_, "trip_finalized"): return .roomFinalized
      case .http(_, "not_authenticated"): return .sessionExpired
      case .http(_, let code?) where sessionEndedCodes.contains(code): return .sessionExpired
      case .http(401, _): return .sessionExpired
      case .http(429, _): return .unavailable
      case .http(let status, _) where status >= 500: return .unavailable
      case .http: return .unknown
      }
    }

    /// 갱신 토큰으로 세션을 이어 갈 수 없다는 Auth 오류 코드.
    /// https://supabase.com/docs/guides/auth/debugging/error-codes (확인일 2026-11-21)
    static let sessionEndedCodes: Set<String> = [
      "refresh_token_not_found", "refresh_token_already_used", "session_not_found", "session_expired",
      "user_not_found", "user_banned",
    ]

    private struct AcceptedRoom: Decodable {
      struct Member: Decodable {
        let displayName: String
        let isHost: Bool
        let isMe: Bool
      }
      let tripId: String
      let tripName: String
      let members: [Member]
    }
  }

  /// 로컬 debug 모드의 정산 구현체. 검토·미리보기·확정·확정본 조회 RPC를 부른다. 계산은 서버가 한다.
  struct LocalSettlementGateway: SettlementGateway {
    let session: LocalSupabaseSession

    func review(_ review: ExpenseReview, in trip: TripID) async throws -> ReviewedExpense {
      var body: [String: Any] = [
        "p_expense": review.expenseID, "p_expected_version": review.expectedVersion,
        "p_request_id": review.requestID.uuidString.lowercased(),
      ]
      switch review.decision {
      case .include(let payer, let verifiedKRW, let shares, let conversion):
        body["p_decision"] = "include"
        body["p_payer"] = payer.value
        body["p_krw_amount"] = verifiedKRW.map { $0 as Any } ?? NSNull()
        body["p_shares"] = shares.map { ["user_id": $0.member.value, "krw": $0.krw] as [String: Any] }
        // 실제 청구액은 예전 요청 모양 그대로 보낸다(서버의 요청 지문도 같다). 다른 기준만 근거를 더한다.
        switch conversion {
        case nil: break
        case .acquisitionCost(let a):
          body["p_krw_basis"] = KRWBasis.acquisitionCost.rawValue
          body["p_acq_krw"] = a.krwPaid
          body["p_acq_foreign_minor"] = a.foreignMinor
        case .referenceEstimate(let quoteID):
          body["p_krw_basis"] = KRWBasis.referenceEstimate.rawValue
          body["p_fx_quote_id"] = quoteID
        }
      case .hold(let reason):
        body["p_decision"] = "hold"
        body["p_hold_reason"] = reason
      }
      let data = try await call("review_expense", body)
      guard let r = try? LocalJSON.decoder.decode(LocalJSON.Reviewed.self, from: data) else {
        throw SettlementFailure.unknown
      }
      return ReviewedExpense(version: r.version, revision: r.revision, replayed: r.replayed)
    }

    func preview(_ trip: TripID) async throws -> SettlementPreview {
      let data = try await call("preview_settlement", ["p_trip": trip.value])
      guard let p = try? LocalJSON.decoder.decode(LocalJSON.Preview.self, from: data) else {
        throw SettlementFailure.unknown
      }
      return SettlementPreview(
        revision: p.revision, isFinalized: p.status == "finalized", ready: p.ready,
        pendingCount: p.pendingExpenseIds.count,
        includedTotalKRW: p.includedTotalKrw, transfers: p.transfers.map(\.value),
        excluded: p.excluded.compactMap(\.value), estimatedTotalKRW: p.estimatedTotalKrw ?? 0)
    }

    func finalize(_ trip: TripID, reviewedRevision: Int, requestID: UUID) async throws -> FinalizeResult {
      let data = try await call(
        "finalize_settlement",
        [
          "p_trip": trip.value, "p_expected_revision": reviewedRevision,
          "p_request_id": requestID.uuidString.lowercased(),
        ])
      guard let r = try? LocalJSON.decoder.decode(LocalJSON.Finalized.self, from: data) else {
        throw SettlementFailure.unknown
      }
      return FinalizeResult(finalizationID: r.finalizationId, replayed: r.replayed)
    }

    func finalized(_ trip: TripID) async throws -> FinalSettlement? {
      let data = try await call("get_finalized_settlement", ["p_trip": trip.value])
      if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "null" { return nil }
      guard let f = try? LocalJSON.decoder.decode(LocalJSON.Final.self, from: data), let value = f.value else {
        throw SettlementFailure.unknown
      }
      return value
    }

    private func call(_ name: String, _ body: [String: Any]) async throws -> Data {
      let json: Data
      do {
        json = try JSONSerialization.data(withJSONObject: body)
      } catch {
        throw SettlementFailure.unknown
      }
      do {
        return try await session.rpc(name, json: json)
      } catch let failure as LocalSupabaseSession.Failure {
        throw Self.failure(failure.outcome)
      }
    }

    /// 서버가 정한 코드와 정확히 같을 때만 기능 실패로 옮긴다. 같은 요청 키의 다른 내용(idempotency_conflict)은 `.unknown`이다.
    static func failure(_ outcome: LocalSupabaseSession.Outcome) -> SettlementFailure {
      switch outcome {
      case .transport: return .network
      case .http(_, "trip_not_found"): return .notFound
      case .http(_, "host_only"): return .hostOnly
      case .http(_, "stale_expense"), .http(_, "stale_revision"): return .stale
      case .http(_, "pending_review"): return .pendingReview
      case .http(_, "trip_finalized"): return .finalized
      case .http(_, "stale_quote"): return .quoteChanged
      case .http(_, let code?) where rejectedCodes.contains(code): return .rejected
      case .http(_, "not_authenticated"): return .sessionExpired
      case .http(_, let code?) where LocalTripGateway.sessionEndedCodes.contains(code): return .sessionExpired
      case .http(401, _): return .sessionExpired
      case .http(429, _): return .unavailable
      case .http(let status, _) where status >= 500: return .unavailable
      case .http: return .unknown
      }
    }

    static let rejectedCodes: Set<String> = [
      "payer_required", "krw_unverified", "shares_invalid", "shares_mismatch", "hold_reason_required",
      "decision_invalid", "invalid_fields", "krw_mismatch", "basis_invalid",
    ]
  }

  /// 로컬 RPC 응답 모양. 앱 타입으로 옮길 때 값을 하나씩 검사하고, 모르는 값이면 nil(→ `.unknown`)이다.
  enum LocalJSON {
    static var decoder: JSONDecoder {
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      return decoder
    }

    struct Submitted: Decodable {
      let expenseId: String
      let replayed: Bool
    }

    struct TripRow: Decodable {
      let tripId: String
      let tripName: String
      let status: String
      let myRole: String
    }

    struct Member: Decodable {
      let userId: String
      let displayName: String
      let role: String
      var value: LedgerMember {
        LedgerMember(id: MemberID(value: userId), displayName: displayName, isHost: role == "host")
      }
    }

    struct Share: Decodable {
      let userId: String
      let krw: Int
    }

    /// 고정했거나 제안한 기준환율 고시값. 출처·항목·단위·형식이 하나라도 다르면 nil(→ 장부 전체 `.unknown`).
    struct Quote: Decodable {
      let quoteId: String
      let source: String
      let statCode: String
      let itemCode: String
      let itemName: String
      let currency: String
      let quoteUnit: Int
      let rate: String
      let rateDate: String
      let dataOrigin: String

      var value: ReferenceQuote? {
        guard source == "bok_ecos", statCode == "731Y001", itemCode == "0000002", currency == "JPY", quoteUnit == 100,
          dataOrigin == "ecos_live" || dataOrigin == "fixture", SharePlan.scaledRate(rate) != nil
        else { return nil }
        return ReferenceQuote(
          quoteID: quoteId, rate: rate, quoteUnit: quoteUnit, rateDate: rateDate, itemName: itemName,
          isSynthetic: dataOrigin == "fixture")
      }
    }

    struct Proposal: Decodable {
      let status: String
      let quoteId: String?
      let source: String?
      let statCode: String?
      let itemCode: String?
      let itemName: String?
      let currency: String?
      let quoteUnit: Int?
      let rate: String?
      let rateDate: String?
      let dataOrigin: String?
      let krw: Int?

      var value: FXProposal? {
        switch status {
        case "undetermined": return .undetermined
        case "unavailable": return .unavailable
        case "proposed":
          guard let quoteId, let source, let statCode, let itemCode, let itemName, let currency, let quoteUnit,
            let rate,
            let rateDate, let dataOrigin, let krw,
            let quote = Quote(
              quoteId: quoteId, source: source, statCode: statCode, itemCode: itemCode, itemName: itemName,
              currency: currency, quoteUnit: quoteUnit, rate: rate, rateDate: rateDate, dataOrigin: dataOrigin
            ).value
          else { return nil }
          return .proposed(quote, krw: krw)
        default: return nil
        }
      }
    }

    struct Acquisition: Decodable {
      let krwPaid: Int
      let foreignMinor: Int
    }

    struct Expense: Decodable {
      let expenseId: String
      let version: Int
      let entry: String
      let uploadedBy: String
      let expenseDate: String
      let amountMinor: Int
      let currency: String
      let merchant: String?
      let status: String
      let payerId: String?
      let krwAmount: Int?
      let krwBasis: String?
      let holdReason: String?
      let shares: [Share]
      let kind: String?
      let artifactPath: String?
      let artifactSha256: String?
      /// v1 확정본에는 없다(그때는 예상액이 없었다).
      let isEstimate: Bool?
      let fx: Quote?
      let acquisition: Acquisition?
      let fxProposal: Proposal?
      let fxSuperseded: Bool?

      /// 원화 기준과 그 근거가 서로 맞을 때만 값. 모르는 기준, 근거 없는 예상액·취득 원가, 예상 표시가 기준과 다른 값은
      /// nil이다(예상액을 실제 청구액처럼 그리지 않는다).
      var basis: (KRWBasis?, ReferenceQuote?, AcquisitionBasis?)? {
        guard let krwBasis else { return isEstimate == true || fx != nil || acquisition != nil ? nil : (nil, nil, nil) }
        guard let parsed = KRWBasis(rawValue: krwBasis) else { return nil }
        if let isEstimate, isEstimate != (parsed == .referenceEstimate) { return nil }
        switch parsed {
        case .referenceEstimate:
          guard isEstimate == true, acquisition == nil, let quote = fx?.value, currency == "JPY",
            rateDateIsNotAfterExpense(quote.rateDate)
          else { return nil }
          return (parsed, quote, nil)
        case .acquisitionCost:
          guard fx == nil, let a = acquisition, a.krwPaid > 0, a.foreignMinor > 0, currency == "JPY" else { return nil }
          return (parsed, nil, AcquisitionBasis(krwPaid: a.krwPaid, foreignMinor: a.foreignMinor))
        case .krwOriginal, .verifiedCharge:
          guard fx == nil, acquisition == nil else { return nil }
          return (parsed, nil, nil)
        }
      }

      private func rateDateIsNotAfterExpense(_ rateDate: String) -> Bool {
        let iso = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
        return rateDate.range(of: iso, options: .regularExpression) != nil
          && expenseDate.range(of: iso, options: .regularExpression) != nil && rateDate <= expenseDate
      }

      var value: LedgerExpense? {
        let state: ExpenseStatus
        switch status {
        case "pending": state = .pending
        case "included": state = .included
        case "held":
          guard let holdReason else { return nil }
          state = .held(reason: holdReason)
        default: return nil
        }
        guard entry == "receipt" || entry == "manual", let basis else { return nil }
        let proposal: FXProposal?
        if let fxProposal {
          guard let parsed = fxProposal.value else { return nil }
          proposal = parsed
        } else {
          proposal = nil
        }
        return LedgerExpense(
          id: expenseId, version: version, isManual: entry == "manual", uploadedBy: MemberID(value: uploadedBy),
          date: expenseDate, amountMinor: amountMinor, currency: currency, merchant: merchant, status: state,
          payer: payerId.map(MemberID.init), krwAmount: krwAmount, krwBasis: basis.0,
          shares: shares.map { ShareLine(member: MemberID(value: $0.userId), krw: $0.krw) },
          artifact: artifactPath.flatMap { path in artifactSha256.map { ReceiptArtifactRef(path: path, sha256: $0) } },
          fx: basis.1, acquisition: basis.2, fxProposal: proposal, fxSuperseded: fxSuperseded ?? false)
      }
    }

    struct Ledger: Decodable {
      let tripId: String
      let tripName: String
      let status: String
      let revision: Int
      let myRole: String
      let me: String
      let members: [Member]
      let expenses: [Expense]

      var ledger: RoomLedger? {
        let mapped = expenses.compactMap(\.value)
        guard mapped.count == expenses.count else { return nil }
        return RoomLedger(
          tripID: TripID(value: tripId), name: tripName, isFinalized: status == "finalized", revision: revision,
          isHost: myRole == "host", me: MemberID(value: me), members: members.map(\.value), expenses: mapped)
      }
    }

    struct Reviewed: Decodable {
      let version: Int
      let revision: Int
      let replayed: Bool
    }

    struct TransferRow: Decodable {
      let from: String
      let to: String
      let krw: Int
      var value: Transfer { Transfer(from: MemberID(value: from), to: MemberID(value: to), krw: krw) }
    }

    struct ExcludedRow: Decodable {
      let expenseId: String
      let kind: String
      let reason: String?
      var value: ExcludedExpense? {
        ExcludedExpense.Kind(rawValue: kind).map { ExcludedExpense(expenseID: expenseId, kind: $0, reason: reason) }
      }
    }

    struct Preview: Decodable {
      let revision: Int
      let status: String
      let ready: Bool
      let pendingExpenseIds: [String]
      let includedTotalKrw: Int
      let transfers: [TransferRow]
      let excluded: [ExcludedRow]
      let estimatedTotalKrw: Int?
    }

    struct Finalized: Decodable {
      let finalizationId: String
      let replayed: Bool
    }

    struct Final: Decodable {
      struct Snapshot: Decodable {
        struct Inputs: Decodable {
          let members: [Member]
          let expenses: [Expense]
        }
        struct Outputs: Decodable {
          let includedTotalKrw: Int
          let transfers: [TransferRow]
          let excluded: [ExcludedRow]
          let estimatedTotalKrw: Int?
        }
        let ruleVersion: String
        let inputs: Inputs
        let outputs: Outputs
      }
      let finalizationId: String
      let version: Int
      let finalizedAt: String
      let reviewedRevision: Int
      let snapshotSha256: String
      let snapshot: Snapshot

      /// 아는 규칙 판만 그린다. v1(예상액 없음)은 그대로, v2는 지출마다 원화 기준과 근거, 예상액 합계가 있어야 한다.
      static let knownRules: Set<String> = ["explicit-krw-shares-v1", "explicit-krw-shares-v2"]

      var value: FinalSettlement? {
        let excluded = snapshot.outputs.excluded.compactMap(\.value)
        guard excluded.count == snapshot.outputs.excluded.count, Self.knownRules.contains(snapshot.ruleVersion) else {
          return nil
        }
        let v2 = snapshot.ruleVersion == "explicit-krw-shares-v2"
        if v2, snapshot.outputs.estimatedTotalKrw == nil { return nil }
        var expenses: [FinalSettlement.Expense] = []
        for e in snapshot.inputs.expenses {
          guard let basis = e.basis, !v2 || e.isEstimate != nil else { return nil }
          if !v2, basis.0 == .referenceEstimate || basis.0 == .acquisitionCost { return nil }
          expenses.append(
            FinalSettlement.Expense(
              id: e.expenseId, merchant: e.merchant, isManual: e.entry == "manual", date: e.expenseDate,
              amountMinor: e.amountMinor, currency: e.currency, krwAmount: e.krwAmount, kind: e.kind ?? "",
              krwBasis: basis.0, fx: basis.1, acquisition: basis.2))
        }
        return FinalSettlement(
          id: finalizationId, version: version, finalizedAt: finalizedAt, reviewedRevision: reviewedRevision,
          ruleVersion: snapshot.ruleVersion, snapshotSHA256: snapshotSha256,
          members: snapshot.inputs.members.map(\.value), expenses: expenses,
          includedTotalKRW: snapshot.outputs.includedTotalKrw, transfers: snapshot.outputs.transfers.map(\.value),
          excluded: excluded, estimatedTotalKRW: snapshot.outputs.estimatedTotalKrw ?? 0)
      }
    }
  }
#endif
