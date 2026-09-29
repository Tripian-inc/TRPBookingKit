import Foundation
@testable import TRPBookingKit

final class MockViatorBookingService: ViatorBookingService, @unchecked Sendable {
    var productResult: Result<ViatorProduct, Error>?
    var scheduleResult: Result<ViatorSchedule, Error>?
    var bookingQuestionsResult: Result<[ViatorBookingQuestion], Error> = .success([])
    var locationsResult: Result<[ViatorLocation], Error> = .success([])
    var availabilityResult: Result<ViatorAvailability, Error>?
    var exchangeRatesResult: Result<[ViatorExchangeRate], Error> = .success([])
    var holdResult: Result<ViatorHold, Error>?
    var bookResult: Result<ViatorBookResult, Error>?
    var statusResult: Result<ViatorBookingStatusResult, Error>?
    var cancelQuoteResult: Result<ViatorCancelQuote, Error>?
    var cancelResult: Result<ViatorCancellation, Error>?

    var holdCallCount = 0
    var bookCallCount = 0
    var statusCallCount = 0
    var cancelCallCount = 0

    var statusHandler: (() -> Result<ViatorBookingStatusResult, Error>)?

    func product(code: String) async throws -> ViatorProduct {
        try unwrap(productResult)
    }

    func schedule(productCode: String) async throws -> ViatorSchedule {
        try unwrap(scheduleResult)
    }

    func bookingQuestions() async throws -> [ViatorBookingQuestion] {
        try bookingQuestionsResult.get()
    }

    func locations(refs: [String]) async throws -> [ViatorLocation] {
        try locationsResult.get()
    }

    func availability(productCode: String, travelDate: BookingDate, currency: String, paxMix: [ViatorPax]) async throws -> ViatorAvailability {
        try unwrap(availabilityResult)
    }

    func exchangeRates(from sources: [String], to targets: [String]) async throws -> [ViatorExchangeRate] {
        try exchangeRatesResult.get()
    }

    func hold(_ item: ViatorHoldItem, currency: String, partnerCartRef: String, partnerBookingRef: String) async throws -> ViatorHold {
        holdCallCount += 1
        return try unwrap(holdResult)
    }

    func book(cartRef: String, bookingRef: String, details: ViatorBookerDetails, paymentToken: String) async throws -> ViatorBookResult {
        bookCallCount += 1
        return try unwrap(bookResult)
    }

    func status(bookingRef: String) async throws -> ViatorBookingStatusResult {
        statusCallCount += 1
        if let statusHandler {
            return try statusHandler().get()
        }
        return try unwrap(statusResult)
    }

    func cancelQuote(bookingRef: String) async throws -> ViatorCancelQuote {
        try unwrap(cancelQuoteResult)
    }

    func cancel(bookingRef: String) async throws -> ViatorCancellation {
        cancelCallCount += 1
        return try unwrap(cancelResult)
    }

    private func unwrap<T>(_ result: Result<T, Error>?) throws -> T {
        guard let result else { throw BookingError.transport("mock result not stubbed") }
        return try result.get()
    }
}

final class MockViatorPaymentTokenProviding: ViatorPaymentTokenProviding, @unchecked Sendable {
    var result: Result<String, Error> = .success("payment-token")
    var callCount = 0
    var beforeReturning: (() -> Void)?

    func paymentToken(for hold: ViatorCheckoutHold) async throws -> String {
        callCount += 1
        beforeReturning?()
        return try result.get()
    }
}
