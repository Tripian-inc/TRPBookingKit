import Foundation
@testable import TRPBookingKit

final class MockVictoryBookingService: VictoryBookingService, @unchecked Sendable {
    var eventResult: Result<VictoryEvent, Error>?
    var listingsResult: Result<[VictoryTicketGroup], Error>?
    var createClientResult: Result<VictoryClient, Error>?
    var taxQuoteResult: Result<VictoryTaxQuote, Error>?
    var placeOrderResult: Result<VictoryOrder, Error>?
    var orderResult: Result<VictoryOrder, Error>?
    var ordersResult: Result<[VictoryOrder], Error>?
    var eventsResult: Result<[VictoryEvent], Error>?

    var eventCallCount = 0
    var listingsCallCount = 0
    var createClientCallCount = 0
    var taxQuoteCallCount = 0
    var placeOrderCallCount = 0
    var orderCallCount = 0
    var ordersCallCount = 0
    var eventsCallCount = 0
    private(set) var eventSearches: [VictoryEventSearch] = []

    var ordersHandler: ((String) -> Result<[VictoryOrder], Error>)?

    func event(id: Int) async throws -> VictoryEvent {
        eventCallCount += 1
        return try unwrap(eventResult)
    }

    func listings(eventId: Int) async throws -> [VictoryTicketGroup] {
        listingsCallCount += 1
        return try unwrap(listingsResult)
    }

    func createClient(_ buyer: VictoryBuyer) async throws -> VictoryClient {
        createClientCallCount += 1
        return try unwrap(createClientResult)
    }

    func taxQuote(group: VictoryTicketGroup, quantity: Int) async throws -> VictoryTaxQuote {
        taxQuoteCallCount += 1
        return try unwrap(taxQuoteResult)
    }

    func placeOrder(_ request: VictoryOrderRequest) async throws -> VictoryOrder {
        placeOrderCallCount += 1
        return try unwrap(placeOrderResult)
    }

    func order(id: String) async throws -> VictoryOrder {
        orderCallCount += 1
        return try unwrap(orderResult)
    }

    func orders(reference: String) async throws -> [VictoryOrder] {
        ordersCallCount += 1
        if let ordersHandler {
            return try ordersHandler(reference).get()
        }
        return try unwrap(ordersResult)
    }

    func events(_ search: VictoryEventSearch) async throws -> [VictoryEvent] {
        eventsCallCount += 1
        eventSearches.append(search)
        return try unwrap(eventsResult)
    }

    private func unwrap<T>(_ result: Result<T, Error>?) throws -> T {
        guard let result else { throw BookingError.transport("mock result not stubbed") }
        return try result.get()
    }
}
