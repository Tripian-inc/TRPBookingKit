import Foundation

extension BookingContract {

    /// The tour-api response envelope around every contract response, successful or not.
    public struct Envelope<Payload: Codable & Sendable>: Codable, Sendable {
        public let status: Int
        public let success: Bool
        public let message: String?
        public let uuid: String?
        public let data: Payload?
        public let pagination: Pagination?

        public init(status: Int, success: Bool, message: String? = nil, uuid: String? = nil,
                    data: Payload?, pagination: Pagination? = nil) {
            self.status = status
            self.success = success
            self.message = message
            self.uuid = uuid
            self.data = data
            self.pagination = pagination
        }

        enum CodingKeys: String, CodingKey {
            case status, success, message, data, pagination
            case uuid = "UUID"
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(status, forKey: .status)
            try container.encode(success, forKey: .success)
            try container.encode(message, forKey: .message)
            try container.encode(uuid, forKey: .uuid)
            try container.encode(data, forKey: .data)
            try container.encodeIfPresent(pagination, forKey: .pagination)
        }
    }

    /// The page information of a list response.
    public struct Pagination: Codable, Hashable, Sendable {
        public let count: Int
        public let total: Int
        public let perPage: Int
        public let currentPage: Int
        public let totalPages: Int
        public let links: Links

        public init(count: Int, total: Int, perPage: Int, currentPage: Int, totalPages: Int, links: Links) {
            self.count = count
            self.total = total
            self.perPage = perPage
            self.currentPage = currentPage
            self.totalPages = totalPages
            self.links = links
        }

        public var hasNextPage: Bool { currentPage < totalPages }

        /// The URLs of the neighbouring pages, `nil` at either end.
        public struct Links: Codable, Hashable, Sendable {
            public let next: String?
            public let previous: String?

            public init(next: String?, previous: String?) {
                self.next = next
                self.previous = previous
            }

            enum CodingKeys: String, CodingKey { case next, previous }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(next, forKey: .next)
                try container.encode(previous, forKey: .previous)
            }
        }
    }

    /// An amount as a decimal string in the currency's minor-unit precision, never a floating-point number.
    public struct Money: Codable, Hashable, Sendable {
        public let amount: String
        public let currency: String

        public init(amount: String, currency: String) {
            self.amount = amount
            self.currency = currency
        }

        public var decimalValue: Decimal? {
            Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX"))
        }
    }
}
