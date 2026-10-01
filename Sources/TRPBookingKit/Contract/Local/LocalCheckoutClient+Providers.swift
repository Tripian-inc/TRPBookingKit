import Foundation

extension LocalCheckoutClient {
    /// A local checkout over the provider checkouts the host has configured.
    ///
    /// A Toristy product needs `toristy` and `stripe`, a Ticket Evolution product `victory` and `braintree`;
    /// a product whose provider is not configured answers `SUPPLIER_UNAVAILABLE`.
    /// - Parameters:
    ///   - stripe: creates the PaymentIntent a Toristy checkout hands to the client.
    ///   - braintree: issues the client token a Ticket Evolution checkout hands to the client.
    ///   - contractVersion: the version the client sends; anything but `BookingContract.version` is refused.
    ///   - fallbackWebBase: prefix of the web checkout offered as `fallback`, followed by the checkout id.
    ///   - processingWait: how long a payment action waits for Viator before answering `202`.
    public init(viator: ViatorCheckout?,
                toristy: ToristyCheckout? = nil,
                stripe: StripePaymentIntentProviding? = nil,
                victory: VictoryCheckout? = nil,
                braintree: BraintreeClientTokenProviding? = nil,
                store: BookingRecordStore,
                catalog: LocalProductCatalog,
                contractVersion: String = BookingContract.version,
                fallbackWebBase: String? = nil,
                identifiers: LocalIdentifiers = .random,
                processingWait: TimeInterval = 8,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(catalog: catalog, store: store, contractVersion: contractVersion, fallbackWebBase: fallbackWebBase,
                  identifiers: identifiers, now: now) { context in
            switch context.product.provider {
            case .viator: return viator.map { ViatorCheckoutFlow(context: context, viator: $0, processingWait: processingWait) }
            case .toristy:
                guard let toristy, let stripe else { return nil }
                return ToristyCheckoutFlow(context: context, toristy: toristy, stripe: stripe)
            default: return nil
            }
        }
    }
}
