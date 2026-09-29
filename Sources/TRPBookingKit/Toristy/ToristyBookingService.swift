import Foundation

/// Toristy's public booking API (Option B).
public protocol ToristyBookingService: Sendable {
    func bookingInformation(serviceId: Int, currency: String?) async throws -> ToristyBookingInformation
    /// Pages the range in windows of at most 62 days and returns the days in order.
    func availability(serviceId: Int, from start: BookingDate, through end: BookingDate) async throws -> ToristyAvailability
    /// Opens a 30-minute cart.
    func validate(_ request: ToristyValidationRequest) async throws -> ToristyValidation
    func confirm(_ reference: BookingReference, receipt: PaymentReceipt, amount: Decimal, currency: String) async throws
    func bookingData(cartId: String) async throws -> ToristyBookingData
    /// `notify` defaults to true at Toristy: the customer and suppliers get an email.
    func cancel(_ reference: BookingReference, note: String?, notify: Bool) async throws -> ToristyCancellation
}

/// Calls `api.toristy.com` directly with the key the host passed in.
public struct ToristyAPIClient: ToristyBookingService {

    /// Toristy rejects availability ranges longer than this.
    public static let maximumAvailabilityDays = 62
    /// `endDate` must fall within a year of today.
    public static let maximumAvailabilityHorizonDays = 364

    private let client: ProviderHTTPClient

    public init(credentials: ToristyCredentials, transport: HTTPTransport = URLSessionHTTPTransport()) {
        client = ProviderHTTPClient(
            baseURL: credentials.baseURL,
            transport: transport,
            authorizer: HeaderKeyAuthorizer(headerName: "X-Api-Key", value: credentials.apiKey),
            errorParser: ToristyAPIClient.parseError
        )
    }

    public func bookingInformation(serviceId: Int, currency: String?) async throws -> ToristyBookingInformation {
        let query = currency.map { [URLQueryItem(name: "currency", value: $0.uppercased())] } ?? []
        return try await client.request(.get, "bookingInformation/\(serviceId)", query: query)
    }

    public func availability(serviceId: Int, from start: BookingDate, through end: BookingDate) async throws -> ToristyAvailability {
        let lastBookableDay = min(end, BookingDate(date: Date()).adding(days: Self.maximumAvailabilityHorizonDays))
        var days: [ToristyAvailabilityDay] = []
        for window in BookingDate.windows(from: start, through: lastBookableDay, maximumDays: Self.maximumAvailabilityDays) {
            let page: ToristyAvailability = try await client.request(.get, "availabilities/\(serviceId)", query: [
                URLQueryItem(name: "startDate", value: window.lowerBound.description),
                URLQueryItem(name: "endDate", value: window.upperBound.description)
            ])
            days += page.days
        }
        return ToristyAvailability(serviceId: serviceId, days: days.sorted { $0.date < $1.date })
    }

    public func validate(_ request: ToristyValidationRequest) async throws -> ToristyValidation {
        try await client.request(.post, "bookingValidation", body: request)
    }

    public func confirm(_ reference: BookingReference, receipt: PaymentReceipt, amount: Decimal, currency: String) async throws {
        let body = ToristyConfirmationRequest(receipt: receipt, amount: amount, currency: currency)
        try await client.send(.post, "bookingConfirmation", query: try cartQuery(reference), body: body)
    }

    public func bookingData(cartId: String) async throws -> ToristyBookingData {
        try await client.request(.get, "bookingdata/\(cartId)")
    }

    public func cancel(_ reference: BookingReference, note: String?, notify: Bool) async throws -> ToristyCancellation {
        try await client.request(.post, "bookingcancel", query: try cartQuery(reference), body: ToristyCancelRequest(note: note, notify: notify))
    }

    private func cartQuery(_ reference: BookingReference) throws -> [URLQueryItem] {
        guard reference.provider == .toristy, let code = reference.secondary else {
            throw BookingError.rejected("A Toristy cart needs both cartid and confirmationCode.")
        }
        return [URLQueryItem(name: "cartid", value: reference.primary), URLQueryItem(name: "confirmationCode", value: code)]
    }

    static let parseError: ProviderHTTPClient.ErrorParser = { status, body in
        guard let error = try? JSONDecoder().decode(ToristyErrorBody.self, from: body) else {
            return ProviderHTTPClient.genericError(status, body)
        }
        return .server(status: status, code: error.errorcode, message: error.message)
    }
}
