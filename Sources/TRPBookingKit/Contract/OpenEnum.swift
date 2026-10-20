import Foundation

/// A closed set of contract values with an `unknown` case for anything a newer server may send.
public protocol ContractEnum: RawRepresentable, CaseIterable, Hashable, Sendable where RawValue == String {
    static var unknown: Self { get }
}

extension ContractEnum {

    /// The case for `raw`, or `unknown` when this version does not declare it.
    public init(decoding raw: String) {
        self = Self(rawValue: raw) ?? .unknown
    }
}

extension BookingContract {

    /// A contract enum value that keeps the string it was decoded from.
    ///
    /// An undeclared value reads as `Value.unknown` and is encoded back exactly as it arrived.
    public struct OpenEnum<Value: ContractEnum>: Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ value: Value) {
            self.rawValue = value.rawValue
        }

        public var value: Value { Value(decoding: rawValue) }

        public var isUnknown: Bool { value == .unknown }

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public static func == (lhs: OpenEnum, rhs: Value) -> Bool { lhs.value == rhs }
        public static func == (lhs: Value, rhs: OpenEnum) -> Bool { lhs == rhs.value }
        public static func != (lhs: OpenEnum, rhs: Value) -> Bool { lhs.value != rhs }
    }

    /// `Checkout.status`.
    public enum CheckoutStatus: String, ContractEnum {
        case collectingDetails = "collecting_details"
        case awaitingPayment = "awaiting_payment"
        case processing, confirmed, pending, failed, expired, cancelled
        /// The provider's own page took the customer over; whether they bought anything is not known to us.
        case handedOff = "handed_off"
        case unknown

        /// Whether no further transition will follow.
        public var isTerminal: Bool {
            switch self {
            case .confirmed, .pending, .failed, .expired, .cancelled, .handedOff: return true
            case .collectingDetails, .awaitingPayment, .processing, .unknown: return false
            }
        }
    }

    /// `Booking.status` and `BookingRef.status`.
    public enum BookingStatus: String, ContractEnum {
        case onHold = "on_hold"
        case confirmed, pending, expired, cancelled, rejected, unknown
    }

    /// An entry of `Checkout.allowedActions`.
    public enum AllowedAction: String, ContractEnum {
        case submit, back, extend, cancel, unknown
    }

    /// `NextAction.type`.
    public enum NextActionType: String, ContractEnum {
        case stripePaymentIntent = "stripe_payment_intent"
        case providerHostedForm = "provider_hosted_form"
        case providerHostedCart = "provider_hosted_cart"
        case braintreeDropin = "braintree_dropin"
        case redirect
        case threeDS = "three_ds"
        case unknown
    }

    /// `Block.type`.
    public enum BlockType: String, ContractEnum {
        case date, choice, quantity, field, consent, summary, notice, image, section, unknown
    }

    /// `Field.fieldType`.
    public enum FieldType: String, ContractEnum {
        case text, multiline, email, phone, number, numberWithUnit, date, time, select, multiSelect, country, boolean
        case locationOrText, unknown
    }

    /// What a client does with a block it cannot render.
    public enum OnUnsupported: String, ContractEnum {
        case skip, fallback, unknown
    }

    /// `ConditionClause.op`.
    public enum ConditionOp: String, ContractEnum {
        case `in`, notIn, eq, gt, lt, exists, unknown
    }

    /// `ErrorData.code`.
    public enum ErrorCode: String, ContractEnum {
        case validation = "VALIDATION"
        case stepMismatch = "STEP_MISMATCH"
        case priceChanged = "PRICE_CHANGED"
        case holdExpired = "HOLD_EXPIRED"
        case soldOut = "SOLD_OUT"
        case supplierUnavailable = "SUPPLIER_UNAVAILABLE"
        case paymentDeclined = "PAYMENT_DECLINED"
        case notCancellable = "NOT_CANCELLABLE"
        case inProgress = "IN_PROGRESS"
        case idempotencyMismatch = "IDEMPOTENCY_MISMATCH"
        case versionUnsupported = "VERSION_UNSUPPORTED"
        case unknown
    }

    /// `DateBlock.mode`.
    public enum DateMode: String, ContractEnum {
        case available, range, unknown
    }

    /// `NoticeBlock.tone`.
    public enum NoticeTone: String, ContractEnum {
        case info, warning, critical, unknown
    }

    /// `Field.scope`.
    public enum FieldScope: String, ContractEnum {
        case booking, traveler, unknown
    }

    /// `Voucher.format`.
    public enum VoucherFormat: String, ContractEnum {
        case pdf, qr, barcode, url, unknown
    }

    /// `Cancellation.refund`.
    public enum RefundPolicy: String, ContractEnum {
        case full, partial, none, unknown
    }

    /// `Refund.status`.
    public enum RefundStatus: String, ContractEnum {
        case none, pending, succeeded, failed, unknown
    }

    /// `ActionResult.status`.
    public enum ActionStatus: String, ContractEnum {
        case succeeded, canceled
        /// The customer left a provider page whose outcome is not reported back, see `ProviderHostedCartParams.Settlement.handOff`.
        case handedOff = "handed_off"
        case unknown
    }
}
