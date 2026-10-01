import Foundation

extension TRPBooking {
    /// A contract `CheckoutClient` that runs on the device over this instance's checkouts and store.
    public func localCheckoutClient(catalog: LocalProductCatalog,
                                    fallbackWebBase: String? = nil,
                                    contractVersion: String = BookingContract.version,
                                    identifiers: LocalIdentifiers = .random,
                                    now: @escaping @Sendable () -> Date = { Date() }) -> LocalCheckoutClient {
        LocalCheckoutClient(viator: viator, store: store, catalog: catalog, contractVersion: contractVersion,
                            fallbackWebBase: fallbackWebBase, identifiers: identifiers, now: now)
    }

    /// A contract `BookingClient` over the bookings this instance's store holds.
    public func localBookingClient(contractVersion: String = BookingContract.version,
                                   now: @escaping @Sendable () -> Date = { Date() }) -> LocalBookingClient {
        LocalBookingClient(store: store, viator: viator, toristy: toristy, contractVersion: contractVersion, now: now)
    }
}
