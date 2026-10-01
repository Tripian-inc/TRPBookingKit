import Foundation

extension BookingContract {

    /// One element of a step, discriminated by `type`.
    ///
    /// A type this version does not know decodes to `unknown`, which keeps the whole object so the client can apply
    /// `onUnsupported` and the value encodes back unchanged.
    public enum Block: Codable, Hashable, Sendable {
        case date(DateBlock)
        case choice(ChoiceBlock)
        case quantity(QuantityBlock)
        case field(Field)
        case consent(ConsentBlock)
        case summary(SummaryBlock)
        case notice(NoticeBlock)
        case image(ImageBlock)
        case section(SectionBlock)
        case unknown(type: String, raw: JSONValue)

        enum CodingKeys: String, CodingKey { case type, id, onUnsupported }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch BlockType(decoding: type) {
            case .date: self = .date(try DateBlock(from: decoder))
            case .choice: self = .choice(try ChoiceBlock(from: decoder))
            case .quantity: self = .quantity(try QuantityBlock(from: decoder))
            case .field: self = .field(try Field(from: decoder))
            case .consent: self = .consent(try ConsentBlock(from: decoder))
            case .summary: self = .summary(try SummaryBlock(from: decoder))
            case .notice: self = .notice(try NoticeBlock(from: decoder))
            case .image: self = .image(try ImageBlock(from: decoder))
            case .section: self = .section(try SectionBlock(from: decoder))
            case .unknown: self = .unknown(type: type, raw: try JSONValue(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .date(let block): try encodeTagged(block, to: encoder)
            case .choice(let block): try encodeTagged(block, to: encoder)
            case .quantity(let block): try encodeTagged(block, to: encoder)
            case .field(let field): try field.encode(to: encoder)
            case .consent(let block): try encodeTagged(block, to: encoder)
            case .summary(let block): try encodeTagged(block, to: encoder)
            case .notice(let block): try encodeTagged(block, to: encoder)
            case .image(let block): try encodeTagged(block, to: encoder)
            case .section(let block): try encodeTagged(block, to: encoder)
            case .unknown(_, let raw): try raw.encode(to: encoder)
            }
        }

        private func encodeTagged<Payload: Encodable>(_ payload: Payload, to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(typeRawValue, forKey: .type)
            try payload.encode(to: encoder)
        }

        /// The `type` as sent, including an unknown one.
        public var typeRawValue: String {
            switch self {
            case .date: return BlockType.date.rawValue
            case .choice: return BlockType.choice.rawValue
            case .quantity: return BlockType.quantity.rawValue
            case .field: return BlockType.field.rawValue
            case .consent: return BlockType.consent.rawValue
            case .summary: return BlockType.summary.rawValue
            case .notice: return BlockType.notice.rawValue
            case .image: return BlockType.image.rawValue
            case .section: return BlockType.section.rawValue
            case .unknown(let type, _): return type
            }
        }

        /// The block id, which is also the key of its answer.
        public var id: String {
            switch self {
            case .date(let block): return block.id
            case .choice(let block): return block.id
            case .quantity(let block): return block.id
            case .field(let field): return field.id
            case .consent(let block): return block.id
            case .summary(let block): return block.id
            case .notice(let block): return block.id
            case .image(let block): return block.id
            case .section(let block): return block.id
            case .unknown(_, let raw): return raw.objectValue?["id"]?.stringValue ?? ""
            }
        }

        /// What to do with this block when it cannot be rendered; the contract default is `fallback`.
        public var onUnsupported: OnUnsupported {
            let raw: OpenEnum<OnUnsupported>?
            switch self {
            case .date(let block): raw = block.onUnsupported
            case .choice(let block): raw = block.onUnsupported
            case .quantity(let block): raw = block.onUnsupported
            case .field(let field): raw = field.onUnsupported
            case .consent(let block): raw = block.onUnsupported
            case .summary(let block): raw = block.onUnsupported
            case .notice(let block): raw = block.onUnsupported
            case .image(let block): raw = block.onUnsupported
            case .section(let block): raw = block.onUnsupported
            case .unknown(_, let json): raw = json.objectValue?["onUnsupported"]?.stringValue.map(OpenEnum.init(rawValue:))
            }
            guard let value = raw?.value, value != .unknown else { return .fallback }
            return value
        }
    }

    /// Picks a date, from a calendar window or a list of available dates.
    public struct DateBlock: Codable, Hashable, Sendable {
        public let id: String
        public let onUnsupported: OpenEnum<OnUnsupported>?
        public let requires: [String: JSONValue]?
        public let mode: OpenEnum<DateMode>
        public let range: DateRange?
        public let dates: [String]?
        public let min: String?
        public let max: String?
        public let defaultValue: String?

        public init(id: String, onUnsupported: OpenEnum<OnUnsupported>? = nil, requires: [String: JSONValue]? = nil,
                    mode: OpenEnum<DateMode>, range: DateRange? = nil, dates: [String]? = nil, min: String? = nil,
                    max: String? = nil, defaultValue: String? = nil) {
            self.id = id
            self.onUnsupported = onUnsupported
            self.requires = requires
            self.mode = mode
            self.range = range
            self.dates = dates
            self.min = min
            self.max = max
            self.defaultValue = defaultValue
        }

        /// An inclusive calendar window, as `yyyy-MM-dd` strings.
        public struct DateRange: Codable, Hashable, Sendable {
            public let from: String
            public let to: String

            public init(from: String, to: String) {
                self.from = from
                self.to = to
            }
        }
    }

    /// A single or multiple choice among options.
    public struct ChoiceBlock: Codable, Hashable, Sendable {
        public let id: String
        public let onUnsupported: OpenEnum<OnUnsupported>?
        public let requires: [String: JSONValue]?
        public let options: [Option]
        public let multiple: Bool?
        public let defaultValue: Selection?

        public init(id: String, onUnsupported: OpenEnum<OnUnsupported>? = nil, requires: [String: JSONValue]? = nil,
                    options: [Option], multiple: Bool? = nil, defaultValue: Selection? = nil) {
            self.id = id
            self.onUnsupported = onUnsupported
            self.requires = requires
            self.options = options
            self.multiple = multiple
            self.defaultValue = defaultValue
        }

        /// One option of a choice.
        public struct Option: Codable, Hashable, Sendable {
            public let value: String
            public let title: String
            public let subtitle: String?
            public let price: Money?
            public let badge: String?
            public let disabled: Bool?

            public init(value: String, title: String, subtitle: String? = nil, price: Money? = nil,
                        badge: String? = nil, disabled: Bool? = nil) {
                self.value = value
                self.title = title
                self.subtitle = subtitle
                self.price = price
                self.badge = badge
                self.disabled = disabled
            }
        }

        /// The selected value of a single choice or the values of a multiple one.
        public enum Selection: Codable, Hashable, Sendable {
            case single(String)
            case multiple([String])

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let values = try? container.decode([String].self) {
                    self = .multiple(values)
                } else {
                    self = .single(try container.decode(String.self))
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .single(let value): try container.encode(value)
                case .multiple(let values): try container.encode(values)
                }
            }
        }
    }

    /// Counts per unit (adult, child, ticket…); its answer is `{unitId: count}`.
    public struct QuantityBlock: Codable, Hashable, Sendable {
        public let id: String
        public let onUnsupported: OpenEnum<OnUnsupported>?
        public let requires: [String: JSONValue]?
        public let items: [Item]
        public let total: Total
        public let defaultValue: [String: Int]?

        public init(id: String, onUnsupported: OpenEnum<OnUnsupported>? = nil, requires: [String: JSONValue]? = nil,
                    items: [Item], total: Total, defaultValue: [String: Int]? = nil) {
            self.id = id
            self.onUnsupported = onUnsupported
            self.requires = requires
            self.items = items
            self.total = total
            self.defaultValue = defaultValue
        }

        /// One unit row; `allowed`, when present, lists the only counts the unit accepts.
        public struct Item: Codable, Hashable, Sendable {
            public let unitId: String
            public let title: String
            public let subtitle: String?
            public let price: Money?
            public let min: Int
            public let max: Int
            public let allowed: [Int]?

            public init(unitId: String, title: String, subtitle: String? = nil, price: Money? = nil, min: Int,
                        max: Int, allowed: [Int]? = nil) {
                self.unitId = unitId
                self.title = title
                self.subtitle = subtitle
                self.price = price
                self.min = min
                self.max = max
                self.allowed = allowed
            }
        }

        /// Limits on the sum of all units.
        public struct Total: Codable, Hashable, Sendable {
            public let min: Int
            public let max: Int

            public init(min: Int, max: Int) {
                self.min = min
                self.max = max
            }
        }
    }

    /// A checkbox the user must or may tick, such as the terms.
    public struct ConsentBlock: Codable, Hashable, Sendable {
        public let id: String
        public let onUnsupported: OpenEnum<OnUnsupported>?
        public let requires: [String: JSONValue]?
        public let text: String
        public let links: [Link]?
        public let required: Bool
        public let defaultValue: Bool?

        public init(id: String, onUnsupported: OpenEnum<OnUnsupported>? = nil, requires: [String: JSONValue]? = nil,
                    text: String, links: [Link]? = nil, required: Bool, defaultValue: Bool? = nil) {
            self.id = id
            self.onUnsupported = onUnsupported
            self.requires = requires
            self.text = text
            self.links = links
            self.required = required
            self.defaultValue = defaultValue
        }

        /// A document the consent text refers to.
        public struct Link: Codable, Hashable, Sendable {
            public let title: String
            public let url: String

            public init(title: String, url: String) {
                self.title = title
                self.url = url
            }
        }
    }

    /// The price breakdown before payment.
    public struct SummaryBlock: Codable, Hashable, Sendable {
        public let id: String
        public let onUnsupported: OpenEnum<OnUnsupported>?
        public let requires: [String: JSONValue]?
        public let lines: [Line]
        public let total: Money
        public let note: String?

        public init(id: String, onUnsupported: OpenEnum<OnUnsupported>? = nil, requires: [String: JSONValue]? = nil,
                    lines: [Line], total: Money, note: String? = nil) {
            self.id = id
            self.onUnsupported = onUnsupported
            self.requires = requires
            self.lines = lines
            self.total = total
            self.note = note
        }

        /// One row of the breakdown.
        public struct Line: Codable, Hashable, Sendable {
            public let title: String
            public let detail: String?
            public let amount: Money?

            public init(title: String, detail: String? = nil, amount: Money? = nil) {
                self.title = title
                self.detail = detail
                self.amount = amount
            }
        }
    }

    /// Read-only text with a tone.
    public struct NoticeBlock: Codable, Hashable, Sendable {
        public let id: String
        public let onUnsupported: OpenEnum<OnUnsupported>?
        public let requires: [String: JSONValue]?
        public let tone: OpenEnum<NoticeTone>
        public let text: String

        public init(id: String, onUnsupported: OpenEnum<OnUnsupported>? = nil, requires: [String: JSONValue]? = nil,
                    tone: OpenEnum<NoticeTone>, text: String) {
            self.id = id
            self.onUnsupported = onUnsupported
            self.requires = requires
            self.tone = tone
            self.text = text
        }
    }

    /// A picture, such as a seating chart.
    public struct ImageBlock: Codable, Hashable, Sendable {
        public let id: String
        public let onUnsupported: OpenEnum<OnUnsupported>?
        public let requires: [String: JSONValue]?
        public let url: String
        public let alt: String
        public let aspectRatio: Double?

        public init(id: String, onUnsupported: OpenEnum<OnUnsupported>? = nil, requires: [String: JSONValue]? = nil,
                    url: String, alt: String, aspectRatio: Double? = nil) {
            self.id = id
            self.onUnsupported = onUnsupported
            self.requires = requires
            self.url = url
            self.alt = alt
            self.aspectRatio = aspectRatio
        }
    }

    /// A titled group of blocks, one level deep.
    public struct SectionBlock: Codable, Hashable, Sendable {
        public let id: String
        public let onUnsupported: OpenEnum<OnUnsupported>?
        public let requires: [String: JSONValue]?
        public let title: String
        public let blocks: [Block]

        public init(id: String, onUnsupported: OpenEnum<OnUnsupported>? = nil, requires: [String: JSONValue]? = nil,
                    title: String, blocks: [Block]) {
            self.id = id
            self.onUnsupported = onUnsupported
            self.requires = requires
            self.title = title
            self.blocks = blocks
        }
    }
}
