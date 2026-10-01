import Foundation

extension BookingContract {

    /// What the client must do outside the step form, usually take a payment, discriminated by `type`.
    ///
    /// A type this version does not know decodes to `unknown`, keeping the whole object; the client then sends the
    /// user to `Checkout.fallback`.
    public enum NextAction: Codable, Hashable, Sendable {
        case stripePaymentIntent(Payload<StripePaymentIntentParams>)
        case providerHostedForm(Payload<ProviderHostedFormParams>)
        case braintreeDropin(Payload<BraintreeDropinParams>)
        case redirect(Payload<RedirectParams>)
        case threeDS(Payload<[String: JSONValue]>)
        case unknown(type: String, raw: JSONValue)

        enum CodingKeys: String, CodingKey { case type }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch NextActionType(decoding: type) {
            case .stripePaymentIntent: self = .stripePaymentIntent(try Payload(from: decoder))
            case .providerHostedForm: self = .providerHostedForm(try Payload(from: decoder))
            case .braintreeDropin: self = .braintreeDropin(try Payload(from: decoder))
            case .redirect: self = .redirect(try Payload(from: decoder))
            case .threeDS: self = .threeDS(try Payload(from: decoder))
            case .unknown: self = .unknown(type: type, raw: try JSONValue(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .stripePaymentIntent(let payload): try encodeTagged(payload, to: encoder)
            case .providerHostedForm(let payload): try encodeTagged(payload, to: encoder)
            case .braintreeDropin(let payload): try encodeTagged(payload, to: encoder)
            case .redirect(let payload): try encodeTagged(payload, to: encoder)
            case .threeDS(let payload): try encodeTagged(payload, to: encoder)
            case .unknown(_, let raw): try raw.encode(to: encoder)
            }
        }

        private func encodeTagged<Params: Codable & Hashable & Sendable>(_ payload: Payload<Params>, to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(typeRawValue, forKey: .type)
            try payload.encode(to: encoder)
        }

        /// The `type` as sent, including an unknown one.
        public var typeRawValue: String {
            switch self {
            case .stripePaymentIntent: return NextActionType.stripePaymentIntent.rawValue
            case .providerHostedForm: return NextActionType.providerHostedForm.rawValue
            case .braintreeDropin: return NextActionType.braintreeDropin.rawValue
            case .redirect: return NextActionType.redirect.rawValue
            case .threeDS: return NextActionType.threeDS.rawValue
            case .unknown(let type, _): return type
            }
        }

        /// The action id, used in `POST /checkouts/{id}/actions/{actionId}`.
        public var id: String {
            switch self {
            case .stripePaymentIntent(let payload): return payload.id
            case .providerHostedForm(let payload): return payload.id
            case .braintreeDropin(let payload): return payload.id
            case .redirect(let payload): return payload.id
            case .threeDS(let payload): return payload.id
            case .unknown(_, let raw): return raw.objectValue?["id"]?.stringValue ?? ""
            }
        }

        /// The keys every action shares; `Params` is the type-specific `params` object.
        public struct Payload<Params: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
            public let id: String
            public let params: Params
            public let expiresAt: String?

            public init(id: String, params: Params, expiresAt: String? = nil) {
                self.id = id
                self.params = params
                self.expiresAt = expiresAt
            }
        }
    }

    /// `stripe_payment_intent` parameters for the Stripe PaymentSheet.
    public struct StripePaymentIntentParams: Codable, Hashable, Sendable {
        public let clientSecret: String
        public let publishableKey: String
        public let merchantName: String

        public init(clientSecret: String, publishableKey: String, merchantName: String) {
            self.clientSecret = clientSecret
            self.publishableKey = publishableKey
            self.merchantName = merchantName
        }
    }

    /// `provider_hosted_form` parameters, such as the Viator payment session.
    public struct ProviderHostedFormParams: Codable, Hashable, Sendable {
        public let paymentSessionToken: String

        public init(paymentSessionToken: String) {
            self.paymentSessionToken = paymentSessionToken
        }
    }

    /// `braintree_dropin` parameters.
    public struct BraintreeDropinParams: Codable, Hashable, Sendable {
        public let clientToken: String
        public let amount: Money?

        public init(clientToken: String, amount: Money? = nil) {
            self.clientToken = clientToken
            self.amount = amount
        }
    }

    /// `redirect` parameters: open `url` and finish when the browser reaches `returnUrl`.
    public struct RedirectParams: Codable, Hashable, Sendable {
        public let url: String
        public let returnUrl: String

        public init(url: String, returnUrl: String) {
            self.url = url
            self.returnUrl = returnUrl
        }
    }

    /// The outcome of a `NextAction`, sent to `POST /checkouts/{id}/actions/{actionId}`.
    ///
    /// Keys the contract does not name, such as the three-D Secure results, are kept in `additional`.
    public struct ActionResult: Codable, Hashable, Sendable {
        public let status: OpenEnum<ActionStatus>?
        public let paymentToken: String?
        public let nonce: String?
        public let deviceData: String?
        public let returnedUrl: String?
        public let additional: [String: JSONValue]

        public init(status: OpenEnum<ActionStatus>? = nil, paymentToken: String? = nil, nonce: String? = nil,
                    deviceData: String? = nil, returnedUrl: String? = nil, additional: [String: JSONValue] = [:]) {
            self.status = status
            self.paymentToken = paymentToken
            self.nonce = nonce
            self.deviceData = deviceData
            self.returnedUrl = returnedUrl
            self.additional = additional
        }

        /// A Stripe outcome, or a cancellation of any action.
        public static func status(_ status: ActionStatus) -> ActionResult {
            ActionResult(status: OpenEnum(status))
        }

        /// A provider hosted form's payment token.
        public static func paymentToken(_ token: String) -> ActionResult {
            ActionResult(paymentToken: token)
        }

        /// A Braintree Drop-in nonce with its device data.
        public static func braintree(nonce: String, deviceData: String) -> ActionResult {
            ActionResult(nonce: nonce, deviceData: deviceData)
        }

        /// The URL the redirect came back to.
        public static func returned(url: String) -> ActionResult {
            ActionResult(returnedUrl: url)
        }

        /// The values the three-D Secure SDK reported, passed through as they are.
        public static func threeDS(_ values: [String: JSONValue]) -> ActionResult {
            ActionResult(additional: values)
        }

        private static let namedKeys: Set<String> = ["status", "paymentToken", "nonce", "deviceData", "returnedUrl"]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: ContractDynamicKey.self)
            status = try container.decodeIfPresent(OpenEnum<ActionStatus>.self, forKey: ContractDynamicKey("status"))
            paymentToken = try container.decodeIfPresent(String.self, forKey: ContractDynamicKey("paymentToken"))
            nonce = try container.decodeIfPresent(String.self, forKey: ContractDynamicKey("nonce"))
            deviceData = try container.decodeIfPresent(String.self, forKey: ContractDynamicKey("deviceData"))
            returnedUrl = try container.decodeIfPresent(String.self, forKey: ContractDynamicKey("returnedUrl"))
            var additional: [String: JSONValue] = [:]
            for key in container.allKeys where !Self.namedKeys.contains(key.stringValue) {
                additional[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
            self.additional = additional
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: ContractDynamicKey.self)
            try container.encodeIfPresent(status, forKey: ContractDynamicKey("status"))
            try container.encodeIfPresent(paymentToken, forKey: ContractDynamicKey("paymentToken"))
            try container.encodeIfPresent(nonce, forKey: ContractDynamicKey("nonce"))
            try container.encodeIfPresent(deviceData, forKey: ContractDynamicKey("deviceData"))
            try container.encodeIfPresent(returnedUrl, forKey: ContractDynamicKey("returnedUrl"))
            for (key, value) in additional where !Self.namedKeys.contains(key) {
                try container.encode(value, forKey: ContractDynamicKey(key))
            }
        }
    }
}
