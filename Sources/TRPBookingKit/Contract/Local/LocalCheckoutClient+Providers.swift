import Foundation

extension LocalCheckoutClient {
    /// A local checkout over the provider checkouts the host has configured.
    ///
    /// A Toristy product needs `toristy` and, paid through Stripe, `stripe`; paid on Toristy's hosted cart it needs
    /// a `toristy` with a `hostedCart`. A Ticket Evolution product needs `victory` with a `hostedCheckout` when paid on
    /// TE's hosted checkout, or `victory` and `braintree` when paid through a Braintree Drop-in;
    /// a product whose provider is not configured answers `SUPPLIER_UNAVAILABLE`.
    /// - Parameters:
    ///   - stripe: creates the PaymentIntent a Toristy checkout hands to the client.
    ///   - toristyPaymentMode: how a Toristy checkout is paid.
    ///   - braintree: issues the client token a Ticket Evolution checkout paid through a Braintree Drop-in hands to the client.
    ///   - victoryPaymentMode: how a Ticket Evolution checkout is paid; `.braintreeDropin` unless set to `.hostedCheckout`.
    ///   - contractVersion: the version the client sends; anything but `BookingContract.version` is refused.
    ///   - fallbackWebBase: prefix of the web checkout offered as `fallback`, followed by the checkout id.
    ///   - processingWait: how long a payment action waits for Viator before answering `202`.
    public init(viator: ViatorCheckout?,
                toristy: ToristyCheckout? = nil,
                stripe: StripePaymentIntentProviding? = nil,
                toristyPaymentMode: ToristyPaymentMode = .stripe,
                victory: VictoryCheckout? = nil,
                braintree: BraintreeClientTokenProviding? = nil,
                victoryPaymentMode: VictoryPaymentMode = .braintreeDropin,
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
                guard let toristy else { return nil }
                switch toristyPaymentMode {
                case .hostedCart:
                    return toristy.hostedCart.map { ToristyHostedCartCheckoutFlow(context: context, toristy: toristy, cart: $0) }
                case .stripe:
                    return stripe.map { ToristyCheckoutFlow(context: context, toristy: toristy, stripe: $0) }
                }
            case .victory:
                guard let victory else { return nil }
                switch victoryPaymentMode {
                case .hostedCheckout:
                    return victory.hostedCheckout.map { VictoryHostedCheckoutFlow(context: context, victory: victory, hosted: $0) }
                case .braintreeDropin:
                    return braintree.map { VictoryCheckoutFlow(context: context, victory: victory, braintree: $0) }
                }
            default: return nil
            }
        }
    }
}
