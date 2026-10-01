import Foundation

extension BookingContract {

    /// One recorded request of a contract fixture: `<name>.request.json`.
    public struct RecordedRequest: Codable, Hashable, Sendable {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let body: JSONValue?

        public init(method: String, path: String, headers: [String: String] = [:], body: JSONValue? = nil) {
            self.method = method
            self.path = path
            self.headers = headers
            self.body = body
        }

        /// `METHOD path`, as requests are matched.
        public var signature: String { "\(method) \(path)" }
    }

    /// The recorded answer of a contract fixture: `<name>.response.json`.
    public struct RecordedResponse: Codable, Hashable, Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: JSONValue

        public init(status: Int, headers: [String: String] = [:], body: JSONValue) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    /// A request and its response, named after the fixture files.
    public struct RecordedExchange: Hashable, Sendable {
        public let name: String
        public let request: RecordedRequest
        public let response: RecordedResponse

        public init(name: String, request: RecordedRequest, response: RecordedResponse) {
            self.name = name
            self.request = request
            self.response = response
        }

        /// Every `<name>.request.json` / `<name>.response.json` pair directly in `directory`, ordered by name.
        public static func load(from directory: URL) throws -> [RecordedExchange] {
            let decoder = JSONDecoder()
            let requestSuffix = ".request.json"
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(requestSuffix) }
                .map { String($0.dropLast(requestSuffix.count)) }
                .sorted()
            return try names.map { name in
                let request = try decoder.decode(RecordedRequest.self, from: Data(
                    contentsOf: directory.appendingPathComponent(name + requestSuffix)))
                let response = try decoder.decode(RecordedResponse.self, from: Data(
                    contentsOf: directory.appendingPathComponent(name + ".response.json")))
                return RecordedExchange(name: name, request: request, response: response)
            }
        }
    }

    /// A request a replay client was asked to send.
    public struct SentRequest: Hashable, Sendable {
        public let method: String
        public let path: String
        public let body: JSONValue?
        public let idempotencyKey: IdempotencyKey?

        public var signature: String { "\(method) \(path)" }
    }

    /// The ordered exchanges replay clients answer from, shared by a checkout and a booking client walking one flow.
    public actor ReplayScript {
        public private(set) var exchanges: [RecordedExchange]
        public private(set) var sent: [SentRequest] = []
        private var cursor = 0

        public init(_ exchanges: [RecordedExchange]) {
            self.exchanges = exchanges
        }

        public init(directory: URL) throws {
            self.exchanges = try RecordedExchange.load(from: directory)
        }

        /// The exchanges not yet answered.
        public var remaining: [RecordedExchange] { Array(exchanges[cursor...]) }

        /// Records `request` and answers it with the next exchange, which must have the same method and path.
        func answer(_ request: SentRequest) throws -> RecordedExchange {
            sent.append(request)
            guard cursor < exchanges.count else {
                throw CheckoutClientError.fixturesExhausted(request: request.signature)
            }
            let exchange = exchanges[cursor]
            guard exchange.request.method == request.method, exchange.request.path == request.path else {
                throw CheckoutClientError.unexpectedRequest(expected: exchange.request.signature, actual: request.signature)
            }
            cursor += 1
            return exchange
        }
    }

    /// A `CheckoutClient` that answers from recorded fixtures in order, for tests and previews.
    public struct ReplayCheckoutClient: CheckoutClient {
        public let script: ReplayScript
        public let basePath: String

        public init(script: ReplayScript, basePath: String = "/tour-api") {
            self.script = script
            self.basePath = basePath
        }

        public func create(_ request: CreateCheckoutRequest,
                           idempotencyKey: IdempotencyKey) async throws -> CheckoutResponse {
            try await send("POST", "/checkouts", body: request, idempotencyKey: idempotencyKey)
        }

        public func get(id: String, lang: String) async throws -> CheckoutResponse {
            try await send("GET", "/checkouts/\(ReplayPath.segment(id))?lang=\(ReplayPath.query(lang))")
        }

        public func submit(checkoutId: String, stepId: String, answers: Answers, expectedAmount: Money?,
                           lang: String, idempotencyKey: IdempotencyKey) async throws -> CheckoutResponse {
            try await send("POST", "/checkouts/\(ReplayPath.segment(checkoutId))/steps/\(ReplayPath.segment(stepId))",
                           body: SubmitStepRequest(answers: answers, expectedAmount: expectedAmount, lang: lang),
                           idempotencyKey: idempotencyKey)
        }

        public func back(checkoutId: String, fromStepId: String, lang: String,
                         idempotencyKey: IdempotencyKey) async throws -> CheckoutResponse {
            try await send("POST", "/checkouts/\(ReplayPath.segment(checkoutId))/back",
                           body: BackRequest(fromStepId: fromStepId, lang: lang), idempotencyKey: idempotencyKey)
        }

        public func action(checkoutId: String, actionId: String, result: ActionResult, lang: String,
                           idempotencyKey: IdempotencyKey) async throws -> CheckoutResponse {
            try await send("POST", "/checkouts/\(ReplayPath.segment(checkoutId))/actions/\(ReplayPath.segment(actionId))",
                           body: ActionResultRequest(result: result, lang: lang), idempotencyKey: idempotencyKey)
        }

        public func extend(checkoutId: String, lang: String,
                           idempotencyKey: IdempotencyKey) async throws -> CheckoutResponse {
            try await send("POST", "/checkouts/\(ReplayPath.segment(checkoutId))/extend",
                           body: LangRequest(lang: lang), idempotencyKey: idempotencyKey)
        }

        public func cancel(checkoutId: String, lang: String,
                           idempotencyKey: IdempotencyKey) async throws -> CheckoutResponse {
            try await send("POST", "/checkouts/\(ReplayPath.segment(checkoutId))/cancel",
                           body: LangRequest(lang: lang), idempotencyKey: idempotencyKey)
        }

        private func send(_ method: String, _ path: String, body: (any Encodable & Sendable)? = nil,
                          idempotencyKey: IdempotencyKey? = nil) async throws -> CheckoutResponse {
            let response = try await ReplayPath.exchange(script, method, basePath + path, body, idempotencyKey)
            return try ContractResponseDecoder.checkoutResponse(httpStatus: response.status, headers: response.headers,
                                                                body: JSONEncoder().encode(response.body))
        }
    }

    /// A `BookingClient` that answers from recorded fixtures in order, for tests and previews.
    public struct ReplayBookingClient: BookingClient {
        public let script: ReplayScript
        public let basePath: String

        public init(script: ReplayScript, basePath: String = "/tour-api") {
            self.script = script
            self.basePath = basePath
        }

        public func list(status: [BookingStatus], page: Int, limit: Int, lang: String) async throws -> BookingPage {
            var query: [String] = []
            if !status.isEmpty {
                query.append("status=" + status.map(\.rawValue).joined(separator: ","))
            }
            query += ["page=\(page)", "limit=\(limit)", "lang=\(ReplayPath.query(lang))"]
            let response = try await ReplayPath.exchange(script, "GET", basePath + "/bookings?" + query.joined(separator: "&"),
                                                         nil, nil)
            let envelope = try ContractResponseDecoder.envelope([Booking].self, httpStatus: response.status,
                                                                body: JSONEncoder().encode(response.body))
            return BookingPage(bookings: envelope.data ?? [], pagination: envelope.pagination)
        }

        public func get(uuid: String, lang: String) async throws -> Booking {
            let response = try await ReplayPath.exchange(
                script, "GET", basePath + "/bookings/\(ReplayPath.segment(uuid))?lang=\(ReplayPath.query(lang))", nil, nil)
            return try ContractResponseDecoder.payload(Booking.self, httpStatus: response.status,
                                                       body: JSONEncoder().encode(response.body))
        }

        public func cancel(uuid: String, reason: String?, lang: String,
                           idempotencyKey: IdempotencyKey) async throws -> Booking {
            let response = try await ReplayPath.exchange(
                script, "POST", basePath + "/bookings/\(ReplayPath.segment(uuid))/cancel",
                CancelBookingRequest(reason: reason, lang: lang), idempotencyKey)
            return try ContractResponseDecoder.payload(Booking.self, httpStatus: response.status,
                                                       body: JSONEncoder().encode(response.body))
        }
    }
}

/// Path building and dispatch shared by the replay clients.
enum ReplayPath {

    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? value
    }

    static func query(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "=", "+"])) ?? value
    }

    static func exchange(_ script: BookingContract.ReplayScript, _ method: String, _ path: String,
                         _ body: (any Encodable & Sendable)?,
                         _ idempotencyKey: BookingContract.IdempotencyKey?) async throws -> BookingContract.RecordedResponse {
        let json = try body.map { try BookingContract.JSONValue(encoding: $0) }
        let request = BookingContract.SentRequest(method: method, path: path, body: json, idempotencyKey: idempotencyKey)
        return try await script.answer(request).response
    }
}
