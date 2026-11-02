import Foundation
import XCTest
@testable import TRPBookingKit

/// `LocalBookingClient.cancellationQuote` against a confirmed Viator or Toristy booking.
final class LocalCancellationQuoteTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-02T14:05:00Z")!
    private var viatorService: MockViatorBookingService!
    private var viatorStore: InMemoryBookingRecordStore!
    private var viatorCheckout: LocalCheckoutClient!
    private var viatorBookings: LocalBookingClient!

    private static let viatorFlow = ["01-create", "02-date", "03-travelers", "04-option", "05-details", "06-back",
                                     "07-details-again", "08-summary", "09-payment", "10-poll"]
    private static let viatorOptionExclusions = ["currentStep.blocks[0].options[2].badge"]

    override func setUp() async throws {
        viatorService = MockViatorBookingService()
        viatorService.productResult = .success(try decodeJSON(ViatorProduct.self, Self.productJSON))
        viatorService.scheduleResult = .success(try decodeJSON(ViatorSchedule.self, Self.scheduleJSON))
        viatorService.locationsResult = .success([try decodeJSON(ViatorLocation.self, #"{"reference": "hotel_123", "name": "Hotel Arts Barcelona"}"#)])
        viatorService.bookingQuestionsResult = .success(try decodeJSON([ViatorBookingQuestion].self, #"""
        [{"id": "PICKUP_POINT", "type": "LOCATION_REF_OR_FREE_TEXT", "group": "PER_BOOKING", "required": "OPTIONAL",
          "units": ["LOCATION_REFERENCE", "FREETEXT"], "label": "Pickup location"}]
        """#))
        viatorService.availabilityResult = .success(try decodeJSON(ViatorAvailability.self, Self.availabilityJSON))
        viatorService.holdResult = .success(try decodeJSON(ViatorHold.self, Self.holdJSON))
        viatorService.bookResult = .success(try decodeJSON(ViatorBookResult.self, Self.bookJSON))
        viatorStore = InMemoryBookingRecordStore()
        let clock = now
        let viator = ViatorCheckout(service: viatorService, store: viatorStore, backgroundTasks: ImmediateTaskRunner(),
                                    maximumHolds: 2, statusAttempts: 1, retryDelay: 0, now: { clock })
        let product = LocalProduct(
            id: "5010BCN_SAGRADA", provider: .viator, providerProductId: "5010BCN_SAGRADA", title: "Sagrada Família guided tour",
            imageUrl: "https://cdn.tripian.com/p/5010BCN_SAGRADA.jpg", timeZone: TimeZone(identifier: "Europe/Madrid")!,
            meetingPoint: .init(name: "Sagrada Família, Carrer de la Marina entrance", address: "Carrer de Mallorca 401, 08013 Barcelona",
                                lat: 41.4036, lng: 2.1744),
            optionDurationMinutes: ["TG1": 90, "TG2": 120])
        viatorCheckout = LocalCheckoutClient(viator: viator, store: viatorStore, catalog: StaticProductCatalog([product]),
                                             contractVersion: BookingContract.version, fallbackWebBase: "https://book.tripian.com/c/",
                                             identifiers: .sequence(["chk_01J9ZQ4M8K", "act_01J9ZR2B", "act_01J9ZR3C"]),
                                             processingWait: 0.05, now: { clock })
        viatorBookings = LocalBookingClient(store: viatorStore, viator: viator, toristy: nil, contractVersion: BookingContract.version, now: { clock })

        for name in Self.viatorFlow {
            if name == "09-payment" { viatorService.bookDelay = 0.3 }
            if name == "10-poll" { try await Task.sleep(nanoseconds: 500_000_000) }
            try await assertLocalSnapshot("viator", name, checkout: viatorCheckout, bookings: viatorBookings,
                                          excluding: name == "03-travelers" ? Self.viatorOptionExclusions : [])
        }
    }

    private func confirmedViatorUUID() async throws -> String {
        let record = try await viatorStore.all().first { $0.contractBooking != nil }
        return try XCTUnwrap(record?.contractBooking?.uuid)
    }

    func testViatorQuoteDifferingFromSnapshotIsReturnedAndStored() async throws {
        let uuid = try await confirmedViatorUUID()
        let before = try await viatorBookings.get(uuid: uuid, lang: "en")
        viatorService.cancelQuoteResult = .success(try decodeJSON(ViatorCancelQuote.self, #"""
        {"bookingId": "BR-1122334455", "status": "CANCELLABLE",
         "refundDetails": {"itemPrice": 145, "refundAmount": 31.25, "refundPercentage": 50, "currencyCode": "EUR"}}
        """#))

        let quote = try await viatorBookings.cancellationQuote(uuid: uuid)

        XCTAssertNotEqual(quote, before.cancellation)
        XCTAssertTrue(quote.allowed)
        XCTAssertEqual(quote.refund.value, .partial)
        XCTAssertEqual(quote.refundAmount?.amount, "31.25")
        XCTAssertEqual(quote.refundAmount?.currency, "EUR")

        let stored = try await viatorBookings.get(uuid: uuid, lang: "en")
        XCTAssertEqual(stored.cancellation, quote)
    }

    func testViatorQuoteNotCancellableIsDisallowed() async throws {
        let uuid = try await confirmedViatorUUID()
        viatorService.cancelQuoteResult = .success(try decodeJSON(ViatorCancelQuote.self, #"""
        {"bookingId": "BR-1122334455", "status": "NOT_CANCELLABLE",
         "refundDetails": {"itemPrice": 145, "refundAmount": 0, "refundPercentage": 0, "currencyCode": "EUR"}}
        """#))

        let quote = try await viatorBookings.cancellationQuote(uuid: uuid)

        XCTAssertFalse(quote.allowed)
    }

    func testViatorQuoteFailingWithAGenericErrorThrowsSupplierUnavailable() async throws {
        let uuid = try await confirmedViatorUUID()
        viatorService.cancelQuoteResult = .failure(URLError(.timedOut))

        do {
            _ = try await viatorBookings.cancellationQuote(uuid: uuid)
            XCTFail("expected a ContractError")
        } catch let error as BookingContract.ContractError {
            XCTAssertEqual(error.httpStatus, 503)
            XCTAssertEqual(error.code, .supplierUnavailable)
            XCTAssertTrue(error.data.retryable)
        }
    }

    func testViatorQuoteOnABookingPastItsTravelDateIsDisallowedAndStored() async throws {
        let uuid = try await confirmedViatorUUID()
        let records = await viatorStore.all()
        let record = try XCTUnwrap(records.first { $0.contractBooking?.uuid == uuid })
        await viatorStore.update(record.reference) { $0.status = .expired }

        let quote = try await viatorBookings.cancellationQuote(uuid: uuid)

        XCTAssertFalse(quote.allowed)
        let stored = try await viatorBookings.get(uuid: uuid, lang: "en")
        XCTAssertFalse(stored.cancellation.allowed)
    }

    func testToristyRecordReturnsStoredSnapshotUnchanged() async throws {
        let clock = TestClock(ISO8601DateFormatter().date(from: "2026-10-02T09:12:00Z")!)
        let service = MockToristyBookingService()
        service.bookingInformationResult = .success(LocalToristyContractTests.information)
        service.availabilityResult = .success(LocalToristyContractTests.availability)
        service.validateResult = .success(ToristyValidation(cartId: "cart-48213", confirmationCode: "TRS-20261015-48213",
                                                             totalPrice: Decimal(string: "62.50")!, currency: "EUR"))
        service.bookingDataResult = .success(ToristyBookingData(
            cartId: "cart-48213", confirmationCode: "TRS-20261015-48213", currency: "EUR", totalPrice: Decimal(string: "62.50")!,
            createdAt: clock.now, expiresAt: ISO8601DateFormatter().date(from: "2026-10-02T09:42:00Z")!, status: .reserved,
            activityDate: "2026-10-15"))
        let stripe = MockStripePaymentIntents()
        let store = InMemoryBookingRecordStore()
        let now: @Sendable () -> Date = { [clock] in clock.now }
        let toristy = ToristyCheckout(service: service, payment: stripe, store: store, backgroundTasks: ImmediateTaskRunner(),
                                      confirmationAttempts: 1, retryDelay: 0, now: now)
        let product = LocalProduct(
            id: "TOR-PMI-CATHEDRAL", provider: .toristy, providerProductId: "48213", title: "Palma Cathedral and Old Town walking tour",
            imageUrl: "https://cdn.tripian.com/p/TOR-PMI-CATHEDRAL.jpg", timeZone: TimeZone(identifier: "Europe/Madrid")!,
            durationMinutes: 120,
            meetingPoint: .init(name: "Plaça de la Seu, cathedral main door", address: "Plaça de la Seu s/n, 07001 Palma",
                                lat: 39.5676, lng: 2.6484))
        let checkout = LocalCheckoutClient(viator: nil, toristy: toristy, stripe: stripe, store: store,
                                           catalog: StaticProductCatalog([product]), fallbackWebBase: "https://book.tripian.com/c/",
                                           identifiers: .sequence(["chk_01J9ZT7P2N", "act_01J9ZTB4"]), now: now)
        let bookings = LocalBookingClient(store: store, viator: nil, toristy: toristy, contractVersion: BookingContract.version, now: now)

        for name in ["01-create", "02-date", "03-time", "04-rate", "05-travelers", "06-details", "07-summary"] {
            try await assertLocalSnapshot("toristy", name, checkout: checkout, bookings: bookings,
                                          excluding: name == "03-time" ? ["currentStep.blocks[0].options[1].subtitle"] : [])
        }
        _ = try await checkout.action(checkoutId: "chk_01J9ZT7P2N", actionId: "act_01J9ZTB4",
                                      result: BookingContract.ActionResult(status: .init(.succeeded)), lang: "en")

        let record = try await store.all().first { $0.contractBooking != nil }
        let booking = try XCTUnwrap(record?.contractBooking)
        let before = booking.cancellation

        let quote = try await bookings.cancellationQuote(uuid: booking.uuid)

        XCTAssertEqual(quote, before)
        let recordsAfter = await store.all()
        XCTAssertEqual(recordsAfter.first?.contractBooking?.cancellation, before)
    }

    private static let productJSON = #"""
    {"productCode": "5010BCN_SAGRADA", "title": "Sagrada Família guided tour", "timeZone": "Europe/Madrid", "bookingQuestions": ["PICKUP_POINT"],
     "pricingInfo": {"ageBands": [
       {"ageBand": "ADULT", "startAge": 13, "endAge": 99, "minTravelersPerBooking": 1, "maxTravelersPerBooking": 9},
       {"ageBand": "CHILD", "startAge": 4, "endAge": 12, "minTravelersPerBooking": 0, "maxTravelersPerBooking": 9}]},
     "bookingRequirements": {"minTravelersPerBooking": 1, "maxTravelersPerBooking": 9},
     "productOptions": [{"productOptionCode": "TG1", "title": "Guided tour in English",
                         "languageGuides": [{"type": "GUIDE", "language": "es", "legacyGuide": "es/SERVICE_GUIDE"},
                                            {"type": "GUIDE", "language": "en", "legacyGuide": "en/SERVICE_GUIDE"}]},
                        {"productOptionCode": "TG2", "title": "Guided tour with tower access"}],
     "logistics": {"travelerPickup": {"pickupOptionType": "PICKUP_EVERYONE", "locations": [{"location": {"ref": "hotel_123"}}]}},
     "cancellationPolicy": {"refundEligibility": [{"dayRangeMin": 1, "percentageRefundable": 100}]}}
    """#

    private static func scheduleItem(_ code: String, _ times: [String]) -> String {
        let entries = times.map { #"{"startTime": "\#($0)", "unavailableDates": [{"date": "2026-10-17"}]}"# }.joined(separator: ",")
        let days = #""MONDAY","TUESDAY","WEDNESDAY","THURSDAY","FRIDAY","SATURDAY","SUNDAY""#
        return #"{"productOptionCode": "\#(code)", "seasons": [{"startDate": "2026-10-15", "endDate": "2026-10-18", "pricingRecords": [{"daysOfWeek": [\#(days)], "timedEntries": [\#(entries)]}]}]}"#
    }

    private static let scheduleJSON = #"{"productCode": "5010BCN_SAGRADA", "currency": "EUR", "bookableItems": ["#
        + scheduleItem("TG1", ["10:30", "14:00"]) + "," + scheduleItem("TG2", ["11:00", "16:00"]) + "]}"

    private static func availabilityItem(_ code: String, _ time: String, available: Bool, adults: Int, total: Int) -> String {
        #"""
        {"productOptionCode": "\#(code)", "startTime": "\#(time)", "available": \#(available),
         "lineItems": [{"ageBand": "ADULT", "numberOfTravelers": 2, "subtotalPrice": {"price": {"recommendedRetailPrice": \#(adults)}}},
                       {"ageBand": "CHILD", "numberOfTravelers": 1, "subtotalPrice": {"price": {"recommendedRetailPrice": \#(total - adults)}}}],
         "totalPrice": {"price": {"recommendedRetailPrice": \#(total)}}}
        """#
    }

    private static let availabilityJSON = #"{"productCode": "5010BCN_SAGRADA", "currency": "EUR", "bookableItems": ["#
        + [availabilityItem("TG1", "10:30", available: true, adults: 110, total: 145),
           availabilityItem("TG1", "14:00", available: true, adults: 110, total: 145),
           availabilityItem("TG2", "11:00", available: true, adults: 140, total: 190),
           availabilityItem("TG2", "16:00", available: false, adults: 140, total: 190)].joined(separator: ",") + "]}"

    private static let holdJSON = #"""
    {"cartRef": "cart-1", "currency": "EUR", "paymentSessionToken": "vps_7Hq2LmN9xR4tB8wK",
     "items": [{"bookingRef": "BR-1122334455", "status": "BOOKABLE", "itemTotalPrice": {"recommendedRetailPrice": 145},
       "bookingHoldInfo": {"availability": {"validUntil": "2026-10-02T14:20:00Z"}, "pricing": {"validUntil": "2026-10-02T14:20:00Z"}}}]}
    """#

    private static let bookJSON = #"""
    {"cartRef": "cart-1", "currency": "EUR",
     "items": [{"bookingRef": "BR-1122334455", "status": "CONFIRMED", "itemTotalPrice": {"recommendedRetailPrice": 145},
       "voucherInfo": {"url": "https://cdn.tripian.com/v/3f6c1a9e.pdf", "format": "PDF"}}]}
    """#
}
