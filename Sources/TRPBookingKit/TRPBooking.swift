import Foundation

/// A tour-api activity resolved to the provider product that books it.
public enum BookableActivity: Sendable, Hashable {
    case toristy(serviceId: Int)
    case viator(productCode: String)
    case victory(eventId: Int)

    public var provider: BookingProviderKind {
        switch self {
        case .toristy: return .toristy
        case .viator: return .viator
        case .victory: return .victory
        }
    }
}

/// The entry point of the kit: builds a checkout for every configured provider and routes a
/// tour-api activity id to the one that books it.
///
/// A host without Tripian's screens drives the checkouts directly; the screens use the same ones.
public final class TRPBooking: Sendable {

    public let configuration: BookingConfiguration
    public let store: BookingRecordStore
    /// `nil` unless Toristy has credentials and the host supplied a `PaymentProcessing`.
    public let toristy: ToristyCheckout?
    public let viator: ViatorCheckout?
    public let victory: VictoryCheckout?

    /// - Parameters:
    ///   - toristyPayment: charges the customer for Toristy, which leaves payment to us.
    ///   - victoryAuthorizer: signs Victory requests; pass the host's own to sign on a backend
    ///     proxy set as `VictoryCredentials.baseURL`. `nil` signs on the device.
    public init(configuration: BookingConfiguration,
                store: BookingRecordStore = UserDefaultsBookingRecordStore(),
                toristyPayment: PaymentProcessing? = nil,
                victoryAuthorizer: RequestAuthorizing? = nil,
                transport: HTTPTransport = URLSessionHTTPTransport(),
                backgroundTasks: BackgroundTaskRunning = BookingConfiguration.defaultBackgroundTaskRunner) {
        self.configuration = configuration
        self.store = store
        toristy = zip(configuration.toristy, toristyPayment).map { credentials, payment in
            ToristyCheckout(service: ToristyAPIClient(credentials: credentials, transport: transport),
                            payment: payment, store: store, backgroundTasks: backgroundTasks)
        }
        viator = configuration.viator.map { credentials in
            ViatorCheckout(service: ViatorAPIClient(credentials: credentials, languageCode: configuration.languageCode, transport: transport),
                           store: store, backgroundTasks: backgroundTasks)
        }
        victory = configuration.victory.map { credentials in
            VictoryCheckout(service: VictoryAPIClient(credentials: credentials, authorizer: victoryAuthorizer, transport: transport),
                            store: store, backgroundTasks: backgroundTasks)
        }
    }

    /// Resolves a tour-api activity id.
    ///
    /// Throws `.invalidActivityId` for a malformed id, `.unsupportedProvider` for a provider the
    /// registry does not know and `.providerNotConfigured` for one without a checkout.
    public func activity(for activityId: String) throws -> BookableActivity {
        guard let id = TRPActivityId(activityId) else { throw BookingError.invalidActivityId(activityId) }
        guard let kind = configuration.registry.kind(forProviderId: id.providerId) else {
            throw BookingError.unsupportedProvider(providerId: id.providerId)
        }
        guard isAvailable(kind) else { throw BookingError.providerNotConfigured(kind) }
        switch kind {
        case .toristy:
            guard let serviceId = Int(id.productId) else { throw BookingError.invalidActivityId(activityId) }
            return .toristy(serviceId: serviceId)
        case .viator:
            return .viator(productCode: id.productId)
        case .victory:
            guard let eventId = Int(id.productId) else { throw BookingError.invalidActivityId(activityId) }
            return .victory(eventId: eventId)
        }
    }

    /// Whether the activity can be booked in the app rather than on the provider's site.
    public func canBook(activityId: String) -> Bool {
        (try? activity(for: activityId)) != nil
    }

    public func isAvailable(_ kind: BookingProviderKind) -> Bool {
        switch kind {
        case .toristy: return toristy != nil
        case .viator: return viator != nil
        case .victory: return victory != nil
        }
    }

    /// Settles bookings left charged or pending by a lost answer or a killed app; call at launch.
    @discardableResult
    public func resolveUnfinished() async -> [BookingRecord] {
        _ = await toristy?.resolveUnfinished()
        _ = await viator?.resolveUnfinished()
        _ = await victory?.resolveUnfinished()
        return await store.all()
    }

    public func records() async -> [BookingRecord] {
        await store.all()
    }
}

private func zip<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
    guard let first, let second else { return nil }
    return (first, second)
}
