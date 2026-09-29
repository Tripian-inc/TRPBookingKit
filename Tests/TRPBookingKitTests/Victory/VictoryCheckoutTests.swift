import XCTest
@testable import TRPBookingKit

final class VictoryCheckoutTests: XCTestCase {

    private func makeGroup(id: Int, retailPrice: Decimal?, wholesalePrice: Decimal?, serviceFee: Decimal = 0,
                           splits: [Int] = [1], available: Int = 10, eticket: Bool = true) throws -> VictoryTicketGroup {
        var json: [String: Any] = ["id": id, "quantity": available, "splits": splits, "available_quantity": available, "eticket": eticket]
        if let retailPrice { json["retail_price"] = NSDecimalNumber(decimal: retailPrice).doubleValue }
        if let wholesalePrice { json["wholesale_price"] = NSDecimalNumber(decimal: wholesalePrice).doubleValue }
        if serviceFee != 0 { json["service_fee"] = NSDecimalNumber(decimal: serviceFee).doubleValue }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(VictoryTicketGroup.self, from: data)
    }

    private func makeBuyer() -> VictoryBuyer {
        VictoryBuyer(name: "Jane Doe", email: "jane@example.com",
                    billingAddress: VictoryBuyer.Address(streetAddress: "1 Main St", locality: "Springfield",
                                                         postalCode: "00000", countryCode: "us"))
    }

    private func makeClient() throws -> VictoryClient {
        try decodeJSON(VictoryClient.self, #"{"id":1,"email_addresses":[{"id":2}],"addresses":[{"id":3}]}"#)
    }

    private func makeOrder(id: String, state: String, total: Decimal = 115) throws -> VictoryOrder {
        try decodeJSON(VictoryOrder.self, "{\"id\":\"\(id)\",\"state\":\"\(state)\",\"total\":\(total)}")
    }

    // MARK: - offers

    func testOffersKeepsOnlySellableDigitalGroupsSortedByRetailPrice() async throws {
        let service = MockVictoryBookingService()
        service.eventResult = .success(try decodeJSON(VictoryEvent.self, "{\"id\":1}"))
        let notSellable = try makeGroup(id: 1, retailPrice: 10, wholesalePrice: 5, splits: [])
        let noPrice = try makeGroup(id: 2, retailPrice: nil, wholesalePrice: 5)
        let physical = try makeGroup(id: 3, retailPrice: 20, wholesalePrice: 10, eticket: false)
        let cheap = try makeGroup(id: 4, retailPrice: 15, wholesalePrice: 8)
        let expensive = try makeGroup(id: 5, retailPrice: 30, wholesalePrice: 20)
        service.listingsResult = .success([notSellable, noPrice, physical, expensive, cheap])
        let checkout = VictoryCheckout(service: service, store: InMemoryBookingRecordStore(), backgroundTasks: ImmediateTaskRunner())

        let offers = try await checkout.offers(eventId: 1)

        XCTAssertEqual(offers.ticketGroups.map(\.id), [4, 5])
    }

    func testOffersIncludesPhysicalGroupsWhenDigitalOnlyIsFalse() async throws {
        let service = MockVictoryBookingService()
        service.eventResult = .success(try decodeJSON(VictoryEvent.self, "{\"id\":1}"))
        let physical = try makeGroup(id: 3, retailPrice: 20, wholesalePrice: 10, eticket: false)
        service.listingsResult = .success([physical])
        let checkout = VictoryCheckout(service: service, store: InMemoryBookingRecordStore(),
                                       backgroundTasks: ImmediateTaskRunner(), digitalOnly: false)

        let offers = try await checkout.offers(eventId: 1)

        XCTAssertEqual(offers.ticketGroups.map(\.id), [3])
    }

    // MARK: - quote

    func testQuoteThrowsInvalidSelectionForAQuantityNotSellable() async throws {
        let service = MockVictoryBookingService()
        let group = try makeGroup(id: 1, retailPrice: 10, wholesalePrice: 5, splits: [2, 4])
        let checkout = VictoryCheckout(service: service, store: InMemoryBookingRecordStore(), backgroundTasks: ImmediateTaskRunner())

        do {
            _ = try await checkout.quote(eventId: 1, group: group, quantity: 3)
            XCTFail("Expected an error")
        } catch BookingError.invalidSelection {
            // expected
        }
    }

    func testQuoteDropsAnUnusableTaxQuoteAndChargesNoTax() async throws {
        let service = MockVictoryBookingService()
        let group = try makeGroup(id: 1, retailPrice: 100, wholesalePrice: 80, serviceFee: 5, splits: [1])
        service.taxQuoteResult = .success(try decodeJSON(VictoryTaxQuote.self, #"{"retail_tax_amount": 10}"#))
        let checkout = VictoryCheckout(service: service, store: InMemoryBookingRecordStore(), backgroundTasks: ImmediateTaskRunner())

        let quote = try await checkout.quote(eventId: 1, group: group, quantity: 1)

        XCTAssertNil(quote.taxQuote)
        XCTAssertEqual(quote.tax, 0)
        XCTAssertEqual(quote.total, 105)
    }

    // MARK: - order: success

    func testOrderSuccessChargesTheNonceAndSavesAConfirmedRecord() async throws {
        let service = MockVictoryBookingService()
        let group = try makeGroup(id: 1, retailPrice: 100, wholesalePrice: 80, serviceFee: 5, splits: [1])
        service.taxQuoteResult = .success(try decodeJSON(
            VictoryTaxQuote.self, #"{"signature":"sig","retail_tax_amount":10,"expires_at":"2099-01-01T00:00:00Z"}"#
        ))
        service.createClientResult = .success(try makeClient())
        service.placeOrderResult = .success(try makeOrder(id: "order-1", state: "accepted", total: 115))
        let store = InMemoryBookingRecordStore()
        let checkout = VictoryCheckout(service: service, store: store, backgroundTasks: ImmediateTaskRunner())
        let nonceProvider = MockPaymentNonceProviding()

        let quote = try await checkout.quote(eventId: 1, group: group, quantity: 1)
        let outcome = try await checkout.order(quote, buyer: makeBuyer(), eventDate: nil,
                                                activityId: "C_1_2", title: "Concert", payment: nonceProvider)

        XCTAssertEqual(outcome.order.id, "order-1")
        XCTAssertEqual(outcome.reference.secondary, "order-1")
        XCTAssertEqual(nonceProvider.lastAmount, 115)
        XCTAssertEqual(nonceProvider.lastCurrency, "USD")
        let records = await store.all()
        XCTAssertEqual(records.first?.status, .confirmed)
    }

    // MARK: - order: permanent failure

    func testOrderMarksTheRecordFailedOnAPermanentServerError() async throws {
        let service = MockVictoryBookingService()
        let group = try makeGroup(id: 1, retailPrice: 100, wholesalePrice: 80, splits: [1])
        service.taxQuoteResult = .success(try decodeJSON(VictoryTaxQuote.self, "{}"))
        service.createClientResult = .success(try makeClient())
        service.placeOrderResult = .failure(BookingError.server(status: 422, code: nil, message: "Unprocessable"))
        let store = InMemoryBookingRecordStore()
        let checkout = VictoryCheckout(service: service, store: store, backgroundTasks: ImmediateTaskRunner())
        let nonceProvider = MockPaymentNonceProviding()

        let quote = try await checkout.quote(eventId: 1, group: group, quantity: 1)
        do {
            _ = try await checkout.order(quote, buyer: makeBuyer(), eventDate: nil,
                                         activityId: "C_1_2", title: "Concert", payment: nonceProvider)
            XCTFail("Expected an error")
        } catch BookingError.server(let status, _, _) {
            XCTAssertEqual(status, 422)
        }

        let records = await store.all()
        XCTAssertEqual(records.first?.status, .failed)
    }

    // MARK: - order: transport failure recovered by probe

    func testOrderRecoversViaProbeWhenPlacingTheOrderFailsButTheOrderWentThrough() async throws {
        let service = MockVictoryBookingService()
        let group = try makeGroup(id: 1, retailPrice: 100, wholesalePrice: 80, splits: [1])
        service.taxQuoteResult = .success(try decodeJSON(VictoryTaxQuote.self, "{}"))
        service.createClientResult = .success(try makeClient())
        service.placeOrderResult = .failure(BookingError.transport("dropped"))
        service.ordersResult = .success([try makeOrder(id: "order-1", state: "accepted", total: 100)])
        let store = InMemoryBookingRecordStore()
        let checkout = VictoryCheckout(service: service, store: store, backgroundTasks: ImmediateTaskRunner(),
                                       statusAttempts: 2, retryDelay: 0)
        let nonceProvider = MockPaymentNonceProviding()

        let quote = try await checkout.quote(eventId: 1, group: group, quantity: 1)
        let outcome = try await checkout.order(quote, buyer: makeBuyer(), eventDate: nil,
                                               activityId: "C_1_2", title: "Concert", payment: nonceProvider)

        XCTAssertEqual(outcome.order.id, "order-1")
        let records = await store.all()
        XCTAssertEqual(records.first?.status, .confirmed)
    }

    func testOrderThrowsOutcomeUnknownWhenTheProbeNeverFindsTheOrder() async throws {
        let service = MockVictoryBookingService()
        let group = try makeGroup(id: 1, retailPrice: 100, wholesalePrice: 80, splits: [1])
        service.taxQuoteResult = .success(try decodeJSON(VictoryTaxQuote.self, "{}"))
        service.createClientResult = .success(try makeClient())
        service.placeOrderResult = .failure(BookingError.transport("dropped"))
        service.ordersResult = .failure(BookingError.transport("still down"))
        let store = InMemoryBookingRecordStore()
        let checkout = VictoryCheckout(service: service, store: store, backgroundTasks: ImmediateTaskRunner(),
                                       statusAttempts: 2, retryDelay: 0)
        let nonceProvider = MockPaymentNonceProviding()

        let quote = try await checkout.quote(eventId: 1, group: group, quantity: 1)
        do {
            _ = try await checkout.order(quote, buyer: makeBuyer(), eventDate: nil,
                                         activityId: "C_1_2", title: "Concert", payment: nonceProvider)
            XCTFail("Expected an error")
        } catch BookingError.outcomeUnknown {
            // expected
        }

        let records = await store.all()
        XCTAssertEqual(records.first?.status, .charged)
    }

    // MARK: - order: rejected/cancelled order state

    func testOrderThrowsRejectedWhenTheOrderWasPlacedButRejected() async throws {
        let service = MockVictoryBookingService()
        let group = try makeGroup(id: 1, retailPrice: 100, wholesalePrice: 80, splits: [1])
        service.taxQuoteResult = .success(try decodeJSON(VictoryTaxQuote.self, "{}"))
        service.createClientResult = .success(try makeClient())
        service.placeOrderResult = .success(try makeOrder(id: "order-1", state: "rejected"))
        let store = InMemoryBookingRecordStore()
        let checkout = VictoryCheckout(service: service, store: store, backgroundTasks: ImmediateTaskRunner())
        let nonceProvider = MockPaymentNonceProviding()

        let quote = try await checkout.quote(eventId: 1, group: group, quantity: 1)
        do {
            _ = try await checkout.order(quote, buyer: makeBuyer(), eventDate: nil,
                                         activityId: "C_1_2", title: "Concert", payment: nonceProvider)
            XCTFail("Expected an error")
        } catch BookingError.rejected {
            // expected
        }

        let records = await store.all()
        XCTAssertEqual(records.first?.status, .failed)
    }

    // MARK: - order: expired tax quote, price changed

    func testOrderThrowsRejectedWhenAnExpiredTaxQuoteRefreshesToADifferentTotal() async throws {
        let service = MockVictoryBookingService()
        let group = try makeGroup(id: 1, retailPrice: 100, wholesalePrice: 80, splits: [1])
        service.taxQuoteResult = .success(try decodeJSON(
            VictoryTaxQuote.self, #"{"signature":"sig","retail_tax_amount":10,"expires_at":"2020-01-01T00:00:00Z"}"#
        ))
        let store = InMemoryBookingRecordStore()
        let checkout = VictoryCheckout(service: service, store: store, backgroundTasks: ImmediateTaskRunner(),
                                       now: { ISO8601.date(from: "2026-01-01T00:00:00Z")! })
        let nonceProvider = MockPaymentNonceProviding()

        let quote = try await checkout.quote(eventId: 1, group: group, quantity: 1)
        service.taxQuoteResult = .success(try decodeJSON(
            VictoryTaxQuote.self, #"{"signature":"sig","retail_tax_amount":20,"expires_at":"2099-01-01T00:00:00Z"}"#
        ))

        do {
            _ = try await checkout.order(quote, buyer: makeBuyer(), eventDate: nil,
                                         activityId: "C_1_2", title: "Concert", payment: nonceProvider)
            XCTFail("Expected an error")
        } catch BookingError.rejected {
            // expected
        }

        XCTAssertEqual(service.placeOrderCallCount, 0)
        XCTAssertEqual(nonceProvider.nonceCallCount, 0)
    }
}
