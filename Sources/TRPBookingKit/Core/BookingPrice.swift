import Foundation

/// A price as tour-api and the providers report it, where a missing or non-positive amount means free.
public struct BookingPrice: Hashable, Sendable {

    public let amount: Decimal?
    public let currency: String?

    public init(amount: Decimal?, currency: String?) {
        self.amount = amount
        self.currency = currency
    }

    /// The tour-api rule: `current_price` wins over `price` when present.
    public static func effective(price: Decimal?, currentPrice: Decimal?, currency: String?) -> BookingPrice {
        BookingPrice(amount: currentPrice ?? price, currency: currency)
    }

    public var isFree: Bool {
        guard let amount else { return true }
        return amount <= 0
    }

    /// The amount formatted for display, or `freeText` when the price is free.
    public func formatted(locale: Locale = .current, freeText: String) -> String {
        guard !isFree, let amount else { return freeText }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        if let currency { formatter.currencyCode = currency }
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }
}
