import Foundation

extension TRPBooking {
    /// A contract `CheckoutClient` that runs on the device over this instance's checkouts and store.
    /// - Parameters:
    ///   - stripe: creates the PaymentIntent for Toristy checkouts when `configuration.toristyPaymentMode` is `.stripe`;
    ///     without it those products are unavailable. Paid on Toristy's hosted cart, they need no Stripe.
    ///   - braintree: issues the client token for Ticket Evolution checkouts when `configuration.victoryPaymentMode` is
    ///     `.braintreeDropin`; without it those products are unavailable. Paid on TE's hosted checkout, they need no Braintree.
    public func localCheckoutClient(catalog: LocalProductCatalog,
                                    stripe: StripePaymentIntentProviding? = nil,
                                    braintree: BraintreeClientTokenProviding? = nil,
                                    fallbackWebBase: String? = nil,
                                    contractVersion: String = BookingContract.version,
                                    identifiers: LocalIdentifiers = .random,
                                    now: @escaping @Sendable () -> Date = { Date() }) -> LocalCheckoutClient {
        LocalCheckoutClient(viator: viator, toristy: toristy, stripe: stripe,
                            toristyPaymentMode: configuration.toristyPaymentMode, victory: victory, braintree: braintree,
                            victoryPaymentMode: configuration.victoryPaymentMode, store: store, catalog: catalog, contractVersion: contractVersion,
                            fallbackWebBase: fallbackWebBase, identifiers: identifiers, now: now)
    }

    /// A contract `BookingClient` over the bookings this instance's store holds.
    public func localBookingClient(contractVersion: String = BookingContract.version,
                                   now: @escaping @Sendable () -> Date = { Date() }) -> LocalBookingClient {
        LocalBookingClient(store: store, viator: viator, toristy: toristy, contractVersion: contractVersion, now: now)
    }
}
