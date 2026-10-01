import Foundation

/// The Tripian booking contract: the provider-neutral checkout and booking resources tour-api serves under `/tour-api`.
///
/// Every type mirrors a schema in the contract's `openapi.yaml` and round-trips its JSON, keeping values this
/// version does not know so a newer server never breaks an older client.
public enum BookingContract {

    /// The contract version this package speaks, sent as `Tripian-Booking-Version`.
    public static let version = "2026-10-01"
}
