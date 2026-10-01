import Foundation

/// The identifiers a provider needs to look a booking up, confirm it or cancel it.
///
/// Never carries payment tokens or card data.
public struct BookingReference: Sendable, Hashable, Codable {
    public let provider: BookingProviderKind
    /// Toristy `cartid`, Viator `bookingRef`, the `reference` sent with a Victory order.
    public let primary: String
    /// Toristy `confirmationCode`, Viator `cartRef`, Victory order id; `nil` until the provider has one.
    public let secondary: String?

    public init(provider: BookingProviderKind, primary: String, secondary: String? = nil) {
        self.provider = provider
        self.primary = primary
        self.secondary = secondary
    }
}

/// Where a booking stands from the app's point of view.
public enum BookingRecordStatus: String, Sendable, Codable {
    /// Held at the provider, not charged yet.
    case held
    /// Charged, confirmation not answered yet.
    case charged
    case confirmed
    /// Booked, waiting for the supplier to confirm; not terminal.
    case pending
    /// Charged but not confirmed; the charge must be refunded.
    case needsRefund
    case refunded
    case cancelled
    case expired
    case failed
}

/// A booking the app has started, saved before the customer is charged so nothing is lost if the
/// app dies in between.
public struct BookingRecord: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(reference.provider.rawValue):\(reference.primary)" }
    public let reference: BookingReference
    public let activityId: String
    public let title: String
    public let travelDate: BookingDate?
    public var status: BookingRecordStatus
    public var total: Decimal?
    public var currency: String?
    public var deadline: BookingDeadline?
    public var receipt: PaymentReceipt?
    public var providerStatus: String?
    public let createdAt: Date
    public var updatedAt: Date
    /// The contract's view of the booking, kept by the local checkout; `nil` for records made outside it.
    public var contractBooking: BookingContract.Booking?

    public init(reference: BookingReference,
                activityId: String,
                title: String,
                travelDate: BookingDate?,
                status: BookingRecordStatus,
                total: Decimal? = nil,
                currency: String? = nil,
                deadline: BookingDeadline? = nil,
                receipt: PaymentReceipt? = nil,
                providerStatus: String? = nil,
                createdAt: Date = Date(),
                contractBooking: BookingContract.Booking? = nil) {
        self.reference = reference
        self.activityId = activityId
        self.title = title
        self.travelDate = travelDate
        self.status = status
        self.total = total
        self.currency = currency
        self.deadline = deadline
        self.receipt = receipt
        self.providerStatus = providerStatus
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.contractBooking = contractBooking
    }
}

/// Persists booking records.
public protocol BookingRecordStore: Sendable {
    func save(_ record: BookingRecord) async
    func record(for reference: BookingReference) async -> BookingRecord?
    func all() async -> [BookingRecord]
    func remove(_ reference: BookingReference) async
}

extension BookingRecordStore {
    /// Records that were charged without a confirmation and still need a refund or a retry.
    public func unresolved() async -> [BookingRecord] {
        await all().filter { $0.status == .charged || $0.status == .needsRefund }
    }

    func update(_ reference: BookingReference, _ change: (inout BookingRecord) -> Void) async {
        guard var record = await record(for: reference) else { return }
        change(&record)
        record.updatedAt = Date()
        await save(record)
    }
}

/// Keeps records in `UserDefaults` under one key.
public actor UserDefaultsBookingRecordStore: BookingRecordStore {

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "trp.booking.records") {
        self.defaults = defaults
        self.key = key
    }

    public func save(_ record: BookingRecord) {
        var records = load()
        records[record.id] = record
        store(records)
    }

    public func record(for reference: BookingReference) -> BookingRecord? {
        load()["\(reference.provider.rawValue):\(reference.primary)"]
    }

    public func all() -> [BookingRecord] {
        load().values.sorted { $0.createdAt > $1.createdAt }
    }

    public func remove(_ reference: BookingReference) {
        var records = load()
        records["\(reference.provider.rawValue):\(reference.primary)"] = nil
        store(records)
    }

    private func load() -> [String: BookingRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([String: BookingRecord].self, from: data) else { return [:] }
        return records
    }

    private func store(_ records: [String: BookingRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Keeps records in memory; for tests and previews.
public actor InMemoryBookingRecordStore: BookingRecordStore {

    private var records: [String: BookingRecord] = [:]

    public init() {}

    public func save(_ record: BookingRecord) { records[record.id] = record }
    public func record(for reference: BookingReference) -> BookingRecord? { records["\(reference.provider.rawValue):\(reference.primary)"] }
    public func all() -> [BookingRecord] { records.values.sorted { $0.createdAt > $1.createdAt } }
    public func remove(_ reference: BookingReference) { records["\(reference.provider.rawValue):\(reference.primary)"] = nil }
}
