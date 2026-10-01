import Foundation

extension BookingContract {

    /// A checkout session: the server's view of where the user is in booking one product.
    public struct Checkout: Codable, Hashable, Sendable {
        public let id: String
        public let status: OpenEnum<CheckoutStatus>
        public let provider: String
        public let product: Product
        public let amount: Money?
        public let holdExpiresAt: String?
        public let priceValidUntil: String?
        public let currentStep: Step?
        public let nextAction: NextAction?
        public let allowedActions: [OpenEnum<AllowedAction>]
        public let booking: BookingRef?
        public let result: CheckoutResult?
        public let fallback: Fallback?

        public init(id: String, status: OpenEnum<CheckoutStatus>, provider: String, product: Product,
                    amount: Money?, holdExpiresAt: String?, priceValidUntil: String?, currentStep: Step?,
                    nextAction: NextAction?, allowedActions: [OpenEnum<AllowedAction>], booking: BookingRef?,
                    result: CheckoutResult?, fallback: Fallback?) {
            self.id = id
            self.status = status
            self.provider = provider
            self.product = product
            self.amount = amount
            self.holdExpiresAt = holdExpiresAt
            self.priceValidUntil = priceValidUntil
            self.currentStep = currentStep
            self.nextAction = nextAction
            self.allowedActions = allowedActions
            self.booking = booking
            self.result = result
            self.fallback = fallback
        }

        /// Whether `action` is in `allowedActions`.
        public func allows(_ action: AllowedAction) -> Bool {
            allowedActions.contains { $0 == action }
        }

        enum CodingKeys: String, CodingKey {
            case id, status, provider, product, amount, holdExpiresAt, priceValidUntil, currentStep, nextAction
            case allowedActions, booking, result, fallback
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(status, forKey: .status)
            try container.encode(provider, forKey: .provider)
            try container.encode(product, forKey: .product)
            try container.encode(amount, forKey: .amount)
            try container.encode(holdExpiresAt, forKey: .holdExpiresAt)
            try container.encode(priceValidUntil, forKey: .priceValidUntil)
            try container.encode(currentStep, forKey: .currentStep)
            try container.encode(nextAction, forKey: .nextAction)
            try container.encode(allowedActions, forKey: .allowedActions)
            try container.encode(booking, forKey: .booking)
            try container.encode(result, forKey: .result)
            try container.encode(fallback, forKey: .fallback)
        }
    }

    /// The product a checkout or booking is for.
    public struct Product: Codable, Hashable, Sendable {
        public let id: String
        public let optionId: String?
        public let title: String
        public let imageUrl: String?

        public init(id: String, optionId: String?, title: String, imageUrl: String?) {
            self.id = id
            self.optionId = optionId
            self.title = title
            self.imageUrl = imageUrl
        }

        enum CodingKeys: String, CodingKey { case id, optionId, title, imageUrl }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(optionId, forKey: .optionId)
            try container.encode(title, forKey: .title)
            try container.encode(imageUrl, forKey: .imageUrl)
        }
    }

    /// The booking a checkout has created, once there is one.
    public struct BookingRef: Codable, Hashable, Sendable {
        public let uuid: String
        public let status: OpenEnum<BookingStatus>

        public init(uuid: String, status: OpenEnum<BookingStatus>) {
            self.uuid = uuid
            self.status = status
        }
    }

    /// The text to show when a checkout reaches a terminal status.
    public struct CheckoutResult: Codable, Hashable, Sendable {
        public let title: String
        public let message: String
        public let bookingUuid: String?

        public init(title: String, message: String, bookingUuid: String?) {
            self.title = title
            self.message = message
            self.bookingUuid = bookingUuid
        }

        enum CodingKeys: String, CodingKey { case title, message, bookingUuid }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try container.encode(message, forKey: .message)
            try container.encode(bookingUuid, forKey: .bookingUuid)
        }
    }

    /// Where to continue when the client cannot render the current step or action.
    public struct Fallback: Codable, Hashable, Sendable {
        public let webUrl: String?
        public let text: String

        public init(webUrl: String?, text: String) {
            self.webUrl = webUrl
            self.text = text
        }

        enum CodingKeys: String, CodingKey { case webUrl, text }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(webUrl, forKey: .webUrl)
            try container.encode(text, forKey: .text)
        }
    }

    /// One screen of the checkout, described as a list of blocks.
    public struct Step: Codable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let subtitle: String?
        public let progress: Progress
        public let blocks: [Block]
        public let primaryAction: PrimaryAction

        public init(id: String, title: String, subtitle: String?, progress: Progress, blocks: [Block],
                    primaryAction: PrimaryAction) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.progress = progress
            self.blocks = blocks
            self.primaryAction = primaryAction
        }

        enum CodingKeys: String, CodingKey { case id, title, subtitle, progress, blocks, primaryAction }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(subtitle, forKey: .subtitle)
            try container.encode(progress, forKey: .progress)
            try container.encode(blocks, forKey: .blocks)
            try container.encode(primaryAction, forKey: .primaryAction)
        }

        /// The step's position; `count` is `nil` while the number of steps is not yet known.
        public struct Progress: Codable, Hashable, Sendable {
            public let index: Int
            public let count: Int?

            public init(index: Int, count: Int?) {
                self.index = index
                self.count = count
            }

            enum CodingKeys: String, CodingKey { case index, count }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(index, forKey: .index)
                try container.encode(count, forKey: .count)
            }
        }
    }

    /// The button that submits a step.
    public struct PrimaryAction: Codable, Hashable, Sendable {
        public let title: String

        public init(title: String) {
            self.title = title
        }
    }
}
