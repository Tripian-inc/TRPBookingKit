import Foundation
import XCTest
@testable import TRPBookingKit

/// `BookingContract.Booking.Cancellation.quoted(by:amount:)` against a Viator cancel quote, isolated from the
/// checkout flow that produces one.
final class LocalCancellationQuotedTests: XCTestCase {

    private let storedAmount = BookingContract.Money(amount: "145.00", currency: "EUR")

    private func cancellation() -> BookingContract.Booking.Cancellation {
        BookingContract.Booking.Cancellation(allowed: true, deadline: "2026-10-14T08:30:00Z",
                                             refund: .init(.full), refundAmount: storedAmount)
    }

    func testQuoteWithNoStatusIsNotAllowed() throws {
        let quote = try decodeJSON(ViatorCancelQuote.self, #"""
        {"bookingId": "BR-1122334455",
         "refundDetails": {"itemPrice": 145, "refundAmount": 145, "refundPercentage": 100, "currencyCode": "EUR"}}
        """#)

        let quoted = cancellation().quoted(by: quote, amount: storedAmount)

        XCTAssertFalse(quoted.allowed)
    }

    func testPercentagePolicyWithNoRefundAmountLeavesRefundAmountNil() throws {
        let quote = try decodeJSON(ViatorCancelQuote.self, #"""
        {"bookingId": "BR-1122334455", "status": "CANCELLABLE",
         "refundDetails": {"refundPercentage": 50, "currencyCode": "EUR"}}
        """#)

        let quoted = cancellation().quoted(by: quote, amount: storedAmount)

        XCTAssertEqual(quoted.refund.value, .partial)
        XCTAssertNil(quoted.refundAmount)
    }

    func testNoPolicyDecidedFallsBackToTheStoredAmount() throws {
        let quote = try decodeJSON(ViatorCancelQuote.self, #"""
        {"bookingId": "BR-1122334455", "status": "CANCELLABLE"}
        """#)

        let quoted = cancellation().quoted(by: quote, amount: storedAmount)

        XCTAssertEqual(quoted.refundAmount, storedAmount)
    }
}
