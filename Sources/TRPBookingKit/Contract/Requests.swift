import Foundation

extension BookingContract {

    /// The answers of a step, keyed by block or field id.
    public struct Answers: Codable, Hashable, Sendable, ExpressibleByDictionaryLiteral {
        public var values: [String: JSONValue]

        public init(_ values: [String: JSONValue] = [:]) {
            self.values = values
        }

        public init(dictionaryLiteral elements: (String, JSONValue)...) {
            self.values = Dictionary(elements, uniquingKeysWith: { _, last in last })
        }

        public subscript(id: String) -> JSONValue? {
            get { values[id] }
            set { values[id] = newValue }
        }

        /// The answer `path` refers to: an id itself, or `blockId.key` inside an object answer such as `units.CHILD`.
        public func value(at path: String) -> JSONValue? {
            if let value = values[path] { return value }
            guard let dot = path.firstIndex(of: ".") else { return nil }
            let id = String(path[..<dot])
            let key = String(path[path.index(after: dot)...])
            return values[id]?.objectValue?[key]
        }

        public init(from decoder: Decoder) throws {
            values = try decoder.singleValueContainer().decode([String: JSONValue].self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(values)
        }
    }

    /// `POST /checkouts`: opens a checkout for a product.
    public struct CreateCheckoutRequest: Codable, Hashable, Sendable {
        public let productId: String
        public let optionId: String?
        public let date: String?
        public let currency: String
        public let bookingUuid: String
        public let lang: String

        public init(productId: String, optionId: String? = nil, date: String? = nil, currency: String,
                    bookingUuid: String, lang: String) {
            self.productId = productId
            self.optionId = optionId
            self.date = date
            self.currency = currency
            self.bookingUuid = bookingUuid
            self.lang = lang
        }

        enum CodingKeys: String, CodingKey { case productId, optionId, date, currency, bookingUuid, lang }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(productId, forKey: .productId)
            try container.encode(optionId, forKey: .optionId)
            try container.encode(date, forKey: .date)
            try container.encode(currency, forKey: .currency)
            try container.encode(bookingUuid, forKey: .bookingUuid)
            try container.encode(lang, forKey: .lang)
        }
    }

    /// `POST /checkouts/{id}/steps/{stepId}`; `expectedAmount` is the checkout's current amount, sent on every
    /// submit while it is known and checked only on the submit that moves the checkout to `awaiting_payment`.
    public struct SubmitStepRequest: Codable, Hashable, Sendable {
        public let answers: Answers
        public let expectedAmount: Money?
        public let lang: String

        public init(answers: Answers, expectedAmount: Money? = nil, lang: String) {
            self.answers = answers
            self.expectedAmount = expectedAmount
            self.lang = lang
        }
    }

    /// `POST /checkouts/{id}/back`.
    public struct BackRequest: Codable, Hashable, Sendable {
        public let fromStepId: String
        public let lang: String

        public init(fromStepId: String, lang: String) {
            self.fromStepId = fromStepId
            self.lang = lang
        }
    }

    /// `POST /checkouts/{id}/actions/{actionId}`.
    public struct ActionResultRequest: Codable, Hashable, Sendable {
        public let result: ActionResult
        public let lang: String

        public init(result: ActionResult, lang: String) {
            self.result = result
            self.lang = lang
        }
    }

    /// The body of `extend` and of a checkout `cancel`.
    public struct LangRequest: Codable, Hashable, Sendable {
        public let lang: String

        public init(lang: String) {
            self.lang = lang
        }
    }

    /// `POST /bookings/{uuid}/cancel`.
    public struct CancelBookingRequest: Codable, Hashable, Sendable {
        public let reason: String?
        public let lang: String

        public init(reason: String? = nil, lang: String) {
            self.reason = reason
            self.lang = lang
        }
    }
}
