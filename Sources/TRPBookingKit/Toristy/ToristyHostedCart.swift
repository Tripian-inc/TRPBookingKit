import Foundation

/// Toristy's hosted cart page, where the customer pays for a cart the kit reserved.
///
/// The page reports nothing back to the app; whether the cart was paid is read from `bookingdata`.
/// Its URL carries the API key, so it must never be logged.
public struct ToristyHostedCart: Sendable, Hashable, CustomStringConvertible {
    public let pageURL: URL
    public let hostOrigin: String
    private let apiKey: String

    public init(credentials: ToristyCredentials) {
        self.init(apiKey: credentials.apiKey, pageURL: credentials.hostedCartURL, hostOrigin: credentials.hostedCartHostOrigin)
    }

    public init(apiKey: String, pageURL: URL, hostOrigin: String) {
        self.apiKey = apiKey
        self.pageURL = pageURL
        self.hostOrigin = hostOrigin
    }

    /// The page showing `cartId`, with `languageCode` mapped onto the languages the page serves and `currency`
    /// the cart's own.
    public func url(cartId: String, languageCode: String, currency: String) -> URL? {
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
        let items = [("apikey", apiKey), ("cartid", cartId), ("host", hostOrigin),
                     ("lang", ToristyAPIClient.hostedCartLanguage(for: languageCode)), ("currency", currency)]
        components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? [])
            + items.map { URLQueryItem(name: $0.0, value: Self.encode($0.1)) }
        return components.url
    }

    public var description: String {
        "ToristyHostedCart(pageURL: \(pageURL), hostOrigin: \(hostOrigin))"
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
