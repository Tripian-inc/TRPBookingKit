import XCTest
@testable import TRPBookingKit

final class ToristyCheckoutTests: XCTestCase {

    private let referenceDate = ISO8601.date(from: "2026-03-01T00:00:00Z")!

    private func makeStartTime(id: Int = 1, availableCount: Int = 10, isUnlimited: Bool = false, minParticipants: Int = 0) -> ToristyStartTime {
        ToristyStartTime(time: "09:00:00", id: id, availableCount: availableCount, isUnlimited: isUnlimited, minParticipants: minParticipants)
    }

    private func makeRate(id: String = "R1") -> ToristyRate {
        ToristyRate(id: id, name: "Standard", prices: [ToristyPricingCategory(id: "ADULT", name: "Adult", price: 50)])
    }

    private func makeInformation(rates: [ToristyRate]? = nil) -> ToristyBookingInformation {
        ToristyBookingInformation(serviceId: 1, currency: "USD", startingPrice: 50, lowestPrice: 50,
                                   fields: ToristyBookingFields(), rates: rates ?? [makeRate()],
                                   cancellationPolicy: nil, cancellationRules: [], pickupPoints: [], dropoffPoints: [])
    }

    private func makeSelection(rateId: String = "R1", startTime: ToristyStartTime? = nil, currency: String = "usd") -> ToristySelection {
        ToristySelection(serviceId: 1, rateId: rateId, date: BookingDate(year: 2026, month: 6, day: 1)!,
                         startTime: startTime ?? makeStartTime(), mainContact: [],
                         passengers: [ToristyPassenger(pricingCategoryId: "ADULT")], currency: currency)
    }

    private func makeValidation(cartId: String = "cart1", code: String = "conf1", total: Decimal = 50, currency: String = "USD") -> ToristyValidation {
        ToristyValidation(cartId: cartId, confirmationCode: code, totalPrice: total, currency: currency)
    }

    private func makeReference(cartId: String = "cart1", code: String = "conf1") -> BookingReference {
        BookingReference(provider: .toristy, primary: cartId, secondary: code)
    }

    private func makeBookingData(cartId: String = "cart1", status: String = "reserved", expiresAt: Date? = nil) -> ToristyBookingData {
        ToristyBookingData(cartId: cartId, confirmationCode: "conf1", currency: "USD", totalPrice: 50,
                            createdAt: referenceDate, expiresAt: expiresAt, status: ToristyPaymentStatus(status))
    }

    private func makeHold(reference: BookingReference? = nil, total: Decimal = 50, currency: String = "USD",
                           deadline: BookingDeadline? = nil) -> ToristyHold {
        ToristyHold(reference: reference ?? makeReference(), total: total, currency: currency,
                    deadline: deadline ?? BookingDeadline(expiresAt: referenceDate.addingTimeInterval(600)),
                    activityId: "activity1", title: "City Tour")
    }

    private func makeReceipt(chargeId: String = "charge1", amount: Decimal = 50, currency: String = "USD") -> PaymentReceipt {
        PaymentReceipt(chargeId: chargeId, amount: amount, currency: currency, cardBrand: "Visa", last4: "4242", paidAt: referenceDate)
    }

    private func makeCheckout(service: MockToristyBookingService, payment: MockPaymentProcessing, store: BookingRecordStore,
                               confirmationAttempts: Int = 3, retryDelay: TimeInterval = 0,
                               now: @escaping @Sendable () -> Date = { Date() }) -> ToristyCheckout {
        ToristyCheckout(service: service, payment: payment, store: store, backgroundTasks: ImmediateTaskRunner(),
                        confirmationAttempts: confirmationAttempts, retryDelay: retryDelay, now: now)
    }

    private func saveHeldRecord(_ hold: ToristyHold, store: BookingRecordStore, status: BookingRecordStatus = .held,
                                 receipt: PaymentReceipt? = nil) async {
        await store.save(BookingRecord(reference: hold.reference, activityId: hold.activityId, title: hold.title, travelDate: nil,
                                        status: status, total: hold.total, currency: hold.currency, deadline: hold.deadline,
                                        receipt: receipt, createdAt: referenceDate))
    }

    // MARK: - reserve

    func testReserveSavesAHeldRecordAndReturnsAMatchingHold() async throws {
        let service = MockToristyBookingService()
        service.validateResult = .success(makeValidation())
        service.bookingDataResult = .success(makeBookingData(expiresAt: referenceDate.addingTimeInterval(1200)))
        let store = InMemoryBookingRecordStore()
        let checkout = makeCheckout(service: service, payment: MockPaymentProcessing(), store: store, now: { self.referenceDate })

        let hold = try await checkout.reserve(makeSelection(), information: makeInformation(), activityId: "activity1", title: "City Tour")

        XCTAssertEqual(hold.reference, makeReference())
        XCTAssertEqual(hold.total, 50)
        XCTAssertEqual(hold.currency, "USD")
        XCTAssertEqual(hold.deadline, BookingDeadline(expiresAt: referenceDate.addingTimeInterval(1200)))

        let record = await store.record(for: hold.reference)
        XCTAssertEqual(record?.status, .held)
        XCTAssertEqual(record?.providerStatus, "Reserved")
    }

    func testReserveFallsBackToTheDefaultCartLifetimeWhenBookingDataFails() async throws {
        let service = MockToristyBookingService()
        service.validateResult = .success(makeValidation())
        service.bookingDataResult = .failure(BookingError.transport("down"))
        let store = InMemoryBookingRecordStore()
        let checkout = makeCheckout(service: service, payment: MockPaymentProcessing(), store: store, now: { self.referenceDate })

        let hold = try await checkout.reserve(makeSelection(), information: makeInformation(), activityId: "activity1", title: "City Tour")

        XCTAssertEqual(hold.deadline, BookingDeadline(expiresAt: referenceDate.addingTimeInterval(ToristyCheckout.defaultCartLifetime)))
    }

    func testReserveUppercasesTheSelectionCurrencyWhenValidationHasNone() async throws {
        let service = MockToristyBookingService()
        service.validateResult = .success(makeValidation(currency: ""))
        service.bookingDataResult = .failure(BookingError.transport("down"))
        let store = InMemoryBookingRecordStore()
        let checkout = makeCheckout(service: service, payment: MockPaymentProcessing(), store: store, now: { self.referenceDate })

        let hold = try await checkout.reserve(makeSelection(currency: "usd"), information: makeInformation(), activityId: "activity1", title: "City Tour")

        XCTAssertEqual(hold.currency, "USD")
    }

    func testReserveThrowsInvalidSelectionAndNeverCallsValidateForAnUnknownRate() async throws {
        let service = MockToristyBookingService()
        let checkout = makeCheckout(service: service, payment: MockPaymentProcessing(), store: InMemoryBookingRecordStore(), now: { self.referenceDate })

        do {
            _ = try await checkout.reserve(makeSelection(rateId: "unknown"), information: makeInformation(), activityId: "activity1", title: "City Tour")
            XCTFail("Expected an error")
        } catch BookingError.invalidSelection {
            // expected
        }
        XCTAssertEqual(service.validateCallCount, 0)
    }

    // MARK: - pay

    func testPayThrowsHoldExpiredWhenTheHoldIsAlreadyExpired() async throws {
        let service = MockToristyBookingService()
        let payment = MockPaymentProcessing()
        let store = InMemoryBookingRecordStore()
        let expiredHold = makeHold(deadline: BookingDeadline(expiresAt: referenceDate.addingTimeInterval(-1)))
        await saveHeldRecord(expiredHold, store: store)
        let checkout = makeCheckout(service: service, payment: payment, store: store, now: { self.referenceDate })

        do {
            _ = try await checkout.pay(expiredHold, customerEmail: nil)
            XCTFail("Expected an error")
        } catch BookingError.holdExpired {
            // expected
        }
        XCTAssertEqual(payment.chargeCallCount, 0)

        let record = await store.record(for: expiredHold.reference)
        XCTAssertEqual(record?.status, .expired)
    }

    func testPayChargesAndConfirmsOnSuccess() async throws {
        let service = MockToristyBookingService()
        service.confirmResult = .success(())
        let payment = MockPaymentProcessing()
        payment.chargeResult = .success(makeReceipt())
        let store = InMemoryBookingRecordStore()
        let hold = makeHold()
        await saveHeldRecord(hold, store: store)
        let checkout = makeCheckout(service: service, payment: payment, store: store, now: { self.referenceDate })

        let confirmed = try await checkout.pay(hold, customerEmail: "a@b.com")

        XCTAssertEqual(confirmed.reference, hold.reference)
        XCTAssertEqual(confirmed.total, hold.total)
        XCTAssertEqual(payment.lastChargeRequest?.amount, hold.total)
        XCTAssertEqual(payment.lastChargeRequest?.currency, hold.currency)

        let record = await store.record(for: hold.reference)
        XCTAssertEqual(record?.status, .confirmed)
        XCTAssertEqual(record?.providerStatus, "Confirmed")
        XCTAssertEqual(record?.receipt, confirmed.receipt)
    }

    func testPayRecoversViaBookingDataWhenTheConfirmCallFailsButBookingDataShowsConfirmed() async throws {
        let service = MockToristyBookingService()
        service.confirmResult = .failure(BookingError.transport("dropped"))
        service.bookingDataResult = .success(makeBookingData(status: "confirmed"))
        let payment = MockPaymentProcessing()
        payment.chargeResult = .success(makeReceipt())
        let store = InMemoryBookingRecordStore()
        let hold = makeHold()
        await saveHeldRecord(hold, store: store)
        let checkout = makeCheckout(service: service, payment: payment, store: store, now: { self.referenceDate })

        let confirmed = try await checkout.pay(hold, customerEmail: nil)

        XCTAssertEqual(confirmed.reference, hold.reference)
        XCTAssertEqual(service.confirmCallCount, 1)
        XCTAssertEqual(service.bookingDataCallCount, 1)

        let record = await store.record(for: hold.reference)
        XCTAssertEqual(record?.status, .confirmed)
    }

    func testPayBreaksTheRetryLoopEarlyOnAPermanentServerError() async throws {
        let service = MockToristyBookingService()
        service.confirmResult = .failure(BookingError.server(status: 422, code: "INVALID", message: "bad request"))
        service.bookingDataResult = .failure(BookingError.transport("no status either"))
        let payment = MockPaymentProcessing()
        payment.chargeResult = .success(makeReceipt())
        let store = InMemoryBookingRecordStore()
        let hold = makeHold()
        await saveHeldRecord(hold, store: store)
        let checkout = makeCheckout(service: service, payment: payment, store: store, confirmationAttempts: 3, now: { self.referenceDate })

        do {
            _ = try await checkout.pay(hold, customerEmail: nil)
            XCTFail("Expected an error")
        } catch BookingError.confirmationFailedAfterCharge(_, let reference, let reason) {
            XCTAssertEqual(reference, hold.reference)
            XCTAssertEqual(reason, "bad request")
        }
        XCTAssertEqual(service.confirmCallCount, 1)

        let record = await store.record(for: hold.reference)
        XCTAssertEqual(record?.status, .refunded)
        XCTAssertEqual(payment.refundCallCount, 1)
    }

    func testPayBreaksTheRetryLoopEarlyWhenBookingDataShowsTimedOut() async throws {
        let service = MockToristyBookingService()
        service.confirmResult = .failure(BookingError.transport("dropped"))
        service.bookingDataResult = .success(makeBookingData(status: "timedOut"))
        let payment = MockPaymentProcessing()
        payment.chargeResult = .success(makeReceipt())
        let store = InMemoryBookingRecordStore()
        let hold = makeHold()
        await saveHeldRecord(hold, store: store)
        let checkout = makeCheckout(service: service, payment: payment, store: store, confirmationAttempts: 3, now: { self.referenceDate })

        do {
            _ = try await checkout.pay(hold, customerEmail: nil)
            XCTFail("Expected an error")
        } catch BookingError.confirmationFailedAfterCharge {
            // expected
        }
        XCTAssertEqual(service.confirmCallCount, 1)
    }

    func testPayExhaustsRetriesThenRefundsAndThrowsConfirmationFailedAfterCharge() async throws {
        let service = MockToristyBookingService()
        service.confirmResult = .failure(BookingError.transport("dropped"))
        service.bookingDataResult = .failure(BookingError.transport("no status either"))
        let payment = MockPaymentProcessing()
        payment.chargeResult = .success(makeReceipt())
        let store = InMemoryBookingRecordStore()
        let hold = makeHold()
        await saveHeldRecord(hold, store: store)
        let checkout = makeCheckout(service: service, payment: payment, store: store, confirmationAttempts: 2, now: { self.referenceDate })

        do {
            _ = try await checkout.pay(hold, customerEmail: nil)
            XCTFail("Expected an error")
        } catch BookingError.confirmationFailedAfterCharge(_, let reference, let reason) {
            XCTAssertEqual(reference, hold.reference)
            XCTAssertEqual(reason, "dropped")
        }
        XCTAssertEqual(service.confirmCallCount, 2)

        let record = await store.record(for: hold.reference)
        XCTAssertEqual(record?.status, .refunded)
    }

    func testPayMarksTheRecordNeedsRefundWhenTheRefundItselfFails() async throws {
        let service = MockToristyBookingService()
        service.confirmResult = .failure(BookingError.server(status: 422, code: nil, message: "bad"))
        service.bookingDataResult = .failure(BookingError.transport("no status"))
        let payment = MockPaymentProcessing()
        payment.chargeResult = .success(makeReceipt())
        payment.refundResult = .failure(BookingError.transport("refund down"))
        let store = InMemoryBookingRecordStore()
        let hold = makeHold()
        await saveHeldRecord(hold, store: store)
        let checkout = makeCheckout(service: service, payment: payment, store: store, now: { self.referenceDate })

        do {
            _ = try await checkout.pay(hold, customerEmail: nil)
            XCTFail("Expected an error")
        } catch BookingError.confirmationFailedAfterCharge {
            // expected
        }

        let record = await store.record(for: hold.reference)
        XCTAssertEqual(record?.status, .needsRefund)
    }

    // MARK: - status

    func testStatusAlwaysMirrorsTheProviderStatusText() async throws {
        let service = MockToristyBookingService()
        service.bookingDataResult = .success(makeBookingData(status: "reserved"))
        let store = InMemoryBookingRecordStore()
        let reference = makeReference()
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t", travelDate: nil, status: .charged, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, payment: MockPaymentProcessing(), store: store, now: { self.referenceDate })

        _ = try await checkout.status(of: reference)

        let record = await store.record(for: reference)
        XCTAssertEqual(record?.providerStatus, "Reserved")
        XCTAssertEqual(record?.status, .held)
    }

    func testStatusDoesNotOverwriteANeedsRefundRecordsStatus() async throws {
        let service = MockToristyBookingService()
        service.bookingDataResult = .success(makeBookingData(status: "confirmed"))
        let store = InMemoryBookingRecordStore()
        let reference = makeReference()
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t", travelDate: nil, status: .needsRefund, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, payment: MockPaymentProcessing(), store: store, now: { self.referenceDate })

        _ = try await checkout.status(of: reference)

        let record = await store.record(for: reference)
        XCTAssertEqual(record?.status, .needsRefund)
        XCTAssertEqual(record?.providerStatus, "Confirmed")
    }

    func testStatusDoesNotOverwriteARefundedRecordsStatus() async throws {
        let service = MockToristyBookingService()
        service.bookingDataResult = .success(makeBookingData(status: "confirmed"))
        let store = InMemoryBookingRecordStore()
        let reference = makeReference()
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t", travelDate: nil, status: .refunded, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, payment: MockPaymentProcessing(), store: store, now: { self.referenceDate })

        _ = try await checkout.status(of: reference)

        let record = await store.record(for: reference)
        XCTAssertEqual(record?.status, .refunded)
    }

    // MARK: - cancel

    func testCancelUnconditionallyMarksTheRecordCancelled() async throws {
        let service = MockToristyBookingService()
        service.cancelResult = .success(ToristyCancellation(message: "done", confirmationCode: "conf1"))
        let store = InMemoryBookingRecordStore()
        let reference = makeReference()
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t", travelDate: nil, status: .confirmed, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, payment: MockPaymentProcessing(), store: store, now: { self.referenceDate })

        _ = try await checkout.cancel(reference, note: "changed my mind")

        let record = await store.record(for: reference)
        XCTAssertEqual(record?.status, .cancelled)
        XCTAssertEqual(record?.providerStatus, "Cancelled")
    }

    // MARK: - resolveUnfinished

    func testResolveUnfinishedSkipsAChargedRecordWithNoReceipt() async throws {
        let service = MockToristyBookingService()
        let store = InMemoryBookingRecordStore()
        let reference = makeReference()
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t", travelDate: nil, status: .charged, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, payment: MockPaymentProcessing(), store: store, now: { self.referenceDate })

        _ = await checkout.resolveUnfinished()

        XCTAssertEqual(service.bookingDataCallCount, 0)
        let record = await store.record(for: reference)
        XCTAssertEqual(record?.status, .charged)
    }

    func testResolveUnfinishedConfirmsAChargedRecordWhenBookingDataShowsConfirmed() async throws {
        let service = MockToristyBookingService()
        service.bookingDataResult = .success(makeBookingData(status: "confirmed"))
        let store = InMemoryBookingRecordStore()
        let reference = makeReference()
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t", travelDate: nil, status: .charged,
                                        total: 50, currency: "USD", deadline: BookingDeadline(expiresAt: referenceDate.addingTimeInterval(600)),
                                        receipt: makeReceipt(), createdAt: referenceDate))
        let checkout = makeCheckout(service: service, payment: MockPaymentProcessing(), store: store, now: { self.referenceDate })

        let unfinished = await checkout.resolveUnfinished().first { $0.reference == reference }

        XCTAssertEqual(unfinished?.status, .confirmed)
    }

    func testResolveUnfinishedReconfirmsAChargedRecordWithinItsDeadline() async throws {
        let service = MockToristyBookingService()
        service.bookingDataResult = .failure(BookingError.transport("no status"))
        service.confirmResult = .success(())
        let store = InMemoryBookingRecordStore()
        let reference = makeReference()
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t", travelDate: nil, status: .charged,
                                        total: 50, currency: "USD", deadline: BookingDeadline(expiresAt: referenceDate.addingTimeInterval(600)),
                                        receipt: makeReceipt(), createdAt: referenceDate))
        let checkout = makeCheckout(service: service, payment: MockPaymentProcessing(), store: store, now: { self.referenceDate })

        let unfinished = await checkout.resolveUnfinished().first { $0.reference == reference }

        XCTAssertEqual(unfinished?.status, .confirmed)
        XCTAssertEqual(service.confirmCallCount, 1)
    }

    func testResolveUnfinishedRefundsAChargedRecordPastItsDeadline() async throws {
        let service = MockToristyBookingService()
        service.bookingDataResult = .failure(BookingError.transport("no status"))
        let payment = MockPaymentProcessing()
        let store = InMemoryBookingRecordStore()
        let reference = makeReference()
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t", travelDate: nil, status: .charged,
                                        total: 50, currency: "USD", deadline: BookingDeadline(expiresAt: referenceDate.addingTimeInterval(-1)),
                                        receipt: makeReceipt(), createdAt: referenceDate))
        let checkout = makeCheckout(service: service, payment: payment, store: store, now: { self.referenceDate })

        let unfinished = await checkout.resolveUnfinished().first { $0.reference == reference }

        XCTAssertEqual(unfinished?.status, .refunded)
        XCTAssertEqual(service.confirmCallCount, 0)
        XCTAssertEqual(payment.refundCallCount, 1)
    }

    func testResolveUnfinishedRefundsANeedsRefundRecordWithoutReconfirming() async throws {
        let service = MockToristyBookingService()
        service.bookingDataResult = .failure(BookingError.transport("no status"))
        let payment = MockPaymentProcessing()
        let store = InMemoryBookingRecordStore()
        let reference = makeReference()
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t", travelDate: nil, status: .needsRefund,
                                        total: 50, currency: "USD", deadline: BookingDeadline(expiresAt: referenceDate.addingTimeInterval(600)),
                                        receipt: makeReceipt(), createdAt: referenceDate))
        let checkout = makeCheckout(service: service, payment: payment, store: store, now: { self.referenceDate })

        let unfinished = await checkout.resolveUnfinished().first { $0.reference == reference }

        XCTAssertEqual(unfinished?.status, .refunded)
        XCTAssertEqual(service.confirmCallCount, 0)
        XCTAssertEqual(payment.refundCallCount, 1)
    }

    func testResolveUnfinishedOnlyProcessesToristyRecords() async throws {
        let service = MockToristyBookingService()
        let store = InMemoryBookingRecordStore()
        let otherReference = BookingReference(provider: .victory, primary: "victory1")
        await store.save(BookingRecord(reference: otherReference, activityId: "a1", title: "t", travelDate: nil, status: .charged,
                                        receipt: makeReceipt(), createdAt: referenceDate))
        let checkout = makeCheckout(service: service, payment: MockPaymentProcessing(), store: store, now: { self.referenceDate })

        let unfinished = await checkout.resolveUnfinished()

        XCTAssertTrue(unfinished.isEmpty)
        let record = await store.record(for: otherReference)
        XCTAssertEqual(record?.status, .charged)
    }
}
