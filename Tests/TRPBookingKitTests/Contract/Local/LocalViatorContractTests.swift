import Foundation
import XCTest
@testable import TRPBookingKit

/// The local clients answer the Viator fixtures from a mocked Viator service.
final class LocalViatorContractTests: XCTestCase {
    private let directory = "viator"
    private let now = ISO8601DateFormatter().date(from: "2026-10-02T14:05:00Z")!
    private var service: MockViatorBookingService!
    private var store: InMemoryBookingRecordStore!
    private var checkout: LocalCheckoutClient!
    private var bookings: LocalBookingClient!

    private static let flow = ["01-create", "02-date", "03-travelers", "04-option", "05-details", "06-back",
                               "07-details-again", "08-summary", "09-payment", "10-poll"]
    private static let optionExclusions = ["currentStep.blocks[0].options[2].badge"]
    private static let bookingExclusions = ["vouchers[1]"]

    override func setUp() async throws {
        service = MockViatorBookingService()
        service.productResult = .success(try decodeJSON(ViatorProduct.self, Self.productJSON))
        service.scheduleResult = .success(try decodeJSON(ViatorSchedule.self, Self.scheduleJSON))
        service.locationsResult = .success([try decodeJSON(ViatorLocation.self, #"{"reference": "hotel_123", "name": "Hotel Arts Barcelona"}"#)])
        service.bookingQuestionsResult = .success(try decodeJSON([ViatorBookingQuestion].self, #"""
        [{"id": "PICKUP_POINT", "type": "LOCATION_REF_OR_FREE_TEXT", "group": "PER_BOOKING", "required": "OPTIONAL",
          "units": ["LOCATION_REFERENCE", "FREETEXT"], "label": "Pickup location"}]
        """#))
        service.availabilityResult = .success(try decodeJSON(ViatorAvailability.self, Self.availabilityJSON))
        service.holdResult = .success(try decodeJSON(ViatorHold.self, Self.holdJSON(token: "vps_7Hq2LmN9xR4tB8wK")))
        service.bookResult = .success(try decodeJSON(ViatorBookResult.self, Self.bookJSON))
        store = InMemoryBookingRecordStore()
        makeClients(version: BookingContract.version)
    }

    private func makeClients(version: String) {
        let clock = now
        let viator = ViatorCheckout(service: service, store: store, backgroundTasks: ImmediateTaskRunner(),
                                    maximumHolds: 2, statusAttempts: 1, retryDelay: 0, now: { clock })
        let product = LocalProduct(
            id: "5010BCN_SAGRADA", provider: .viator, providerProductId: "5010BCN_SAGRADA", title: "Sagrada Família guided tour",
            imageUrl: "https://cdn.tripian.com/p/5010BCN_SAGRADA.jpg", timeZone: TimeZone(identifier: "Europe/Madrid")!,
            meetingPoint: .init(name: "Sagrada Família, Carrer de la Marina entrance", address: "Carrer de Mallorca 401, 08013 Barcelona",
                                lat: 41.4036, lng: 2.1744),
            optionDurationMinutes: ["TG1": 90, "TG2": 120])
        checkout = LocalCheckoutClient(viator: viator, store: store, catalog: StaticProductCatalog([product]), contractVersion: version,
                                       fallbackWebBase: "https://book.tripian.com/c/",
                                       identifiers: .sequence(["chk_01J9ZQ4M8K", "act_01J9ZR2B", "act_01J9ZR3C"]),
                                       processingWait: 0.05, now: { clock })
        bookings = LocalBookingClient(store: store, viator: viator, toristy: nil, contractVersion: version, now: { clock })
    }

    private func replay(_ names: ArraySlice<String>) async throws {
        for name in names {
            if name == "09-payment" { service.bookDelay = 0.3 }
            if name == "10-poll" { try await Task.sleep(nanoseconds: 500_000_000) }
            try await assertLocalSnapshot(directory, name, checkout: checkout, bookings: bookings,
                                          excluding: name == "03-travelers" ? Self.optionExclusions : [])
        }
    }

    func testHappyPathIncludingBack() async throws {
        try await replay(Self.flow[...])
        for name in ["11-bookings", "12-booking"] {
            try await assertLocalSnapshot(directory, name, checkout: checkout, bookings: bookings,
                                          excluding: name == "11-bookings" ? ["[*].vouchers[1]"] : Self.bookingExclusions)
        }
    }

    func testStepMismatch() async throws {
        try await replay(Self.flow[0..<2])
        try await assertLocalSnapshot("viator/errors", "STEP_MISMATCH", checkout: checkout, bookings: bookings)
    }

    func testValidation() async throws {
        try await replay(Self.flow[0..<4])
        try await assertLocalSnapshot("viator/errors", "VALIDATION", checkout: checkout, bookings: bookings)
    }

    func testSupplierUnavailable() async throws {
        try await replay(Self.flow[0..<4])
        service.holdResult = .failure(BookingError.transport("timed out"))
        try await assertLocalSnapshot("viator/errors", "SUPPLIER_UNAVAILABLE", checkout: checkout, bookings: bookings)
    }

    func testPaymentDeclined() async throws {
        try await replay(Self.flow[0..<8])
        service.bookResult = .failure(BookingError.server(status: 402, code: "PAYMENT_DECLINED", message: nil))
        service.holdResult = .success(try decodeJSON(ViatorHold.self, Self.holdJSON(token: "vps_2Pd6JsV0cY5nE1uG")))
        try await assertLocalSnapshot("viator/errors", "PAYMENT_DECLINED", checkout: checkout, bookings: bookings)
    }

    func testVersionUnsupported() async throws {
        makeClients(version: "2025-06-01")
        try await assertLocalSnapshot("viator/errors", "VERSION_UNSUPPORTED", checkout: checkout, bookings: bookings)
    }

    private static let productJSON = #"""
    {"productCode": "5010BCN_SAGRADA", "title": "Sagrada Família guided tour", "timeZone": "Europe/Madrid", "bookingQuestions": ["PICKUP_POINT"],
     "pricingInfo": {"ageBands": [
       {"ageBand": "ADULT", "startAge": 13, "endAge": 99, "minTravelersPerBooking": 1, "maxTravelersPerBooking": 9},
       {"ageBand": "CHILD", "startAge": 4, "endAge": 12, "minTravelersPerBooking": 0, "maxTravelersPerBooking": 9}]},
     "bookingRequirements": {"minTravelersPerBooking": 1, "maxTravelersPerBooking": 9},
     "productOptions": [{"productOptionCode": "TG1", "title": "Guided tour in English"},
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

    private static func holdJSON(token: String) -> String {
        #"""
        {"cartRef": "cart-1", "currency": "EUR", "paymentSessionToken": "\#(token)",
         "items": [{"bookingRef": "BR-1122334455", "status": "BOOKABLE", "itemTotalPrice": {"recommendedRetailPrice": 145},
           "bookingHoldInfo": {"availability": {"validUntil": "2026-10-02T14:20:00Z"}, "pricing": {"validUntil": "2026-10-02T14:20:00Z"}}}]}
        """#
    }

    private static let bookJSON = #"""
    {"cartRef": "cart-1", "currency": "EUR",
     "items": [{"bookingRef": "BR-1122334455", "status": "CONFIRMED", "itemTotalPrice": {"recommendedRetailPrice": 145},
       "voucherInfo": {"url": "https://cdn.tripian.com/v/3f6c1a9e.pdf", "format": "PDF"}}]}
    """#
}
