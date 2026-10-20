import Foundation

/// Ticket Evolution's hosted checkout page, where the customer buys a ticket group without the kit placing an order.
///
/// The page reports nothing back to the app, so the outcome of a purchase made there is not known to the kit.
public struct VictoryHostedCheckout: Sendable, Hashable {
    public let baseURL: URL

    /// `nil` when the credentials carry no `checkoutBaseURL`.
    public init?(credentials: VictoryCredentials) {
        guard let baseURL = credentials.checkoutBaseURL else { return nil }
        self.init(baseURL: baseURL)
    }

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// `<base>/checkout/payment/<eventId>/<ticketGroupId>?quantity=<quantity>`, whether or not the base ends in "/".
    public func url(eventId: Int, ticketGroupId: Int, quantity: Int) -> URL {
        let page = baseURL
            .appendingPathComponent("checkout")
            .appendingPathComponent("payment")
            .appendingPathComponent(String(eventId))
            .appendingPathComponent(String(ticketGroupId))
        guard var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return page }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "quantity", value: String(quantity))]
        return components.url ?? page
    }
}
