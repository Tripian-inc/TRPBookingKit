import Foundation

extension BookingContract {

    /// Counts per unit id, such as `["ADULT": 2, "CHILD": 1]`.
    public typealias Units = [String: Int]

    /// A booking as tour-api keeps it, independent of the provider that fulfils it.
    public struct Booking: Codable, Hashable, Sendable {
        public let uuid: String
        public let status: OpenEnum<BookingStatus>
        public let provider: String
        public let providerReference: String?
        public let product: Product
        public let units: Units
        public let start: Start
        public let durationMinutes: Int?
        public let meetingPoint: MeetingPoint?
        public let amount: Money
        public let utcExpiresAt: String?
        public let vouchers: [Voucher]
        public let cancellation: Cancellation
        public let refund: Refund?
        public let contact: Contact

        public init(uuid: String, status: OpenEnum<BookingStatus>, provider: String, providerReference: String?,
                    product: Product, units: Units, start: Start, durationMinutes: Int?, meetingPoint: MeetingPoint?,
                    amount: Money, utcExpiresAt: String?, vouchers: [Voucher], cancellation: Cancellation,
                    refund: Refund?, contact: Contact) {
            self.uuid = uuid
            self.status = status
            self.provider = provider
            self.providerReference = providerReference
            self.product = product
            self.units = units
            self.start = start
            self.durationMinutes = durationMinutes
            self.meetingPoint = meetingPoint
            self.amount = amount
            self.utcExpiresAt = utcExpiresAt
            self.vouchers = vouchers
            self.cancellation = cancellation
            self.refund = refund
            self.contact = contact
        }

        enum CodingKeys: String, CodingKey {
            case uuid, status, provider, providerReference, product, units, start, durationMinutes, meetingPoint
            case amount, utcExpiresAt, vouchers, cancellation, refund, contact
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(uuid, forKey: .uuid)
            try container.encode(status, forKey: .status)
            try container.encode(provider, forKey: .provider)
            try container.encode(providerReference, forKey: .providerReference)
            try container.encode(product, forKey: .product)
            try container.encode(units, forKey: .units)
            try container.encode(start, forKey: .start)
            try container.encode(durationMinutes, forKey: .durationMinutes)
            try container.encode(meetingPoint, forKey: .meetingPoint)
            try container.encode(amount, forKey: .amount)
            try container.encode(utcExpiresAt, forKey: .utcExpiresAt)
            try container.encode(vouchers, forKey: .vouchers)
            try container.encode(cancellation, forKey: .cancellation)
            try container.encode(refund, forKey: .refund)
            try container.encode(contact, forKey: .contact)
        }

        /// The local start: a `yyyy-MM-dd` date, an optional `HH:mm` time and the IANA time zone they are in.
        public struct Start: Codable, Hashable, Sendable {
            public let date: String
            public let time: String?
            public let timezone: String

            public init(date: String, time: String?, timezone: String) {
                self.date = date
                self.time = time
                self.timezone = timezone
            }

            enum CodingKeys: String, CodingKey { case date, time, timezone }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(date, forKey: .date)
                try container.encode(time, forKey: .time)
                try container.encode(timezone, forKey: .timezone)
            }
        }

        /// Where the activity starts.
        public struct MeetingPoint: Codable, Hashable, Sendable {
            public let name: String
            public let address: String?
            public let lat: Double?
            public let lng: Double?

            public init(name: String, address: String?, lat: Double?, lng: Double?) {
                self.name = name
                self.address = address
                self.lat = lat
                self.lng = lng
            }

            enum CodingKeys: String, CodingKey { case name, address, lat, lng }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                try container.encode(address, forKey: .address)
                try container.encode(lat, forKey: .lat)
                try container.encode(lng, forKey: .lng)
            }
        }

        /// A ticket or confirmation document.
        public struct Voucher: Codable, Hashable, Sendable {
            public let format: OpenEnum<VoucherFormat>
            public let url: String

            public init(format: OpenEnum<VoucherFormat>, url: String) {
                self.format = format
                self.url = url
            }
        }

        /// Whether and until when the booking can be cancelled, and what comes back.
        public struct Cancellation: Codable, Hashable, Sendable {
            public let allowed: Bool
            public let deadline: String?
            public let refund: OpenEnum<RefundPolicy>
            public let refundAmount: Money?

            public init(allowed: Bool, deadline: String?, refund: OpenEnum<RefundPolicy>, refundAmount: Money?) {
                self.allowed = allowed
                self.deadline = deadline
                self.refund = refund
                self.refundAmount = refundAmount
            }

            enum CodingKeys: String, CodingKey { case allowed, deadline, refund, refundAmount }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(allowed, forKey: .allowed)
                try container.encode(deadline, forKey: .deadline)
                try container.encode(refund, forKey: .refund)
                try container.encode(refundAmount, forKey: .refundAmount)
            }
        }

        /// The refund after a cancellation or a failed confirmation.
        public struct Refund: Codable, Hashable, Sendable {
            public let status: OpenEnum<RefundStatus>
            public let amount: Money

            public init(status: OpenEnum<RefundStatus>, amount: Money) {
                self.status = status
                self.amount = amount
            }
        }

        /// The buyer.
        public struct Contact: Codable, Hashable, Sendable {
            public let name: String
            public let email: String

            public init(name: String, email: String) {
                self.name = name
                self.email = email
            }
        }
    }
}
