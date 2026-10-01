import Foundation

extension LocalCheckoutClient {
    /// A local checkout over the provider checkouts the host has configured.
    ///
    /// Only Viator products run a flow so far; a Toristy or Ticket Evolution product answers
    /// `SUPPLIER_UNAVAILABLE`, as does a product whose provider is not configured.
    /// - Parameters:
    ///   - contractVersion: the version the client sends; anything but `BookingContract.version` is refused.
    ///   - fallbackWebBase: prefix of the web checkout offered as `fallback`, followed by the checkout id.
    ///   - processingWait: how long a payment action waits for Viator before answering `202`.
    public init(viator: ViatorCheckout?,
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
            default: return nil
            }
        }
    }
}
