import Foundation

/// Viator Partner API v2, the calls a booking needs.
public protocol ViatorBookingService: Sendable {
    func product(code: String) async throws -> ViatorProduct
    func schedule(productCode: String) async throws -> ViatorSchedule
    /// The whole dictionary; cache it and look questions up by id.
    func bookingQuestions() async throws -> [ViatorBookingQuestion]
    /// Resolves refs in batches of at most 300.
    func locations(refs: [String]) async throws -> [ViatorLocation]
    func availability(productCode: String, travelDate: BookingDate, currency: String, paxMix: [ViatorPax]) async throws -> ViatorAvailability
    func exchangeRates(from sources: [String], to targets: [String]) async throws -> [ViatorExchangeRate]
    func hold(_ item: ViatorHoldItem, currency: String, partnerCartRef: String, partnerBookingRef: String) async throws -> ViatorHold
    func book(cartRef: String, bookingRef: String, details: ViatorBookerDetails, paymentToken: String) async throws -> ViatorBookResult
    func status(bookingRef: String) async throws -> ViatorBookingStatusResult
    func cancelQuote(bookingRef: String) async throws -> ViatorCancelQuote
    func cancel(bookingRef: String) async throws -> ViatorCancellation
}

/// The answer to `POST /bookings/status`.
public struct ViatorBookingStatusResult: Sendable, Hashable, Decodable {
    public let bookingRef: String
    public let status: ViatorBookingStatus
    public let rawStatus: String?

    private enum CodingKeys: String, CodingKey { case bookingRef, status }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookingRef = container.flexibleString(.bookingRef) ?? ""
        rawStatus = container.flexibleString(.status)
        status = ViatorBookingStatus(rawStatus)
    }
}

/// Calls the Viator Partner API directly with the key the host passed in.
public struct ViatorAPIClient: ViatorBookingService {

    /// `Accept-Language` values Viator serves; anything else falls back to English.
    public static let supportedLanguages: Set<String> = ["en", "da", "nl", "no", "sv", "es", "fr", "it", "de", "pt", "ja", "zh", "ko"]
    public static let maximumLocationsPerRequest = 300

    private let client: ProviderHTTPClient
    private let hostingOrigin: String
    private let subChannelId: String

    public init(credentials: ViatorCredentials, languageCode: String, transport: HTTPTransport = URLSessionHTTPTransport()) {
        client = ProviderHTTPClient(
            baseURL: credentials.baseURL,
            transport: transport,
            authorizer: HeaderKeyAuthorizer(headerName: "exp-api-key", value: credentials.apiKey),
            defaultHeaders: [
                "Accept": "application/json;version=2.0",
                "Accept-Language": Self.acceptLanguage(for: languageCode)
            ],
            errorParser: ViatorAPIClient.parseError
        )
        hostingOrigin = credentials.hostingOrigin
        subChannelId = credentials.subChannelId
    }

    /// Maps an app language such as `tr` or `pt-BR` onto Viator's allow-list.
    public static func acceptLanguage(for languageCode: String) -> String {
        let base = languageCode.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        return supportedLanguages.contains(base) ? base : "en"
    }

    public func product(code: String) async throws -> ViatorProduct {
        try await client.request(.get, "products/\(code)")
    }

    public func schedule(productCode: String) async throws -> ViatorSchedule {
        try await client.request(.get, "availability/schedules/\(productCode)")
    }

    public func bookingQuestions() async throws -> [ViatorBookingQuestion] {
        let response: ViatorBookingQuestionsResponse = try await client.request(.get, "products/booking-questions")
        return response.bookingQuestions
    }

    public func locations(refs: [String]) async throws -> [ViatorLocation] {
        let unique = Array(Set(refs.filter { !$0.isEmpty && $0 != "MEET_AT_DEPARTURE_POINT" })).sorted()
        var locations: [ViatorLocation] = []
        for start in stride(from: 0, to: unique.count, by: Self.maximumLocationsPerRequest) {
            let batch = Array(unique[start..<min(start + Self.maximumLocationsPerRequest, unique.count)])
            let response: ViatorLocationsResponse = try await client.request(.post, "locations/bulk", body: ["locations": batch])
            locations += response.locations
        }
        return locations
    }

    public func availability(productCode: String, travelDate: BookingDate, currency: String, paxMix: [ViatorPax]) async throws -> ViatorAvailability {
        let body = ViatorAvailabilityRequest(productCode: productCode, travelDate: travelDate, currency: currency.uppercased(),
                                             paxMix: paxMix.filter { $0.numberOfTravelers > 0 })
        return try await client.request(.post, "availability/check", body: body)
    }

    public func exchangeRates(from sources: [String], to targets: [String]) async throws -> [ViatorExchangeRate] {
        let response: ViatorExchangeRatesResponse = try await client.request(
            .post, "exchange-rates", body: ViatorExchangeRatesRequest(sourceCurrencies: sources, targetCurrencies: targets))
        return response.rates
    }

    public func hold(_ item: ViatorHoldItem, currency: String, partnerCartRef: String, partnerBookingRef: String) async throws -> ViatorHold {
        let body = ViatorHoldRequest(
            currency: currency.uppercased(),
            partnerCartRef: partnerCartRef,
            items: [.init(partnerBookingRef: partnerBookingRef, productCode: item.productCode, productOptionCode: item.productOptionCode,
                          startTime: item.startTime, travelDate: item.travelDate, paxMix: item.paxMix)],
            hostingUrl: hostingOrigin
        )
        return try await client.request(.post, "bookings/cart/hold", body: body)
    }

    public func book(cartRef: String, bookingRef: String, details: ViatorBookerDetails, paymentToken: String) async throws -> ViatorBookResult {
        let body = ViatorBookRequest(cartRef: cartRef, bookingRef: bookingRef, details: details,
                                     paymentToken: paymentToken, subChannelId: subChannelId)
        return try await client.request(.post, "bookings/cart/book", body: body)
    }

    public func status(bookingRef: String) async throws -> ViatorBookingStatusResult {
        try await client.request(.post, "bookings/status", body: ViatorStatusRequest(bookingRef: bookingRef))
    }

    public func cancelQuote(bookingRef: String) async throws -> ViatorCancelQuote {
        try await client.request(.get, "bookings/\(bookingRef)/cancel-quote")
    }

    public func cancel(bookingRef: String) async throws -> ViatorCancellation {
        try await client.request(.post, "bookings/\(bookingRef)/cancel", body: ViatorCancelRequest(reasonCode: "CUSTOMER_SERVICE_CANCELLED"))
    }

    static let parseError: ProviderHTTPClient.ErrorParser = { status, body in
        guard let error = try? JSONDecoder().decode(ViatorErrorBody.self, from: body), error.code != nil || error.message != nil else {
            return ProviderHTTPClient.genericError(status, body)
        }
        return .server(status: status, code: error.code, message: error.message)
    }
}

struct ViatorBookingQuestionsResponse: Decodable {
    let bookingQuestions: [ViatorBookingQuestion]

    private enum CodingKeys: String, CodingKey { case bookingQuestions }

    init(from decoder: Decoder) throws {
        bookingQuestions = try decoder.container(keyedBy: CodingKeys.self).lossyArray(.bookingQuestions)
    }
}
