import Foundation

extension BookingContract {

    /// An error response of the contract: the HTTP status and the envelope's `data`.
    public struct ContractError: Error, Hashable, Sendable {
        public let httpStatus: Int
        public let data: ErrorData

        public init(httpStatus: Int, data: ErrorData) {
            self.httpStatus = httpStatus
            self.data = data
        }

        public var code: ErrorCode { data.code.value }
    }

    /// A failure to get a contract answer at all, as opposed to a `ContractError`.
    public enum CheckoutClientError: Error, Hashable, Sendable {
        /// A successful envelope came without `data`.
        case missingData(httpStatus: Int)
        /// The response body could not be read as the contract describes it.
        case undecodable(httpStatus: Int, reason: String)
        /// A replay client was asked for one request while its next fixture records another.
        case unexpectedRequest(expected: String, actual: String)
        /// A replay client has no fixtures left.
        case fixturesExhausted(request: String)
    }

    /// The `Idempotency-Key` header of a mutating call: a lowercase UUID v4.
    public struct IdempotencyKey: Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init() {
            rawValue = UUID().uuidString.lowercased()
        }

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }
    }
}
