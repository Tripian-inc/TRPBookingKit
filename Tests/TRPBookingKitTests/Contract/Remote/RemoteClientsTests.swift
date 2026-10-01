import Foundation
import XCTest
@testable import TRPBookingKit

/// The remote clients send the requests the contract fixtures record and read their answers, through a stub
/// `URLProtocol` that never reaches the network.
final class RemoteClientsTests: XCTestCase {

    private let baseURL = URL(string: "https://stub.tripian.test/tour-api")!

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testFlowsSendEveryOperationWithTheRecordedMethodPathQueryAndBody() async throws {
        let exchanges = try ContractFixtures.exchanges(in: "_synthetic/a-full-flow")
            + ContractFixtures.exchanges(in: "_synthetic/e-cancel")
            + ContractFixtures.exchanges(in: "viator")
        StubURLProtocol.answer(exchanges.map(\.response))
        let (checkout, bookings) = clients(headers: fixtureAuthHeaders(exchanges[0].request),
                                           capabilities: capabilitiesHeader(of: exchanges[0].request))

        for exchange in exchanges {
            _ = try await performContractRequest(exchange.request, checkout: checkout, bookings: bookings)
        }

        let sent = StubURLProtocol.requests
        XCTAssertEqual(sent.count, exchanges.count)
        for (request, exchange) in zip(sent, exchanges) {
            XCTAssertEqual(request.signature, exchange.request.signature, exchange.name)
            XCTAssertEqual(try canonical(request.body), try canonical(exchange.request.body), exchange.name)
        }
        let operations = Set(exchanges.map { operation(of: $0.request) })
        XCTAssertEqual(operations, ["POST /checkouts", "GET /checkouts/{id}", "POST /checkouts/{id}/steps/{stepId}",
                                    "POST /checkouts/{id}/back", "POST /checkouts/{id}/actions/{actionId}",
                                    "POST /checkouts/{id}/extend", "POST /checkouts/{id}/cancel", "GET /bookings",
                                    "GET /bookings/{uuid}", "POST /bookings/{uuid}/cancel"])
    }

    func testHeadersMatchTheRecordedOnes() async throws {
        let exchanges = try ContractFixtures.exchanges(in: "_synthetic/a-full-flow")
            + ContractFixtures.exchanges(in: "_synthetic/e-cancel")
        StubURLProtocol.answer(exchanges.map(\.response))
        let (checkout, bookings) = clients(headers: fixtureAuthHeaders(exchanges[0].request),
                                           capabilities: capabilitiesHeader(of: exchanges[0].request))

        for exchange in exchanges {
            _ = try await performContractRequest(exchange.request, checkout: checkout, bookings: bookings)
        }

        for (request, exchange) in zip(StubURLProtocol.requests, exchanges) {
            XCTAssertEqual(request.headers["Tripian-Booking-Version"], BC.version, exchange.name)
            XCTAssertEqual(request.headers["Idempotency-Key"], exchange.request.headers["Idempotency-Key"], exchange.name)
            XCTAssertEqual(request.headers["Idempotency-Key"] != nil, exchange.request.method == "POST", exchange.name)
            XCTAssertEqual(request.headers["Tripian-Client-Capabilities"] != nil,
                           exchange.request.path.hasSuffix("/checkouts"), exchange.name)
            for (name, value) in exchange.request.headers {
                XCTAssertEqual(request.headers[name], value, "\(exchange.name) \(name)")
            }
        }
    }

    func testDecoratorIsAskedPerRequestAndItsHeadersWin() async throws {
        let exchange = try ContractFixtures.exchange("viator", "10-poll")
        StubURLProtocol.answer([exchange.response, exchange.response])
        let decorator = CountingDecorator()
        let checkout = RemoteCheckoutClient(baseURL: baseURL, session: StubURLProtocol.session, decorator: decorator,
                                            capabilities: { "" })

        _ = try await checkout.get(id: "chk_01J9ZQ4M8K", lang: "en")
        _ = try await checkout.get(id: "chk_01J9ZQ4M8K", lang: "en")

        XCTAssertEqual(StubURLProtocol.requests.map { $0.headers["Authorization"] }, ["Bearer token-1", "Bearer token-2"])
        XCTAssertEqual(StubURLProtocol.requests.first?.headers["Accept"], "application/vnd.tripian+json")
    }

    func testCapabilitiesAreReadWhenTheCheckoutIsCreated() async throws {
        let exchange = try ContractFixtures.exchange("viator", "01-create")
        StubURLProtocol.answer([exchange.response])
        let capabilities = CapabilitiesBox()
        let checkout = RemoteCheckoutClient(baseURL: baseURL, session: StubURLProtocol.session,
                                            decorator: StaticContractHeaders([:]), capabilities: { capabilities.value })
        capabilities.value = "blocks=date; fields=text; actions=provider_hosted_form"

        _ = try await checkout.create(exchange.request.body!.decode(as: BC.CreateCheckoutRequest.self))

        XCTAssertEqual(StubURLProtocol.requests.first?.headers["Tripian-Client-Capabilities"],
                       "blocks=date; fields=text; actions=provider_hosted_form")
    }

    func testProcessingAnswerCarriesRetryAfter() async throws {
        let exchange = try ContractFixtures.exchange("viator", "09-payment")
        StubURLProtocol.answer([exchange.response])
        let (checkout, bookings) = clients(headers: [:], capabilities: "")

        guard case .checkout(let response) = try await performContractRequest(exchange.request, checkout: checkout,
                                                                               bookings: bookings) else {
            return XCTFail("09-payment is a checkout call")
        }

        XCTAssertEqual(response.httpStatus, 202)
        XCTAssertTrue(response.isProcessing)
        XCTAssertEqual(response.retryAfter, 2)
        XCTAssertEqual(response.checkout.status.rawValue, "processing")
    }

    func testPriceChangedIsThrownAsContractErrorWithTheCheckout() async throws {
        let exchange = try ContractFixtures.exchange("viator/errors", "PRICE_CHANGED")
        StubURLProtocol.answer([exchange.response])
        let (checkout, bookings) = clients(headers: [:], capabilities: "")

        do {
            _ = try await performContractRequest(exchange.request, checkout: checkout, bookings: bookings)
            XCTFail("PRICE_CHANGED did not throw")
        } catch let error as BC.ContractError {
            XCTAssertEqual(error.httpStatus, 409)
            XCTAssertEqual(error.code, .priceChanged)
            XCTAssertEqual(error.data.checkout?.id, "chk_01J9ZQ4M8K")
        }
    }

    func testBookingListReadsBookingsAndPagination() async throws {
        let exchange = try ContractFixtures.exchange("viator", "11-bookings")
        StubURLProtocol.answer([exchange.response])
        let bookings = RemoteBookingClient(baseURL: baseURL, session: StubURLProtocol.session,
                                           decorator: StaticContractHeaders([:]))

        let page = try await bookings.list(status: [BC.BookingStatus(decoding: "confirmed"),
                                                    BC.BookingStatus(decoding: "pending")],
                                           page: 1, limit: 20, lang: "en")

        XCTAssertEqual(StubURLProtocol.requests.first?.signature,
                       "GET /tour-api/bookings?status=confirmed,pending&page=1&limit=20&lang=en")
        XCTAssertFalse(page.bookings.isEmpty)
        XCTAssertEqual(page.bookings.first?.uuid, "3f6c1a9e-8d2b-4b7a-a1c4-5e9f0d2b7c11")
        XCTAssertNotNil(page.pagination)
    }

    func testBaseURLWithTrailingSlashAndReservedCharactersInIds() async throws {
        let exchange = try ContractFixtures.exchange("viator", "10-poll")
        StubURLProtocol.answer([exchange.response])
        let checkout = RemoteCheckoutClient(baseURL: URL(string: "https://stub.tripian.test/tour-api/")!,
                                            session: StubURLProtocol.session,
                                            decorator: StaticContractHeaders([:]), capabilities: { "" })

        _ = try await checkout.get(id: "chk_a/b c", lang: "pt-BR&x")

        XCTAssertEqual(StubURLProtocol.requests.first?.signature, "GET /tour-api/checkouts/chk_a%2Fb%20c?lang=pt-BR%26x")
    }

    func testTransportFailureIsRethrownAsURLError() async throws {
        StubURLProtocol.fail(with: URLError(.notConnectedToInternet))
        let checkout = RemoteCheckoutClient(baseURL: baseURL, session: StubURLProtocol.session,
                                            decorator: StaticContractHeaders([:]), capabilities: { "" })

        do {
            _ = try await checkout.get(id: "chk_01J9ZQ4M8K", lang: "en")
            XCTFail("an offline call did not throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }

    func testNonJSONBodyIsUndecodable() async throws {
        StubURLProtocol.answer([BC.RecordedResponse(status: 502, headers: ["Content-Type": "text/html"],
                                                    body: .string("<html>Bad gateway</html>"))])
        let bookings = RemoteBookingClient(baseURL: baseURL, session: StubURLProtocol.session,
                                           decorator: StaticContractHeaders([:]))

        do {
            _ = try await bookings.get(uuid: "3f6c1a9e-8d2b-4b7a-a1c4-5e9f0d2b7c11", lang: "en")
            XCTFail("a non-JSON body did not throw")
        } catch BC.CheckoutClientError.undecodable(let status, _) {
            XCTAssertEqual(status, 502)
        }
    }

    private func clients(headers: [String: String], capabilities: String) -> (CheckoutClient, BookingClient) {
        (RemoteCheckoutClient(baseURL: baseURL, session: StubURLProtocol.session,
                              decorator: StaticContractHeaders(headers), capabilities: { capabilities }),
         RemoteBookingClient(baseURL: baseURL, session: StubURLProtocol.session,
                             decorator: StaticContractHeaders(headers)))
    }

    private func fixtureAuthHeaders(_ request: BC.RecordedRequest) -> [String: String] {
        request.headers.filter { ["x-api-key", "Authorization"].contains($0.key) }
    }

    private func capabilitiesHeader(of request: BC.RecordedRequest) -> String {
        request.headers["Tripian-Client-Capabilities"] ?? ""
    }

    private func operation(of request: BC.RecordedRequest) -> String {
        let path = request.path.split(separator: "?")[0].split(separator: "/").dropFirst().map(String.init)
        let templates = ["checkouts": "{id}", "bookings": "{uuid}", "steps": "{stepId}", "actions": "{actionId}"]
        let templated = path.enumerated().map { index, segment -> String in
            guard index > 0, let template = templates[path[index - 1]] else { return segment }
            return template
        }
        return "\(request.method) /" + templated.joined(separator: "/")
    }

    private func canonical(_ value: BC.JSONValue?) throws -> CanonicalJSON {
        guard let value, !value.isNull else { return .null }
        return try CanonicalJSON(data: JSONEncoder().encode(value))
    }
}

/// A decorator that sends a new bearer token each time and overrides `Accept`.
private final class CountingDecorator: ContractRequestDecorating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func headers() async throws -> [String: String] {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        return ["Authorization": "Bearer token-\(current)", "Accept": "application/vnd.tripian+json"]
    }
}

/// A capabilities string changed after the client is built.
private final class CapabilitiesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""

    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// One request the stub received.
private struct StubbedRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: BC.JSONValue?

    /// `METHOD path?query`, as the fixtures record it.
    var signature: String { "\(method) \(path)" }
}

/// A `URLProtocol` that records every request and answers with the queued fixture responses in order.
private final class StubURLProtocol: URLProtocol {

    private static let lock = NSLock()
    private static var responses: [BC.RecordedResponse] = []
    private static var failure: Error?
    private static var recorded: [StubbedRequest] = []

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [StubbedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func answer(_ queued: [BC.RecordedResponse]) {
        lock.lock(); defer { lock.unlock() }
        responses = queued
    }

    static func fail(with error: Error) {
        lock.lock(); defer { lock.unlock() }
        failure = error
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responses = []
        failure = nil
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let next = Self.record(request)
        switch next {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let response):
            let body: Data
            if case .string(let text) = response.body {
                body = Data(text.utf8)
            } else {
                body = (try? JSONEncoder().encode(response.body)) ?? Data()
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                                       headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func record(_ request: URLRequest) -> Result<BC.RecordedResponse, Error> {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let body = bodyData(of: request).flatMap { try? JSONDecoder().decode(BC.JSONValue.self, from: $0) }
        let stubbed = StubbedRequest(method: request.httpMethod ?? "GET", path: path,
                                     headers: request.allHTTPHeaderFields ?? [:], body: body)
        lock.lock(); defer { lock.unlock() }
        recorded.append(stubbed)
        if let failure { return .failure(failure) }
        guard !responses.isEmpty else { return .failure(URLError(.resourceUnavailable)) }
        return .success(responses.removeFirst())
    }

    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
