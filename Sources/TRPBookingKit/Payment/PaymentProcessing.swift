import Foundation

/// What to charge, handed to the host's payment adapter.
public struct PaymentRequest: Sendable, Hashable {
    public let amount: Decimal
    /// ISO 4217, upper case.
    public let currency: String
    public let description: String
    /// The provider's booking reference, so the charge can be traced back to it.
    public let reference: BookingReference
    public let customerEmail: String?

    public init(amount: Decimal, currency: String, description: String, reference: BookingReference, customerEmail: String? = nil) {
        self.amount = amount
        self.currency = currency.uppercased()
        self.description = description
        self.reference = reference
        self.customerEmail = customerEmail
    }

    /// The amount in the currency's minor unit, as Stripe expects it.
    public var minorUnitAmount: Int {
        let digits = PaymentRequest.zeroDecimalCurrencies.contains(currency) ? 0 : 2
        var scaled = amount * pow(10, digits)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    static let zeroDecimalCurrencies: Set<String> = ["BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA", "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF"]
}

/// The outcome of a successful charge. Holds no card data beyond brand and last four digits.
public struct PaymentReceipt: Sendable, Hashable, Codable {
    /// The processor's id for the charge, needed to refund it.
    public let chargeId: String
    public let amount: Decimal
    public let currency: String
    public let cardBrand: String?
    public let last4: String?
    public let paidAt: Date

    public init(chargeId: String, amount: Decimal, currency: String, cardBrand: String?, last4: String?, paidAt: Date = Date()) {
        self.chargeId = chargeId
        self.amount = amount
        self.currency = currency
        self.cardBrand = cardBrand
        self.last4 = last4
        self.paidAt = paidAt
    }
}

/// Charges the customer for providers that leave payment to us (Toristy Option B).
///
/// Implementations present their own UI where needed and throw `BookingError.paymentCancelled`
/// when the customer backs out.
public protocol PaymentProcessing: Sendable {
    func charge(_ request: PaymentRequest) async throws -> PaymentReceipt
    /// Returns the customer's money after the provider failed to confirm a paid booking.
    func refund(_ receipt: PaymentReceipt, reason: String) async throws
}

/// Produces a one-time payment nonce for providers that charge on their side (Victory/Braintree).
///
/// The nonce is used once and never stored.
public protocol PaymentNonceProviding: Sendable {
    func nonce(amount: Decimal, currency: String) async throws -> String
}
