import Foundation

/// Ticket Evolution, the calls a Victory order needs. Prices are USD.
public protocol VictoryBookingService: Sendable {
    func event(id: Int) async throws -> VictoryEvent
    /// The ticket groups on sale; this is the availability, there is no separate call.
    func listings(eventId: Int) async throws -> [VictoryTicketGroup]
    func createClient(_ buyer: VictoryBuyer) async throws -> VictoryClient
    func taxQuote(group: VictoryTicketGroup, quantity: Int) async throws -> VictoryTaxQuote
    func placeOrder(_ request: VictoryOrderRequest) async throws -> VictoryOrder
    func order(id: String) async throws -> VictoryOrder
    /// Orders placed with our own `reference`, used to find out whether an order whose answer was
    /// lost went through.
    func orders(reference: String) async throws -> [VictoryOrder]
}

/// Calls Ticket Evolution with signed requests.
///
/// Pass `authorizer: nil` with a `baseURL` pointing at the host's backend proxy to keep the secret
/// off the device; the default signs on the device with `VictoryCredentials.secret`.
public struct VictoryAPIClient: VictoryBookingService {

    private let client: ProviderHTTPClient
    private let officeId: Int?

    public init(credentials: VictoryCredentials,
                authorizer: RequestAuthorizing? = nil,
                usesDeviceSigning: Bool = true,
                transport: HTTPTransport = URLSessionHTTPTransport()) {
        let signer: RequestAuthorizing? = authorizer
            ?? (usesDeviceSigning ? VictoryRequestSigner(token: credentials.token, secret: credentials.secret) : nil)
        client = ProviderHTTPClient(baseURL: credentials.baseURL, transport: transport, authorizer: signer,
                                    errorParser: VictoryAPIClient.parseError)
        officeId = credentials.officeId
    }

    public func event(id: Int) async throws -> VictoryEvent {
        try await client.request(.get, "v9/events/\(id)")
    }

    public func listings(eventId: Int) async throws -> [VictoryTicketGroup] {
        let response: VictoryListingsResponse = try await client.request(
            .get, "v9/listings", query: [URLQueryItem(name: "event_id", value: String(eventId))])
        return response.ticketGroups
    }

    public func createClient(_ buyer: VictoryBuyer) async throws -> VictoryClient {
        let response: VictoryClientsResponse = try await client.request(
            .post, "v9/clients", body: VictoryClientRequest(buyer: buyer, officeId: officeId))
        guard let created = response.clients.first else { throw BookingError.decoding("No client was created.") }
        return created
    }

    public func taxQuote(group: VictoryTicketGroup, quantity: Int) async throws -> VictoryTaxQuote {
        try await client.request(.post, "v9/tax_quotes", body: VictoryTaxQuoteRequest(group: group, quantity: quantity))
    }

    public func placeOrder(_ request: VictoryOrderRequest) async throws -> VictoryOrder {
        let response: VictoryOrdersResponse = try await client.request(.post, "v10/orders", body: request)
        guard let order = response.orders.first else { throw BookingError.decoding("No order was returned.") }
        return order
    }

    public func order(id: String) async throws -> VictoryOrder {
        try await client.request(.get, "v9/orders/\(id)")
    }

    public func orders(reference: String) async throws -> [VictoryOrder] {
        let response: VictoryOrdersResponse = try await client.request(
            .get, "v9/orders", query: [URLQueryItem(name: "reference", value: reference)])
        return response.orders
    }

    static let parseError: ProviderHTTPClient.ErrorParser = { status, body in
        guard let error = try? JSONDecoder().decode(VictoryErrorBody.self, from: body), error.message != nil || error.error != nil else {
            return ProviderHTTPClient.genericError(status, body)
        }
        return .server(status: status, code: error.code, message: error.message ?? error.error)
    }
}
