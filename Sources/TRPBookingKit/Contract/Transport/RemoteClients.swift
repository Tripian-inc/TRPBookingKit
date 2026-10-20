import Foundation

/// Supplies the headers a server needs beyond the contract's own: api key, bearer token, anything host-specific.
///
/// It is asked before every request, so a refreshed token reaches the next call; its headers are applied last
/// and win over the contract's.
public protocol ContractRequestDecorating: Sendable {
    func headers() async throws -> [String: String]
}

/// A `ContractRequestDecorating` that sends the same headers on every request.
public struct StaticContractHeaders: ContractRequestDecorating {
    private let values: [String: String]

    public init(_ headers: [String: String]) {
        self.values = headers
    }

    public func headers() async throws -> [String: String] {
        values
    }
}

/// A `CheckoutClient` that speaks the booking contract to a server over HTTP.
///
/// `baseURL` is the contract's server URL, the paths are appended to it, so for tour-api it ends in `/tour-api`.
/// `capabilities` is read on every create and sent as `Tripian-Client-Capabilities`.
/// A transport failure is rethrown as `URLSession` reported it; an unreadable answer is a `CheckoutClientError`.
public final class RemoteCheckoutClient: CheckoutClient, Sendable {
    private let transport: ContractHTTPTransport
    private let capabilities: @Sendable () -> String

    public init(baseURL: URL, session: URLSession = .shared, decorator: ContractRequestDecorating,
                capabilities: @escaping @Sendable () -> String) {
        self.transport = ContractHTTPTransport(baseURL: baseURL, session: session, decorator: decorator)
        self.capabilities = capabilities
    }

    public func create(_ request: BookingContract.CreateCheckoutRequest,
                       idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.CheckoutResponse {
        try await send(.post, "/checkouts", body: request, idempotencyKey: idempotencyKey,
                       extraHeaders: [ContractHTTPTransport.capabilitiesHeader: capabilities()])
    }

    public func get(id: String, lang: String) async throws -> BookingContract.CheckoutResponse {
        try await send(.get, "/checkouts/\(ReplayPath.segment(id))", query: [("lang", lang)])
    }

    public func submit(checkoutId: String, stepId: String, answers: BookingContract.Answers,
                       expectedAmount: BookingContract.Money?, lang: String,
                       idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.CheckoutResponse {
        try await send(.post, "/checkouts/\(ReplayPath.segment(checkoutId))/steps/\(ReplayPath.segment(stepId))",
                       body: BookingContract.SubmitStepRequest(answers: answers, expectedAmount: expectedAmount,
                                                               lang: lang),
                       idempotencyKey: idempotencyKey)
    }

    public func back(checkoutId: String, fromStepId: String, lang: String,
                     idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.CheckoutResponse {
        try await send(.post, "/checkouts/\(ReplayPath.segment(checkoutId))/back",
                       body: BookingContract.BackRequest(fromStepId: fromStepId, lang: lang),
                       idempotencyKey: idempotencyKey)
    }

    public func action(checkoutId: String, actionId: String, result: BookingContract.ActionResult, lang: String,
                       idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.CheckoutResponse {
        try await send(.post, "/checkouts/\(ReplayPath.segment(checkoutId))/actions/\(ReplayPath.segment(actionId))",
                       body: BookingContract.ActionResultRequest(result: result, lang: lang),
                       idempotencyKey: idempotencyKey)
    }

    public func extend(checkoutId: String, lang: String,
                       idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.CheckoutResponse {
        try await send(.post, "/checkouts/\(ReplayPath.segment(checkoutId))/extend",
                       body: BookingContract.LangRequest(lang: lang), idempotencyKey: idempotencyKey)
    }

    public func cancel(checkoutId: String, lang: String,
                       idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.CheckoutResponse {
        try await send(.post, "/checkouts/\(ReplayPath.segment(checkoutId))/cancel",
                       body: BookingContract.LangRequest(lang: lang), idempotencyKey: idempotencyKey)
    }

    /// `GET /checkouts/{id}/actions/{actionId}/settlement`, answering `{ status: pending | succeeded | failed, reason? }`;
    /// a `404`, or a status this version does not know, is `pending`.
    public func settlement(checkoutId: String, actionId: String) async throws -> BookingContract.ActionSettlement {
        let response = try await transport.send(
            .get, "/checkouts/\(ReplayPath.segment(checkoutId))/actions/\(ReplayPath.segment(actionId))/settlement")
        guard response.status != 404 else { return .pending }
        let payload = try ContractResponseDecoder.payload(SettlementPayload.self, httpStatus: response.status,
                                                          body: response.body)
        switch payload.status {
        case "succeeded": return .succeeded
        case "failed": return .failed(reason: payload.reason)
        default: return .pending
        }
    }

    private struct SettlementPayload: Codable, Sendable {
        let status: String
        let reason: String?
    }

    private func send(_ method: ContractHTTPTransport.Method, _ path: String, query: [(String, String)] = [],
                      body: (any Encodable & Sendable)? = nil,
                      idempotencyKey: BookingContract.IdempotencyKey? = nil,
                      extraHeaders: [String: String] = [:]) async throws -> BookingContract.CheckoutResponse {
        let response = try await transport.send(method, path, query: query, body: body,
                                                idempotencyKey: idempotencyKey, extraHeaders: extraHeaders)
        return try ContractResponseDecoder.checkoutResponse(httpStatus: response.status, headers: response.headers,
                                                            body: response.body)
    }
}

/// A `BookingClient` that speaks the booking contract to a server over HTTP.
///
/// `baseURL` is the contract's server URL, the paths are appended to it, so for tour-api it ends in `/tour-api`.
/// A transport failure is rethrown as `URLSession` reported it; an unreadable answer is a `CheckoutClientError`.
public final class RemoteBookingClient: BookingClient, Sendable {
    private let transport: ContractHTTPTransport

    public init(baseURL: URL, session: URLSession = .shared, decorator: ContractRequestDecorating) {
        self.transport = ContractHTTPTransport(baseURL: baseURL, session: session, decorator: decorator)
    }

    public func list(status: [BookingContract.BookingStatus], page: Int, limit: Int,
                     lang: String) async throws -> BookingContract.BookingPage {
        var query: [(String, String)] = []
        if !status.isEmpty {
            query.append(("status", status.map(\.rawValue).joined(separator: ",")))
        }
        query += [("page", String(page)), ("limit", String(limit)), ("lang", lang)]
        let response = try await transport.send(.get, "/bookings", query: query)
        let envelope = try ContractResponseDecoder.envelope([BookingContract.Booking].self,
                                                            httpStatus: response.status, body: response.body)
        return BookingContract.BookingPage(bookings: envelope.data ?? [], pagination: envelope.pagination)
    }

    public func get(uuid: String, lang: String) async throws -> BookingContract.Booking {
        let response = try await transport.send(.get, "/bookings/\(ReplayPath.segment(uuid))", query: [("lang", lang)])
        return try ContractResponseDecoder.payload(BookingContract.Booking.self, httpStatus: response.status,
                                                   body: response.body)
    }

    public func cancel(uuid: String, reason: String?, lang: String,
                       idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.Booking {
        let response = try await transport.send(.post, "/bookings/\(ReplayPath.segment(uuid))/cancel",
                                                body: BookingContract.CancelBookingRequest(reason: reason, lang: lang),
                                                idempotencyKey: idempotencyKey)
        return try ContractResponseDecoder.payload(BookingContract.Booking.self, httpStatus: response.status,
                                                   body: response.body)
    }
}

/// Builds, decorates and sends one contract request, shared by the remote clients.
struct ContractHTTPTransport: Sendable {

    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    /// A raw answer: the status, the headers as strings and the body.
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    static let versionHeader = "Tripian-Booking-Version"
    static let idempotencyHeader = "Idempotency-Key"
    static let capabilitiesHeader = "Tripian-Client-Capabilities"

    let baseURL: URL
    let session: URLSession
    let decorator: ContractRequestDecorating

    /// Sends `path` below `baseURL` with the contract headers, then `extraHeaders`, then the decorator's.
    func send(_ method: Method, _ path: String, query: [(String, String)] = [],
              body: (any Encodable & Sendable)? = nil, idempotencyKey: BookingContract.IdempotencyKey? = nil,
              extraHeaders: [String: String] = [:]) async throws -> Response {
        var request = URLRequest(url: try url(path: path, query: query))
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(BookingContract.version, forHTTPHeaderField: Self.versionHeader)
        if let idempotencyKey {
            request.setValue(idempotencyKey.rawValue, forHTTPHeaderField: Self.idempotencyHeader)
        }
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in try await decorator.headers() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        return try await perform(request)
    }

    /// `baseURL` with `path` appended to its path and `query` percent-encoded the way the contract fixtures record it.
    func url(path: String, query: [(String, String)]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw URLError(.badURL)
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = basePath + path
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { "\(ReplayPath.query($0.0))=\(ReplayPath.query($0.1))" }
                .joined(separator: "&")
        }
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    private func perform(_ request: URLRequest) async throws -> Response {
        let box = DataTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: BookingContract.CheckoutClientError.undecodable(
                            httpStatus: 0, reason: "The answer is not an HTTP response."))
                        return
                    }
                    var headers: [String: String] = [:]
                    for (name, value) in http.allHeaderFields {
                        if let name = name as? String { headers[name] = "\(value)" }
                    }
                    continuation.resume(returning: Response(status: http.statusCode, headers: headers,
                                                            body: data ?? Data()))
                }
                box.start(task)
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Holds the running data task so cancelling the calling `Task` cancels the request, whichever happens first.
private final class DataTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isCancelled = false

    func start(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { task.cancel() }
        task.resume()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
