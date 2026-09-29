import Foundation
@testable import TRPBookingKit

final class MockToristyBookingService: ToristyBookingService, @unchecked Sendable {
    var bookingInformationResult: Result<ToristyBookingInformation, Error>?
    var availabilityResult: Result<ToristyAvailability, Error>?
    var validateResult: Result<ToristyValidation, Error>?
    var confirmResult: Result<Void, Error> = .success(())
    var bookingDataResult: Result<ToristyBookingData, Error>?
    var cancelResult: Result<ToristyCancellation, Error>?

    var bookingInformationCallCount = 0
    var availabilityCallCount = 0
    var validateCallCount = 0
    var confirmCallCount = 0
    var bookingDataCallCount = 0
    var cancelCallCount = 0

    var confirmHandler: (() -> Result<Void, Error>)?
    var bookingDataHandler: (() -> Result<ToristyBookingData, Error>)?

    func bookingInformation(serviceId: Int, currency: String?) async throws -> ToristyBookingInformation {
        bookingInformationCallCount += 1
        return try unwrap(bookingInformationResult)
    }

    func availability(serviceId: Int, from start: BookingDate, through end: BookingDate) async throws -> ToristyAvailability {
        availabilityCallCount += 1
        return try unwrap(availabilityResult)
    }

    func validate(_ request: ToristyValidationRequest) async throws -> ToristyValidation {
        validateCallCount += 1
        return try unwrap(validateResult)
    }

    func confirm(_ reference: BookingReference, receipt: PaymentReceipt, amount: Decimal, currency: String) async throws {
        confirmCallCount += 1
        if let confirmHandler {
            try confirmHandler().get()
            return
        }
        try confirmResult.get()
    }

    func bookingData(cartId: String) async throws -> ToristyBookingData {
        bookingDataCallCount += 1
        if let bookingDataHandler {
            return try bookingDataHandler().get()
        }
        return try unwrap(bookingDataResult)
    }

    func cancel(_ reference: BookingReference, note: String?, notify: Bool) async throws -> ToristyCancellation {
        cancelCallCount += 1
        return try unwrap(cancelResult)
    }

    private func unwrap<T>(_ result: Result<T, Error>?) throws -> T {
        guard let result else { throw BookingError.transport("mock result not stubbed") }
        return try result.get()
    }
}
