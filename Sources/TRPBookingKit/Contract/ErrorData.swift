import Foundation

extension BookingContract {

    /// The `data` of an error response.
    ///
    /// `checkout` carries the current checkout when the client should re-render from it; `supported` lists the
    /// contract versions the server accepts and comes only with `VERSION_UNSUPPORTED`.
    public struct ErrorData: Codable, Hashable, Sendable {
        public let code: OpenEnum<ErrorCode>
        public let errors: [FieldError]
        public let retryable: Bool
        public let checkout: Checkout?
        public let supported: [String]?

        public init(code: OpenEnum<ErrorCode>, errors: [FieldError], retryable: Bool, checkout: Checkout?,
                    supported: [String]? = nil) {
            self.code = code
            self.errors = errors
            self.retryable = retryable
            self.checkout = checkout
            self.supported = supported
        }

        enum CodingKeys: String, CodingKey { case code, errors, retryable, checkout, supported }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(code, forKey: .code)
            try container.encode(errors, forKey: .errors)
            try container.encode(retryable, forKey: .retryable)
            try container.encode(checkout, forKey: .checkout)
            try container.encodeIfPresent(supported, forKey: .supported)
        }

        /// A message about one answer; `field` is the field or block id.
        public struct FieldError: Codable, Hashable, Sendable {
            public let field: String
            public let message: String

            public init(field: String, message: String) {
                self.field = field
                self.message = message
            }
        }
    }
}
