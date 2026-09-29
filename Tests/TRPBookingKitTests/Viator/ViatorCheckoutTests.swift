import XCTest
@testable import TRPBookingKit

final class ViatorCheckoutTests: XCTestCase {

    private let referenceDate = ISO8601.date(from: "2026-03-01T00:00:00Z")!
    private let utc = TimeZone(identifier: "UTC")!

    private func makeItem(productCode: String = "P1", optionCode: String = "OPT1", travelDate: BookingDate? = nil) -> ViatorHoldItem {
        ViatorHoldItem(productCode: productCode, productOptionCode: optionCode, startTime: "09:00",
                       travelDate: travelDate ?? BookingDate(year: 2026, month: 6, day: 1)!,
                       paxMix: [ViatorPax(ageBand: .adult, numberOfTravelers: 2)])
    }

    private func holdJSON(bookingRef: String = "book1", cartRef: String = "cart1", status: String = "BOOKABLE",
                           rejectionReasonCode: String? = nil, paymentSessionToken: String? = "sess-token",
                           validUntil: String = "2026-06-01T00:00:00Z") -> String {
        let tokenField = paymentSessionToken.map { "\"paymentSessionToken\": \"\($0)\"," } ?? ""
        let rejectionField = rejectionReasonCode.map { "\"rejectionReasonCode\": \"\($0)\"," } ?? ""
        return """
        {"cartRef": "\(cartRef)", "currency": "USD", \(tokenField)
         "items": [{"bookingRef": "\(bookingRef)", "status": "\(status)", \(rejectionField)
           "itemTotalPrice": {"recommendedRetailPrice": 100},
           "bookingHoldInfo": {"availability": {"validUntil": "\(validUntil)"}, "pricing": {"validUntil": "\(validUntil)"}}}]}
        """
    }

    private func makeHold(deadline: BookingDeadline? = nil, total: Decimal? = 100, currency: String = "USD") -> ViatorCheckoutHold {
        ViatorCheckoutHold(reference: BookingReference(provider: .viator, primary: "book1", secondary: "cart1"),
                           cartRef: "cart1", bookingRef: "book1", item: makeItem(),
                           total: total, currency: currency,
                           deadline: deadline ?? BookingDeadline(expiresAt: referenceDate.addingTimeInterval(600)),
                           paymentSessionToken: "sess-token", activityId: "activity1", title: "City Tour")
    }

    private func bookResultJSON(bookingRef: String = "book1", status: String = "CONFIRMED", currency: String = "USD") -> String {
        """
        {"cartRef": "cart1", "currency": "\(currency)",
         "items": [{"bookingRef": "\(bookingRef)", "status": "\(status)", "itemTotalPrice": {"recommendedRetailPrice": 100}}]}
        """
    }

    private func makeCheckout(service: MockViatorBookingService, store: InMemoryBookingRecordStore,
                               statusAttempts: Int = 3, retryDelay: TimeInterval = 0,
                               now: @escaping @Sendable () -> Date = { Date() }) -> ViatorCheckout {
        ViatorCheckout(service: service, store: store, backgroundTasks: ImmediateTaskRunner(),
                       maximumHolds: 2, statusAttempts: statusAttempts, retryDelay: retryDelay, now: now)
    }

    private func makeBookerDetails() -> ViatorBookerDetails {
        ViatorBookerDetails(firstName: "Jane", lastName: "Doe", email: "jane@example.com", phone: "+1", answers: [])
    }

    private func makeEmptyContext() throws -> ViatorProductContext {
        ViatorProductContext(product: try decodeJSON(ViatorProduct.self, #"{"productCode": "P1"}"#),
                              calendar: ViatorAvailabilityCalendar(schedule: try decodeJSON(ViatorSchedule.self, #"{"productCode": "P1", "bookableItems": []}"#), timeZone: utc),
                              questions: [], locations: [:])
    }

    // MARK: - context

    func testContextComposesProductScheduleQuestionsAndLocations() async throws {
        let service = MockViatorBookingService()
        service.productResult = .success(try decodeJSON(ViatorProduct.self,
            #"{"productCode": "P1", "bookingQuestions": ["Q1"], "logistics": {"travelerPickup": {"locations": [{"location": {"ref": "L1"}}]}}}"#))
        service.scheduleResult = .success(try decodeJSON(ViatorSchedule.self, #"{"productCode": "P1", "bookableItems": []}"#))
        service.bookingQuestionsResult = .success([try decodeJSON(ViatorBookingQuestion.self, #"{"id": "Q1"}"#)])
        service.locationsResult = .success([try decodeJSON(ViatorLocation.self, #"{"reference": "L1", "name": "Hotel"}"#)])
        let checkout = makeCheckout(service: service, store: InMemoryBookingRecordStore())

        let context = try await checkout.context(productCode: "P1")

        XCTAssertEqual(context.questions.map(\.id), ["Q1"])
        XCTAssertEqual(context.pickupLocations.map(\.name), ["Hotel"])
    }

    func testContextToleratesLocationsFailingToResolve() async throws {
        let service = MockViatorBookingService()
        service.productResult = .success(try decodeJSON(ViatorProduct.self, #"{"productCode": "P1"}"#))
        service.scheduleResult = .success(try decodeJSON(ViatorSchedule.self, #"{"productCode": "P1", "bookableItems": []}"#))
        service.locationsResult = .failure(BookingError.transport("down"))
        let checkout = makeCheckout(service: service, store: InMemoryBookingRecordStore())

        let context = try await checkout.context(productCode: "P1")

        XCTAssertTrue(context.locations.isEmpty)
    }

    // MARK: - hold

    func testHoldSavesAHeldRecordOnSuccess() async throws {
        let service = MockViatorBookingService()
        service.holdResult = .success(try decodeJSON(ViatorHold.self, holdJSON()))
        let store = InMemoryBookingRecordStore()
        let checkout = makeCheckout(service: service, store: store, now: { self.referenceDate })

        let hold = try await checkout.hold(makeItem(), currency: "usd", activityId: "activity1", title: "City Tour")

        XCTAssertEqual(hold.reference, BookingReference(provider: .viator, primary: "book1", secondary: "cart1"))
        XCTAssertEqual(hold.total, 100)
        XCTAssertEqual(hold.currency, "USD")
        XCTAssertEqual(hold.paymentSessionToken, "sess-token")

        let record = await store.record(for: hold.reference)
        XCTAssertEqual(record?.status, .held)
        XCTAssertEqual(record?.total, 100)
    }

    func testHoldThrowsTooManyHoldsAfterTheLimitForTheSameSelection() async throws {
        let service = MockViatorBookingService()
        service.holdResult = .success(try decodeJSON(ViatorHold.self, holdJSON()))
        let checkout = makeCheckout(service: service, store: InMemoryBookingRecordStore())
        let item = makeItem()

        _ = try await checkout.hold(item, currency: "USD", activityId: "activity1", title: "City Tour")
        _ = try await checkout.hold(item, currency: "USD", activityId: "activity1", title: "City Tour")

        do {
            _ = try await checkout.hold(item, currency: "USD", activityId: "activity1", title: "City Tour")
            XCTFail("Expected an error")
        } catch BookingError.tooManyHolds {
            // expected
        }
    }

    func testHoldThrowsHoldRejectedWhenTheCartHasNoItems() async throws {
        let service = MockViatorBookingService()
        service.holdResult = .success(try decodeJSON(ViatorHold.self, #"{"cartRef": "cart1", "currency": "USD", "items": []}"#))
        let checkout = makeCheckout(service: service, store: InMemoryBookingRecordStore())

        do {
            _ = try await checkout.hold(makeItem(), currency: "USD", activityId: "a1", title: "t")
            XCTFail("Expected an error")
        } catch BookingError.holdRejected(let code) {
            XCTAssertNil(code)
        }
    }

    func testHoldThrowsHoldRejectedWithReasonWhenTheItemIsNotBookable() async throws {
        let service = MockViatorBookingService()
        service.holdResult = .success(try decodeJSON(ViatorHold.self, holdJSON(status: "NOT_AVAILABLE", rejectionReasonCode: "SOLD_OUT")))
        let checkout = makeCheckout(service: service, store: InMemoryBookingRecordStore())

        do {
            _ = try await checkout.hold(makeItem(), currency: "USD", activityId: "a1", title: "t")
            XCTFail("Expected an error")
        } catch BookingError.holdRejected(let code) {
            XCTAssertEqual(code, "SOLD_OUT")
        }
    }

    func testHoldThrowsRejectedWhenTheCartHasNoPaymentSessionToken() async throws {
        let service = MockViatorBookingService()
        service.holdResult = .success(try decodeJSON(ViatorHold.self, holdJSON(paymentSessionToken: nil)))
        let checkout = makeCheckout(service: service, store: InMemoryBookingRecordStore())

        do {
            _ = try await checkout.hold(makeItem(), currency: "USD", activityId: "a1", title: "t")
            XCTFail("Expected an error")
        } catch BookingError.rejected {
            // expected
        }
    }

    // MARK: - book: success

    func testBookReturnsAConfirmedOutcomeAndUpdatesTheRecord() async throws {
        let service = MockViatorBookingService()
        service.bookResult = .success(try decodeJSON(ViatorBookResult.self, bookResultJSON()))
        let store = InMemoryBookingRecordStore()
        let hold = makeHold()
        await store.save(BookingRecord(reference: hold.reference, activityId: "a1", title: "t", travelDate: hold.item.travelDate,
                                        status: .held, total: 100, currency: "USD", deadline: hold.deadline, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, store: store, now: { self.referenceDate })
        let payment = MockViatorPaymentTokenProviding()

        let outcome = try await checkout.book(hold, details: makeBookerDetails(), context: try makeEmptyContext(), payment: payment)

        XCTAssertEqual(outcome.status, .confirmed)
        XCTAssertEqual(outcome.total, 100)
        XCTAssertEqual(payment.callCount, 1)

        let record = await store.record(for: hold.reference)
        XCTAssertEqual(record?.status, .confirmed)
    }

    func testSuccessfulBookResetsTheHoldCountForFurtherSelections() async throws {
        let service = MockViatorBookingService()
        service.holdResult = .success(try decodeJSON(ViatorHold.self, holdJSON()))
        service.bookResult = .success(try decodeJSON(ViatorBookResult.self, bookResultJSON()))
        let store = InMemoryBookingRecordStore()
        let checkout = makeCheckout(service: service, store: store, now: { self.referenceDate })
        let item = makeItem()

        _ = try await checkout.hold(item, currency: "USD", activityId: "a1", title: "t")
        let secondHold = try await checkout.hold(item, currency: "USD", activityId: "a1", title: "t")
        _ = try await checkout.book(secondHold, details: makeBookerDetails(), context: try makeEmptyContext(), payment: MockViatorPaymentTokenProviding())

        _ = try await checkout.hold(item, currency: "USD", activityId: "a1", title: "t")
        _ = try await checkout.hold(item, currency: "USD", activityId: "a1", title: "t")
    }

    // MARK: - book: hold expiry

    func testBookThrowsHoldExpiredWhenTheHoldIsAlreadyExpired() async throws {
        let service = MockViatorBookingService()
        let store = InMemoryBookingRecordStore()
        let expiredDeadline = BookingDeadline(expiresAt: referenceDate.addingTimeInterval(-1))
        let hold = makeHold(deadline: expiredDeadline)
        await store.save(BookingRecord(reference: hold.reference, activityId: "a1", title: "t", travelDate: hold.item.travelDate,
                                        status: .held, total: 100, currency: "USD", deadline: expiredDeadline, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, store: store, now: { self.referenceDate })
        let payment = MockViatorPaymentTokenProviding()

        do {
            _ = try await checkout.book(hold, details: makeBookerDetails(), context: try makeEmptyContext(), payment: payment)
            XCTFail("Expected an error")
        } catch BookingError.holdExpired {
            // expected
        }
        XCTAssertEqual(payment.callCount, 0)

        let record = await store.record(for: hold.reference)
        XCTAssertEqual(record?.status, .expired)
    }

    func testBookThrowsHoldExpiredWhenTheHoldExpiresWhileAcquiringThePaymentToken() async throws {
        let service = MockViatorBookingService()
        let store = InMemoryBookingRecordStore()
        let deadline = BookingDeadline(expiresAt: referenceDate.addingTimeInterval(60))
        let hold = makeHold(deadline: deadline)
        await store.save(BookingRecord(reference: hold.reference, activityId: "a1", title: "t", travelDate: hold.item.travelDate,
                                        status: .held, total: 100, currency: "USD", deadline: deadline, createdAt: referenceDate))
        let clock = MutableDate(referenceDate)
        let checkout = makeCheckout(service: service, store: store, now: { clock.date })
        let payment = MockViatorPaymentTokenProviding()
        payment.beforeReturning = { clock.date = deadline.expiresAt.addingTimeInterval(1) }

        do {
            _ = try await checkout.book(hold, details: makeBookerDetails(), context: try makeEmptyContext(), payment: payment)
            XCTFail("Expected an error")
        } catch BookingError.holdExpired {
            // expected
        }
        XCTAssertEqual(payment.callCount, 1)
        XCTAssertEqual(service.bookCallCount, 0)

        let record = await store.record(for: hold.reference)
        XCTAssertEqual(record?.status, .expired)
    }

    // MARK: - book: failures

    func testBookMarksTheRecordFailedAndRethrowsAPermanentServerError() async throws {
        let service = MockViatorBookingService()
        service.bookResult = .failure(BookingError.server(status: 422, code: "INVALID", message: "bad request"))
        let store = InMemoryBookingRecordStore()
        let hold = makeHold()
        await store.save(BookingRecord(reference: hold.reference, activityId: "a1", title: "t", travelDate: hold.item.travelDate,
                                        status: .held, total: 100, currency: "USD", deadline: hold.deadline, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, store: store, now: { self.referenceDate })

        do {
            _ = try await checkout.book(hold, details: makeBookerDetails(), context: try makeEmptyContext(), payment: MockViatorPaymentTokenProviding())
            XCTFail("Expected an error")
        } catch BookingError.server(let status, _, _) {
            XCTAssertEqual(status, 422)
        }

        let record = await store.record(for: hold.reference)
        XCTAssertEqual(record?.status, .failed)
    }

    func testBookRecoversThroughProbeWhenTheBookCallFailsButStatusResolves() async throws {
        let service = MockViatorBookingService()
        service.bookResult = .failure(BookingError.transport("timed out"))
        service.statusResult = .success(try decodeJSON(ViatorBookingStatusResult.self, #"{"bookingRef": "book1", "status": "CONFIRMED"}"#))
        let store = InMemoryBookingRecordStore()
        let hold = makeHold()
        await store.save(BookingRecord(reference: hold.reference, activityId: "a1", title: "t", travelDate: hold.item.travelDate,
                                        status: .held, total: 100, currency: "USD", deadline: hold.deadline, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, store: store, now: { self.referenceDate })

        let outcome = try await checkout.book(hold, details: makeBookerDetails(), context: try makeEmptyContext(), payment: MockViatorPaymentTokenProviding())

        XCTAssertEqual(outcome.status, .confirmed)
        let record = await store.record(for: hold.reference)
        XCTAssertEqual(record?.status, .confirmed)
    }

    func testBookThrowsOutcomeUnknownWhenTheProbeNeverResolves() async throws {
        let service = MockViatorBookingService()
        service.bookResult = .failure(BookingError.transport("timed out"))
        service.statusResult = .failure(BookingError.transport("still down"))
        let store = InMemoryBookingRecordStore()
        let hold = makeHold()
        await store.save(BookingRecord(reference: hold.reference, activityId: "a1", title: "t", travelDate: hold.item.travelDate,
                                        status: .held, total: 100, currency: "USD", deadline: hold.deadline, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, store: store, statusAttempts: 2, now: { self.referenceDate })

        do {
            _ = try await checkout.book(hold, details: makeBookerDetails(), context: try makeEmptyContext(), payment: MockViatorPaymentTokenProviding())
            XCTFail("Expected an error")
        } catch BookingError.outcomeUnknown(let reference) {
            XCTAssertEqual(reference, hold.reference)
        }
        XCTAssertEqual(service.statusCallCount, 2)

        let record = await store.record(for: hold.reference)
        XCTAssertEqual(record?.status, .charged)
    }

    func testBookThrowsRejectedWhenTheBookedItemComesBackRejected() async throws {
        let service = MockViatorBookingService()
        service.bookResult = .success(try decodeJSON(ViatorBookResult.self, bookResultJSON(status: "REJECTED")))
        let store = InMemoryBookingRecordStore()
        let hold = makeHold()
        await store.save(BookingRecord(reference: hold.reference, activityId: "a1", title: "t", travelDate: hold.item.travelDate,
                                        status: .held, total: 100, currency: "USD", deadline: hold.deadline, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, store: store, now: { self.referenceDate })

        do {
            _ = try await checkout.book(hold, details: makeBookerDetails(), context: try makeEmptyContext(), payment: MockViatorPaymentTokenProviding())
            XCTFail("Expected an error")
        } catch BookingError.rejected {
            // expected
        }
    }

    // MARK: - status

    func testStatusMirrorsTheResolvedStatusIntoTheRecord() async throws {
        let service = MockViatorBookingService()
        service.statusResult = .success(try decodeJSON(ViatorBookingStatusResult.self, #"{"bookingRef": "book1", "status": "ON_HOLD"}"#))
        let store = InMemoryBookingRecordStore()
        let reference = BookingReference(provider: .viator, primary: "book1", secondary: "cart1")
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t", travelDate: nil,
                                        status: .charged, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, store: store)

        let status = try await checkout.status(of: reference)

        XCTAssertEqual(status, .pending)
        let record = await store.record(for: reference)
        XCTAssertEqual(record?.status, .pending)
        XCTAssertEqual(record?.providerStatus, "ON_HOLD")
    }

    // MARK: - cancel

    func testCancelThrowsNotCancellableWhenTheTravelDateIsNotInTheFuture() async throws {
        let service = MockViatorBookingService()
        let store = InMemoryBookingRecordStore()
        let reference = BookingReference(provider: .viator, primary: "book1", secondary: "cart1")
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t",
                                        travelDate: BookingDate(date: referenceDate, timeZone: utc), status: .confirmed, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, store: store, now: { self.referenceDate })

        do {
            _ = try await checkout.cancel(reference)
            XCTFail("Expected an error")
        } catch BookingError.notCancellable {
            // expected
        }
        XCTAssertEqual(service.cancelCallCount, 0)
    }

    func testCancelThrowsNotCancellableWhenTheRecordIsNotConfirmedOrPending() async throws {
        let service = MockViatorBookingService()
        let store = InMemoryBookingRecordStore()
        let reference = BookingReference(provider: .viator, primary: "book1", secondary: "cart1")
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t",
                                        travelDate: BookingDate(year: 2030, month: 1, day: 1), status: .held, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, store: store, now: { self.referenceDate })

        do {
            _ = try await checkout.cancel(reference)
            XCTFail("Expected an error")
        } catch BookingError.notCancellable {
            // expected
        }
    }

    func testCancelThrowsNotCancellableWhenViatorDeclines() async throws {
        let service = MockViatorBookingService()
        service.cancelResult = .success(try decodeJSON(ViatorCancellation.self, #"{"bookingId": "book1", "status": "DECLINED", "reason": "too late"}"#))
        let store = InMemoryBookingRecordStore()
        let reference = BookingReference(provider: .viator, primary: "book1", secondary: "cart1")
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t",
                                        travelDate: BookingDate(year: 2030, month: 1, day: 1), status: .confirmed, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, store: store, now: { self.referenceDate })

        do {
            _ = try await checkout.cancel(reference)
            XCTFail("Expected an error")
        } catch BookingError.notCancellable(let reason) {
            XCTAssertEqual(reason, "too late")
        }
    }

    func testCancelUpdatesTheRecordToCancelledWhenAccepted() async throws {
        let service = MockViatorBookingService()
        service.cancelResult = .success(try decodeJSON(ViatorCancellation.self, #"{"bookingId": "book1", "status": "ACCEPTED"}"#))
        let store = InMemoryBookingRecordStore()
        let reference = BookingReference(provider: .viator, primary: "book1", secondary: "cart1")
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t",
                                        travelDate: BookingDate(year: 2030, month: 1, day: 1), status: .confirmed, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, store: store, now: { self.referenceDate })

        _ = try await checkout.cancel(reference)

        let record = await store.record(for: reference)
        XCTAssertEqual(record?.status, .cancelled)
    }

    // MARK: - resolveUnfinished

    func testResolveUnfinishedExpiresAHeldRecordPastItsDeadline() async throws {
        let service = MockViatorBookingService()
        let store = InMemoryBookingRecordStore()
        let reference = BookingReference(provider: .viator, primary: "book1", secondary: "cart1")
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t", travelDate: nil, status: .held,
                                        deadline: BookingDeadline(expiresAt: referenceDate.addingTimeInterval(-1)), createdAt: referenceDate))
        let checkout = makeCheckout(service: service, store: store, now: { self.referenceDate })

        let unfinished = await checkout.resolveUnfinished().first { $0.reference == reference }

        XCTAssertEqual(unfinished?.status, .expired)
    }

    func testResolveUnfinishedProbesChargedRecordsAndMirrorsTheirStatus() async throws {
        let service = MockViatorBookingService()
        service.statusResult = .success(try decodeJSON(ViatorBookingStatusResult.self, #"{"bookingRef": "book1", "status": "CONFIRMED"}"#))
        let store = InMemoryBookingRecordStore()
        let reference = BookingReference(provider: .viator, primary: "book1", secondary: "cart1")
        await store.save(BookingRecord(reference: reference, activityId: "a1", title: "t", travelDate: nil, status: .charged, createdAt: referenceDate))
        let checkout = makeCheckout(service: service, store: store, now: { self.referenceDate })

        let unfinished = await checkout.resolveUnfinished().first { $0.reference == reference }

        XCTAssertEqual(unfinished?.status, .confirmed)
    }
}

private final class MutableDate: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}
