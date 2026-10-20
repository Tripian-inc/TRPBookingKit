import XCTest
@testable import TRPBookingKit

/// Toristy takes its key as a url query parameter and rejects it in a header; Viator is the opposite.
final class ToristyAPIClientAuthorizationTests: XCTestCase {

    private func queryItems(_ request: URLRequest) -> [URLQueryItem] {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    func testBookingInformationCarriesTheApiKeyInTheQueryAndNoApiKeyHeader() async throws {
        let transport = RecordingHTTPTransport()
        transport.body = Data(#"{"serviceid": 1}"#.utf8)
        let client = ToristyAPIClient(credentials: ToristyCredentials(apiKey: "tor-secret"), transport: transport)

        _ = try await client.bookingInformation(serviceId: 48213, currency: "eur")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertTrue(queryItems(request).contains(URLQueryItem(name: "apikey", value: "tor-secret")))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
        XCTAssertTrue(queryItems(request).contains(URLQueryItem(name: "currency", value: "EUR")))
    }

    func testBookingConfirmationCarriesTheApiKeyAlongsideTheCartQuery() async throws {
        let transport = RecordingHTTPTransport()
        let client = ToristyAPIClient(credentials: ToristyCredentials(apiKey: "tor-secret"), transport: transport)
        let reference = BookingReference(provider: .toristy, primary: "cart1", secondary: "conf1")
        let receipt = PaymentReceipt(chargeId: "ch1", amount: 10, currency: "EUR", cardBrand: "Visa", last4: "4242", paidAt: Date())

        try await client.confirm(reference, receipt: receipt, amount: 10, currency: "EUR")

        let request = try XCTUnwrap(transport.requests.first)
        let items = Set(queryItems(request))
        XCTAssertTrue(items.contains(URLQueryItem(name: "apikey", value: "tor-secret")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "cartid", value: "cart1")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "confirmationCode", value: "conf1")))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
    }

    func testViatorAPIClientStillAuthorizesWithAHeaderAndSendsNoApikeyQuery() async throws {
        let transport = RecordingHTTPTransport()
        transport.body = Data(#"{"bookingId": "B1", "status": "ACCEPTED"}"#.utf8)
        let credentials = ViatorCredentials(apiKey: "via-secret", environment: .sandbox,
                                            paymentPageURL: URL(string: "https://book.tripian.com/viator")!, subChannelId: "sub1")
        let client = ViatorAPIClient(credentials: credentials, languageCode: "en", transport: transport)

        _ = try await client.cancel(bookingRef: "B1")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "exp-api-key"), "via-secret")
        XCTAssertFalse(queryItems(request).contains { $0.name == "apikey" })
    }
}
