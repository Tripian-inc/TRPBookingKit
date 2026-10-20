import XCTest
@testable import TRPBookingKit

final class VictoryAPIClientEventsTests: XCTestCase {

    private func makeClient(transport: RecordingHTTPTransport) -> VictoryAPIClient {
        let credentials = VictoryCredentials(token: "tok", secret: "sekret", environment: .sandbox)
        return VictoryAPIClient(credentials: credentials, transport: transport)
    }

    private static let from = ISO8601.date(from: "2026-10-15T00:00:00Z")!
    private static let to = ISO8601.date(from: "2026-10-16T00:00:00Z")!

    func testEventsRequestsTheV9EventsPathWithASortedSignedQuery() async throws {
        let transport = RecordingHTTPTransport()
        transport.body = Data(#"{"events":[]}"#.utf8)
        let client = makeClient(transport: transport)
        let search = VictoryEventSearch(latitude: 40.7, longitude: -73.9, from: Self.from, to: Self.to, categoryId: 7, perPage: 20)

        _ = try await client.events(search)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v9/events")
        let query = try XCTUnwrap(request.url?.query)
        XCTAssertEqual(query, "category_id=7&lat=40.700000&lon=-73.900000&occurs_at.gte=2026-10-15T00:00:00Z&occurs_at.lt=2026-10-16T00:00:00Z&per_page=20")
    }

    func testEventsSignsTheSentRequestExactlyAsVictoryRequestSignerWould() async throws {
        let transport = RecordingHTTPTransport()
        transport.body = Data(#"{"events":[]}"#.utf8)
        let client = makeClient(transport: transport)
        let search = VictoryEventSearch(latitude: 40.7, longitude: -73.9, from: Self.from, to: Self.to, categoryId: 7, perPage: 20)

        _ = try await client.events(search)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Token"), "tok")
        let canonical = "GET api.sandbox.ticketevolution.com/v9/events?category_id=7&lat=40.700000&lon=-73.900000"
            + "&occurs_at.gte=2026-10-15T00:00:00Z&occurs_at.lt=2026-10-16T00:00:00Z&per_page=20"
        XCTAssertEqual(try VictoryRequestSigner.signatureString(for: request), canonical)
        let expectedSignature = VictoryRequestSigner(token: "tok", secret: "sekret").signature(of: canonical)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Signature"), expectedSignature)
    }

    func testEventsOmitsCategoryIdFromTheQueryWhenNotGiven() async throws {
        let transport = RecordingHTTPTransport()
        transport.body = Data(#"{"events":[]}"#.utf8)
        let client = makeClient(transport: transport)
        let search = VictoryEventSearch(latitude: 40.7, longitude: -73.9, from: Self.from, to: Self.to)

        _ = try await client.events(search)

        let query = try XCTUnwrap(transport.requests.first?.url?.query)
        XCTAssertFalse(query.contains("category_id"))
    }

    func testEventsDefaultsPerPageToOneHundred() async throws {
        let transport = RecordingHTTPTransport()
        transport.body = Data(#"{"events":[]}"#.utf8)
        let client = makeClient(transport: transport)
        let search = VictoryEventSearch(latitude: 40.7, longitude: -73.9, from: Self.from, to: Self.to)

        _ = try await client.events(search)

        let query = try XCTUnwrap(transport.requests.first?.url?.query)
        XCTAssertTrue(query.contains("per_page=100"))
    }

    func testCoordinateNeverUsesExponentForm() {
        XCTAssertEqual(VictoryEventSearch.coordinate(0.0000001), "0.000000")
        XCTAssertEqual(VictoryEventSearch.coordinate(-0.0000001), "-0.000000")
        XCTAssertEqual(VictoryEventSearch.coordinate(123456789.123456), "123456789.123456")
        XCTAssertEqual(VictoryEventSearch.coordinate(-73.9866), "-73.986600")
    }

    func testEventsReturnsTheDecodedEventsFromTheResponse() async throws {
        let transport = RecordingHTTPTransport()
        transport.body = Data(#"{"events":[{"id":2817364,"name":"Hamilton"}]}"#.utf8)
        let client = makeClient(transport: transport)
        let search = VictoryEventSearch(latitude: 40.7, longitude: -73.9, from: Self.from, to: Self.to)

        let events = try await client.events(search)

        XCTAssertEqual(events.map(\.id), [2817364])
    }
}

/// A service that never overrides the protocol's default `events(_:)`, pinning its fallback behaviour.
private struct EventlessVictoryBookingService: VictoryBookingService {
    func event(id: Int) async throws -> VictoryEvent { throw BookingError.transport("unused") }
    func listings(eventId: Int) async throws -> [VictoryTicketGroup] { [] }
    func createClient(_ buyer: VictoryBuyer) async throws -> VictoryClient { throw BookingError.transport("unused") }
    func taxQuote(group: VictoryTicketGroup, quantity: Int) async throws -> VictoryTaxQuote { throw BookingError.transport("unused") }
    func placeOrder(_ request: VictoryOrderRequest) async throws -> VictoryOrder { throw BookingError.transport("unused") }
    func order(id: String) async throws -> VictoryOrder { throw BookingError.transport("unused") }
    func orders(reference: String) async throws -> [VictoryOrder] { [] }
}

final class VictoryBookingServiceDefaultEventsTests: XCTestCase {

    func testTheDefaultEventsImplementationThrowsProviderNotConfigured() async throws {
        let service = EventlessVictoryBookingService()
        let search = VictoryEventSearch(latitude: 0, longitude: 0, from: Date(), to: Date())

        do {
            _ = try await service.events(search)
            XCTFail("Expected providerNotConfigured")
        } catch let error as BookingError {
            guard case .providerNotConfigured(let provider) = error else {
                return XCTFail("Expected providerNotConfigured, got \(error)")
            }
            XCTAssertEqual(provider, .victory)
        }
    }
}
