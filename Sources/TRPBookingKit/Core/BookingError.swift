import Foundation

/// Everything a booking call can fail with.
public enum BookingError: Error, Sendable {
    case providerNotConfigured(BookingProviderKind)
    case unsupportedProvider(providerId: Int)
    case invalidActivityId(String)
    /// The provider answered with a non-2xx status; `code` and `message` come from its error body.
    case server(status: Int, code: String?, message: String?)
    case decoding(String)
    case transport(String)
    /// A client-side check rejected the input before any call was made.
    case invalidSelection([String])
    case holdExpired
    case paymentCancelled
    case paymentFailed(String)
    /// The customer was charged but the provider did not confirm; `receipt` is what must be refunded.
    case confirmationFailedAfterCharge(receipt: PaymentReceipt, reference: BookingReference, reason: String)
    case notCancellable(String)
    case rejected(String)
    /// The booking call got no answer and a status probe could not tell either; look it up again later.
    case outcomeUnknown(reference: BookingReference)
    /// The provider refused the hold; `code` says why, e.g. Viator's `rejectionReasonCode`.
    case holdRejected(code: String?)
    /// Too many holds were taken for the same selection; the customer should start over.
    case tooManyHolds
}

extension BookingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .providerNotConfigured(let kind): return "\(kind.rawValue) is not configured."
        case .unsupportedProvider(let id): return "Provider \(id) has no in-app checkout."
        case .invalidActivityId(let raw): return "\(raw) is not a tour-api activity id."
        case .server(let status, let code, let message): return message ?? code ?? "The provider answered \(status)."
        case .decoding(let detail): return "The provider's answer could not be read: \(detail)"
        case .transport(let detail): return detail
        case .invalidSelection(let issues): return issues.joined(separator: "\n")
        case .holdExpired: return "The reservation expired."
        case .paymentCancelled: return "The payment was cancelled."
        case .paymentFailed(let detail): return detail
        case .confirmationFailedAfterCharge(_, _, let reason): return reason
        case .notCancellable(let detail): return detail
        case .rejected(let detail): return detail
        case .outcomeUnknown: return "The booking could not be confirmed yet. We will check it again shortly."
        case .holdRejected(let code): return code.map { "The tour could not be reserved (\($0))." } ?? "The tour could not be reserved."
        case .tooManyHolds: return "The tour could not be reserved. Please choose again."
        }
    }
}
