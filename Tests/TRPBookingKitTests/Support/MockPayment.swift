import Foundation
@testable import TRPBookingKit

final class MockPaymentNonceProviding: PaymentNonceProviding, @unchecked Sendable {
    var result: Result<String, Error> = .success("nonce-token")
    var nonceCallCount = 0
    var lastAmount: Decimal?
    var lastCurrency: String?

    func nonce(amount: Decimal, currency: String) async throws -> String {
        nonceCallCount += 1
        lastAmount = amount
        lastCurrency = currency
        return try result.get()
    }
}

final class MockPaymentProcessing: PaymentProcessing, @unchecked Sendable {
    var chargeResult: Result<PaymentReceipt, Error>?
    var refundResult: Result<Void, Error> = .success(())
    var chargeCallCount = 0
    var refundCallCount = 0
    var lastChargeRequest: PaymentRequest?
    var lastRefundReceipt: PaymentReceipt?
    var lastRefundReason: String?

    func charge(_ request: PaymentRequest) async throws -> PaymentReceipt {
        chargeCallCount += 1
        lastChargeRequest = request
        guard let chargeResult else { throw BookingError.transport("MockPaymentProcessing.chargeResult not stubbed") }
        return try chargeResult.get()
    }

    func refund(_ receipt: PaymentReceipt, reason: String) async throws {
        refundCallCount += 1
        lastRefundReceipt = receipt
        lastRefundReason = reason
        try refundResult.get()
    }
}
