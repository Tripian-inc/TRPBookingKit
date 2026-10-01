import Foundation

/// What the local checkout knows about a product beyond what the provider's api returns.
public struct LocalProduct: Sendable, Hashable {
    public let id: String
    public let provider: BookingProviderKind
    /// The provider's own id: a Viator product code, a Toristy service id or a Ticket Evolution event id.
    public let providerProductId: String
    public let title: String
    public let imageUrl: String?
    public let timeZone: TimeZone
    public let durationMinutes: Int?
    public let meetingPoint: BookingContract.Booking.MeetingPoint?
    /// Durations of single options, by option id, when they differ from `durationMinutes`.
    public let optionDurationMinutes: [String: Int]

    public init(id: String, provider: BookingProviderKind, providerProductId: String, title: String, imageUrl: String? = nil,
                timeZone: TimeZone, durationMinutes: Int? = nil, meetingPoint: BookingContract.Booking.MeetingPoint? = nil,
                optionDurationMinutes: [String: Int] = [:]) {
        self.id = id
        self.provider = provider
        self.providerProductId = providerProductId
        self.title = title
        self.imageUrl = imageUrl
        self.timeZone = timeZone
        self.durationMinutes = durationMinutes
        self.meetingPoint = meetingPoint
        self.optionDurationMinutes = optionDurationMinutes
    }

    func duration(option: String?) -> Int? {
        option.flatMap { optionDurationMinutes[$0] } ?? durationMinutes
    }
}

/// Resolves a contract `productId` to a provider product.
public protocol LocalProductCatalog: Sendable {
    func product(id: String) async -> LocalProduct?
}

/// A catalog held in memory.
public struct StaticProductCatalog: LocalProductCatalog {
    private let products: [String: LocalProduct]

    public init(_ products: [LocalProduct]) {
        self.products = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func product(id: String) async -> LocalProduct? { products[id] }
}

/// Mints the `chk_` and `act_` ids of the local checkout.
public struct LocalIdentifiers: Sendable {
    private let make: @Sendable (String) -> String

    public init(_ make: @escaping @Sendable (_ prefix: String) -> String) {
        self.make = make
    }

    /// The id that starts with `prefix`, such as `chk_` or `act_`.
    public func next(_ prefix: String) -> String { make(prefix) }

    /// Random uppercase ids.
    public static let random = LocalIdentifiers { prefix in
        prefix + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
    }

    /// Hands out `ids` in order, each to the first request for its prefix, and random ids once a prefix runs out.
    public static func sequence(_ ids: [String]) -> LocalIdentifiers {
        let queue = IdentifierQueue(ids)
        return LocalIdentifiers { prefix in queue.take(prefix) ?? random.next(prefix) }
    }
}

private final class IdentifierQueue: @unchecked Sendable {
    private var ids: [String]
    private let lock = NSLock()

    init(_ ids: [String]) { self.ids = ids }

    func take(_ prefix: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = ids.firstIndex(where: { $0.hasPrefix(prefix) }) else { return nil }
        return ids.remove(at: index)
    }
}
