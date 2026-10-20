import Foundation
import XCTest
@testable import TRPBookingKit

/// The local clients answer the Ticket Evolution fixtures from a mocked TE service and a mocked Braintree.
///
/// Excluded fixture paths, which the local flow cannot produce from what TE returns:
/// - `03-quantity` `currentStep.blocks[0].lines[2].detail`: a TE tax quote carries an amount, not the name of the tax.
final class LocalVictoryContractTests: XCTestCase {
    private let directory = "victory"
    private var clock: TestClock!
    private var service: MockVictoryBookingService!
    private var braintree: MockBraintreeClientToken!
    private var store: InMemoryBookingRecordStore!
    private var checkout: LocalCheckoutClient!
    private var bookings: LocalBookingClient!

    private static let flow = ["01-create", "02-group", "03-quantity", "04-summary", "05-buyer", "06-payment"]
    private static let exclusions = ["03-quantity": ["currentStep.blocks[0].lines[2].detail"]]

    override func setUp() async throws {
        clock = TestClock(ISO8601DateFormatter().date(from: "2026-10-02T16:05:00Z")!)
        service = MockVictoryBookingService()
        service.eventResult = .success(try decodeJSON(VictoryEvent.self, """
            {"id": 2817364, "name": "Hamilton", "occurs_at": "2026-10-15T23:00:00Z", "occurs_at_local": "2026-10-15T19:00:00",
             "venue": {"name": "Richard Rodgers Theatre", "time_zone": "America/New_York",
                       "address": {"latitude": 40.759, "longitude": -73.9866}}}
            """))
        service.listingsResult = .success(try Self.groups(mezzanineAvailable: 6))
        service.taxQuoteResult = .success(try decodeJSON(VictoryTaxQuote.self, """
            {"tax_quote": {"id": 7741, "signature": "sig_7741", "retail_tax_amount": 7.70, "expires_at": "2026-10-02T16:18:00Z"}}
            """))
        service.createClientResult = .success(try decodeJSON(VictoryClient.self,
                                                             #"{"id":1,"email_addresses":[{"id":2}],"addresses":[{"id":3}]}"#))
        service.placeOrderResult = .success(try decodeJSON(VictoryOrder.self, #"{"id":"TE-ORD-5531902","state":"pending","total":212.40}"#))
        braintree = MockBraintreeClientToken()
        store = InMemoryBookingRecordStore()
        let now: @Sendable () -> Date = { [clock] in clock!.now }
        let victory = VictoryCheckout(service: service, store: store, backgroundTasks: ImmediateTaskRunner(), statusAttempts: 1,
                                      retryDelay: 0, now: now)
        let product = LocalProduct(
            id: "TEVO-2817364", provider: .victory, providerProductId: "2817364", title: "Hamilton on Broadway",
            imageUrl: "https://cdn.tripian.com/p/TEVO-2817364.jpg", timeZone: TimeZone(identifier: "America/New_York")!,
            durationMinutes: 165,
            meetingPoint: .init(name: "Richard Rodgers Theatre", address: "226 W 46th St, New York, NY 10036",
                                lat: 40.759, lng: -73.9866))
        checkout = LocalCheckoutClient(viator: nil, victory: victory, braintree: braintree, store: store,
                                       catalog: StaticProductCatalog([product]), fallbackWebBase: "https://book.tripian.com/c/",
                                       identifiers: .sequence(["chk_01J9ZV3R6Q", "act_01J9ZV9K"]), now: now)
        bookings = LocalBookingClient(store: store, viator: nil, toristy: nil, contractVersion: BookingContract.version, now: now)
    }

    private func replay(_ names: ArraySlice<String>) async throws {
        for name in names {
            try await assertLocalSnapshot(directory, name, checkout: checkout, bookings: bookings, excluding: Self.exclusions[name] ?? [])
        }
    }

    func testHappyPath() async throws {
        try await replay(Self.flow[...])
        try await assertLocalSnapshot(directory, "07-booking", checkout: checkout, bookings: bookings)
        XCTAssertEqual(service.placeOrderCallCount, 1)
    }

    func testSoldOutSendsTheCustomerBackToTheSeats() async throws {
        try await replay(Self.flow[0..<2])
        service.listingsResult = .success(try Self.groups(mezzanineAvailable: 0))
        try await assertLocalSnapshot("victory/errors", "SOLD_OUT", checkout: checkout, bookings: bookings)
        XCTAssertEqual(service.taxQuoteCallCount, 0)
    }

    func testABookedOrderIsNotCancellable() async throws {
        try await replay(Self.flow[...])
        try await assertLocalSnapshot("victory/errors", "NOT_CANCELLABLE", checkout: checkout, bookings: bookings)
    }

    func testCanceledPaymentLeavesCheckoutUnchanged() async throws {
        try await replay(Self.flow[0..<5])
        let recordsBefore = await store.all().map(\.status)
        let response = try await checkout.action(checkoutId: "chk_01J9ZV3R6Q", actionId: "act_01J9ZV9K",
                                                 result: BookingContract.ActionResult(status: .init(.canceled)), lang: "en")
        XCTAssertEqual(response.checkout.status.value, .awaitingPayment)
        XCTAssertEqual(response.checkout.nextAction?.id, "act_01J9ZV9K")
        XCTAssertEqual(response.checkout.allowedActions.map(\.value), [.back, .cancel])
        XCTAssertEqual(braintree.callCount, 1)
        XCTAssertEqual(service.placeOrderCallCount, 0)
        let recordsAfter = await store.all().map(\.status)
        XCTAssertEqual(recordsAfter, recordsBefore)
    }

    func testBackFromAwaitingPaymentShowsBuyerAndKeepsQuote() async throws {
        try await replay(Self.flow[0..<5])
        let quotes = service.taxQuoteCallCount
        let back = try await checkout.back(checkoutId: "chk_01J9ZV3R6Q", fromStepId: "buyer", lang: "en")
        XCTAssertEqual(back.checkout.status.value, .collectingDetails)
        XCTAssertEqual(back.checkout.currentStep?.id, "buyer")
        XCTAssertNil(back.checkout.nextAction)
        XCTAssertTrue(back.checkout.allowedActions.contains { $0.value == .submit })
        let resubmitted = try await checkout.submit(checkoutId: "chk_01J9ZV3R6Q", stepId: "buyer", answers: Self.buyerAnswers, lang: "en")
        XCTAssertEqual(resubmitted.checkout.status.value, .awaitingPayment)
        XCTAssertNotNil(resubmitted.checkout.nextAction)
        XCTAssertEqual(service.taxQuoteCallCount, quotes)
        XCTAssertEqual(service.placeOrderCallCount, 0)
    }

    func testBackFromAwaitingPaymentRejectsOtherStep() async throws {
        try await replay(Self.flow[0..<5])
        do {
            _ = try await checkout.back(checkoutId: "chk_01J9ZV3R6Q", fromStepId: "summary", lang: "en")
            XCTFail("Expected STEP_MISMATCH")
        } catch let error as BookingContract.ContractError {
            XCTAssertEqual(error.data.code.value, .stepMismatch)
        }
    }

    private static let buyerAnswers: BookingContract.Answers = [
        "buyer.firstName": "Maya", "buyer.lastName": "Brooks", "buyer.email": "maya@example.com", "buyer.phone": "+12125550143",
        "billing.address1": "350 W 50th St", "billing.city": "New York", "billing.postalCode": "10019", "billing.country": "US",
        "billing.state": "NY", "terms": true
    ]

    /// The event's three groups; the rear mezzanine never has seats, the mezzanine has `mezzanineAvailable`.
    private static func groups(mezzanineAvailable: Int) throws -> [VictoryTicketGroup] {
        try [
            group(id: 88121, section: "Orchestra", row: "K", retail: "129.00", available: 4, splits: [2, 4]),
            group(id: 88122, section: "Mezzanine", row: "C", retail: "89.00", available: mezzanineAvailable,
                  splits: mezzanineAvailable > 0 ? [2, 4, 6] : []),
            group(id: 88123, section: "Rear Mezzanine", row: "M", retail: "59.00", available: 0, splits: [])
        ]
    }

    private static func group(id: Int, section: String, row: String, retail: String, available: Int, splits: [Int]) throws
        -> VictoryTicketGroup {
        try decodeJSON(VictoryTicketGroup.self, """
            {"id": \(id), "section": "\(section)", "row": "\(row)", "quantity": \(available), "available_quantity": \(available),
             "splits": \(splits), "retail_price": \(retail), "wholesale_price": 80.00, "service_fee": 26.70,
             "format": "Eticket", "eticket": true, "instant_delivery": true}
            """)
    }
}

/// A Braintree that hands out one fixed client token.
final class MockBraintreeClientToken: BraintreeClientTokenProviding, @unchecked Sendable {
    var callCount = 0

    func clientToken() async throws -> String {
        callCount += 1
        return "bt_ct_sandbox_6xk2p9q4z8m1"
    }
}
