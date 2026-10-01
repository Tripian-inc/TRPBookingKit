import Foundation

/// Toristy public booking API credentials, read by the host from its own config.
public struct ToristyCredentials: Sendable, Hashable {
    public let apiKey: String
    public let baseURL: URL

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.toristy.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }
}

/// Viator Partner API credentials.
public struct ViatorCredentials: Sendable, Hashable {

    public enum Environment: String, Sendable {
        case sandbox
        case production

        public var baseURL: URL {
            switch self {
            case .sandbox: return URL(string: "https://api.sandbox.viator.com/partner")!
            case .production: return URL(string: "https://api.viator.com/partner")!
            }
        }
    }

    public let apiKey: String
    public let environment: Environment
    public let baseURL: URL
    /// The page that hosts Viator's payment form; its origin is sent as `hostingUrl` in `cart/hold`.
    public let paymentPageURL: URL
    /// Sent as `fraudPreventionDetails.subChannelId` so Viator can tell the host's traffic apart.
    public let subChannelId: String

    public init(apiKey: String, environment: Environment, paymentPageURL: URL, subChannelId: String, baseURL: URL? = nil) {
        self.apiKey = apiKey
        self.environment = environment
        self.paymentPageURL = paymentPageURL
        self.subChannelId = subChannelId
        self.baseURL = baseURL ?? environment.baseURL
    }

    /// `scheme://host[:port]` of `paymentPageURL`, with no trailing slash.
    public var hostingOrigin: String {
        Self.origin(of: paymentPageURL)
    }

    /// `scheme://host[:port]` of `url`, with no trailing slash.
    static func origin(of url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host else { return url.absoluteString }
        return components.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
}

/// Ticket Evolution (Victory) credentials; every request is HMAC-signed with `secret`.
public struct VictoryCredentials: Sendable, Hashable {

    public enum Environment: String, Sendable {
        case sandbox
        case production

        public var baseURL: URL {
            switch self {
            case .sandbox: return URL(string: "https://api.sandbox.ticketevolution.com")!
            case .production: return URL(string: "https://api.ticketevolution.com")!
            }
        }
    }

    public let token: String
    public let secret: String
    public let environment: Environment
    public let baseURL: URL
    /// The office that sells the tickets, required when creating clients and orders.
    public let officeId: Int?

    public init(token: String, secret: String, environment: Environment, officeId: Int? = nil, baseURL: URL? = nil) {
        self.token = token
        self.secret = secret
        self.environment = environment
        self.officeId = officeId
        self.baseURL = baseURL ?? environment.baseURL
    }
}

/// Everything TRPBookingKit needs from the host: which tour-api provider ids map to which
/// provider, and the credentials of each provider the host has enabled.
///
/// Keys are never bundled with the SDK; a provider left without credentials is simply not bookable.
public struct BookingConfiguration: Sendable {
    public var registry: BookingProviderRegistry
    public var toristy: ToristyCredentials?
    public var viator: ViatorCredentials?
    public var victory: VictoryCredentials?
    /// Currency asked for when a provider lets the caller choose.
    public var preferredCurrency: String
    /// Customer language, sent where the provider supports it.
    public var languageCode: String

    public init(registry: BookingProviderRegistry,
                toristy: ToristyCredentials? = nil,
                viator: ViatorCredentials? = nil,
                victory: VictoryCredentials? = nil,
                preferredCurrency: String = "EUR",
                languageCode: String = "en") {
        self.registry = registry
        self.toristy = toristy
        self.viator = viator
        self.victory = victory
        self.preferredCurrency = preferredCurrency
        self.languageCode = languageCode
    }

    /// Whether the provider has credentials and so can be booked in the app.
    public func isEnabled(_ kind: BookingProviderKind) -> Bool {
        switch kind {
        case .toristy: return toristy != nil
        case .viator: return viator != nil
        case .victory: return victory != nil
        }
    }
}
