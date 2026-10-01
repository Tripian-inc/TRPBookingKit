import Foundation

/// A Stripe PaymentIntent the device confirms with the Stripe SDK.
public struct StripePaymentIntent: Sendable, Hashable {
    public let id: String
    public let clientSecret: String
    public let publishableKey: String
    public let merchantName: String

    public init(id: String, clientSecret: String, publishableKey: String, merchantName: String) {
        self.id = id
        self.clientSecret = clientSecret
        self.publishableKey = publishableKey
        self.merchantName = merchantName
    }
}

/// Stripe payment split in two: the intent is created first and confirmed on the device.
///
/// `charge(_:)` does not take money again: it returns the receipt of the intent the device already
/// confirmed for the same request.
public protocol StripePaymentIntentProviding: PaymentProcessing {
    func paymentIntent(for request: PaymentRequest) async throws -> StripePaymentIntent
}

/// Hands out the Braintree client token the Drop-in UI starts with.
public protocol BraintreeClientTokenProviding: Sendable {
    func clientToken() async throws -> String
}
