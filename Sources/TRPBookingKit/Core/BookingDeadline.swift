import Foundation

/// An absolute expiry for a hold or cart.
///
/// Remaining time is always derived from the wall clock, so a countdown stays right after the
/// app returns from the background.
public struct BookingDeadline: Hashable, Sendable, Codable {

    public let expiresAt: Date

    public init(expiresAt: Date) {
        self.expiresAt = expiresAt
    }

    /// The earliest of several expiries, as Viator's hold requires; `nil` for an empty list.
    public init?(earliestOf dates: [Date]) {
        guard let earliest = dates.min() else { return nil }
        self.init(expiresAt: earliest)
    }

    public func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(now))
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        remaining(at: now) <= 0
    }

    /// Whether fewer than `threshold` seconds are left, for the "hurry up" warning.
    public func isEndingSoon(threshold: TimeInterval, at now: Date = Date()) -> Bool {
        !isExpired(at: now) && remaining(at: now) <= threshold
    }
}
