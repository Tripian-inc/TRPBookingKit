import Foundation

extension BookingContract {

    /// An input block (`type: field`), discriminated by `fieldType`.
    ///
    /// Each case carries a `FieldSpec` whose `Answer` is the type of the field's answer and `defaultValue`.
    /// A field type this version does not know decodes to `unknown`, keeping the whole object; render it as
    /// `degradesTo` when that is set.
    public enum Field: Codable, Hashable, Sendable {
        case text(FieldSpec<String>)
        case multiline(FieldSpec<String>)
        case email(FieldSpec<String>)
        case phone(FieldSpec<String>)
        case number(FieldSpec<Double>)
        case numberWithUnit(FieldSpec<NumberWithUnitAnswer>)
        case date(FieldSpec<String>)
        case time(FieldSpec<String>)
        case select(FieldSpec<String>)
        case multiSelect(FieldSpec<[String]>)
        case country(FieldSpec<String>)
        case boolean(FieldSpec<Bool>)
        case locationOrText(FieldSpec<LocationOrTextAnswer>)
        case unknown(fieldType: String, raw: JSONValue)

        enum CodingKeys: String, CodingKey { case type, fieldType }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let fieldType = try container.decode(String.self, forKey: .fieldType)
            switch FieldType(decoding: fieldType) {
            case .text: self = .text(try FieldSpec(from: decoder))
            case .multiline: self = .multiline(try FieldSpec(from: decoder))
            case .email: self = .email(try FieldSpec(from: decoder))
            case .phone: self = .phone(try FieldSpec(from: decoder))
            case .number: self = .number(try FieldSpec(from: decoder))
            case .numberWithUnit: self = .numberWithUnit(try FieldSpec(from: decoder))
            case .date: self = .date(try FieldSpec(from: decoder))
            case .time: self = .time(try FieldSpec(from: decoder))
            case .select: self = .select(try FieldSpec(from: decoder))
            case .multiSelect: self = .multiSelect(try FieldSpec(from: decoder))
            case .country: self = .country(try FieldSpec(from: decoder))
            case .boolean: self = .boolean(try FieldSpec(from: decoder))
            case .locationOrText: self = .locationOrText(try FieldSpec(from: decoder))
            case .unknown: self = .unknown(fieldType: fieldType, raw: try JSONValue(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            if case .unknown(_, let raw) = self {
                try raw.encode(to: encoder)
                return
            }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(BlockType.field.rawValue, forKey: .type)
            try container.encode(fieldTypeRawValue, forKey: .fieldType)
            try spec?.encode(to: encoder)
        }

        /// The `fieldType` as sent, including an unknown one.
        public var fieldTypeRawValue: String {
            switch self {
            case .text: return FieldType.text.rawValue
            case .multiline: return FieldType.multiline.rawValue
            case .email: return FieldType.email.rawValue
            case .phone: return FieldType.phone.rawValue
            case .number: return FieldType.number.rawValue
            case .numberWithUnit: return FieldType.numberWithUnit.rawValue
            case .date: return FieldType.date.rawValue
            case .time: return FieldType.time.rawValue
            case .select: return FieldType.select.rawValue
            case .multiSelect: return FieldType.multiSelect.rawValue
            case .country: return FieldType.country.rawValue
            case .boolean: return FieldType.boolean.rawValue
            case .locationOrText: return FieldType.locationOrText.rawValue
            case .unknown(let fieldType, _): return fieldType
            }
        }

        public var id: String { spec?.id ?? rawString("id") ?? "" }
        public var label: String { spec?.label ?? rawString("label") ?? "" }
        public var required: Bool { spec?.required ?? unknownObject?["required"]?.boolValue ?? false }
        public var onUnsupported: OpenEnum<OnUnsupported>? {
            spec?.onUnsupported ?? rawString("onUnsupported").map(OpenEnum.init(rawValue:))
        }
        public var degradesTo: OpenEnum<FieldType>? {
            spec?.degradesTo ?? rawString("degradesTo").map(OpenEnum.init(rawValue:))
        }
        public var visibleWhen: Condition? { spec?.visibleWhen ?? rawCondition("visibleWhen") }
        public var requiredWhen: Condition? { spec?.requiredWhen ?? rawCondition("requiredWhen") }

        /// Whether the field is shown for `answers`.
        public func isVisible(answers: Answers) -> Bool {
            ConditionEvaluator.isSatisfied(visibleWhen, answers: answers)
        }

        /// Whether the field needs an answer for `answers`: it is visible and `required` or `requiredWhen` holds.
        public func isRequired(answers: Answers) -> Bool {
            guard isVisible(answers: answers) else { return false }
            if required { return true }
            guard let requiredWhen else { return false }
            return ConditionEvaluator.isSatisfied(requiredWhen, answers: answers)
        }

        private var spec: (any FieldDescribing)? {
            switch self {
            case .text(let spec), .multiline(let spec), .email(let spec), .phone(let spec), .date(let spec),
                 .time(let spec), .select(let spec), .country(let spec):
                return spec
            case .number(let spec): return spec
            case .numberWithUnit(let spec): return spec
            case .multiSelect(let spec): return spec
            case .boolean(let spec): return spec
            case .locationOrText(let spec): return spec
            case .unknown: return nil
            }
        }

        private var unknownObject: [String: JSONValue]? {
            if case .unknown(_, let raw) = self { return raw.objectValue }
            return nil
        }

        private func rawString(_ key: String) -> String? {
            unknownObject?[key]?.stringValue
        }

        private func rawCondition(_ key: String) -> Condition? {
            guard let value = unknownObject?[key] else { return nil }
            return try? value.decode(as: Condition.self)
        }
    }

    /// The keys every field shares; `Answer` is the type of its answer and `defaultValue`.
    public struct FieldSpec<Answer: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
        public let id: String
        public let onUnsupported: OpenEnum<OnUnsupported>?
        public let requires: [String: JSONValue]?
        public let control: String?
        public let label: String
        public let hint: String?
        public let placeholder: String?
        public let required: Bool
        public let scope: OpenEnum<FieldScope>?
        public let travelerIndex: Int?
        public let validation: Validation?
        public let options: [FieldOption]?
        public let units: [FieldOption]?
        public let defaultValue: Answer?
        public let autofill: String?
        public let visibleWhen: Condition?
        public let requiredWhen: Condition?
        public let degradesTo: OpenEnum<FieldType>?

        public init(id: String, onUnsupported: OpenEnum<OnUnsupported>? = nil, requires: [String: JSONValue]? = nil,
                    control: String? = nil, label: String, hint: String? = nil, placeholder: String? = nil,
                    required: Bool, scope: OpenEnum<FieldScope>? = nil, travelerIndex: Int? = nil,
                    validation: Validation? = nil, options: [FieldOption]? = nil, units: [FieldOption]? = nil,
                    defaultValue: Answer? = nil, autofill: String? = nil, visibleWhen: Condition? = nil,
                    requiredWhen: Condition? = nil, degradesTo: OpenEnum<FieldType>? = nil) {
            self.id = id
            self.onUnsupported = onUnsupported
            self.requires = requires
            self.control = control
            self.label = label
            self.hint = hint
            self.placeholder = placeholder
            self.required = required
            self.scope = scope
            self.travelerIndex = travelerIndex
            self.validation = validation
            self.options = options
            self.units = units
            self.defaultValue = defaultValue
            self.autofill = autofill
            self.visibleWhen = visibleWhen
            self.requiredWhen = requiredWhen
            self.degradesTo = degradesTo
        }
    }

    /// Input rules; the length rules apply to text, the numeric ones to numbers.
    public struct Validation: Codable, Hashable, Sendable {
        public let minLength: Int?
        public let maxLength: Int?
        public let pattern: String?
        public let message: String?
        public let min: Double?
        public let max: Double?
        public let step: Double?

        public init(minLength: Int? = nil, maxLength: Int? = nil, pattern: String? = nil, message: String? = nil,
                    min: Double? = nil, max: Double? = nil, step: Double? = nil) {
            self.minLength = minLength
            self.maxLength = maxLength
            self.pattern = pattern
            self.message = message
            self.min = min
            self.max = max
            self.step = step
        }
    }

    /// An option of a select, multi-select or location field, or a unit of a number-with-unit field.
    public struct FieldOption: Codable, Hashable, Sendable {
        public let value: String
        public let title: String

        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    /// The answer of a `numberWithUnit` field.
    public struct NumberWithUnitAnswer: Codable, Hashable, Sendable {
        public let value: Double
        public let unit: String

        public init(value: Double, unit: String) {
            self.value = value
            self.unit = unit
        }
    }

    /// The answer of a `locationOrText` field: one of the offered locations, or free text.
    public enum LocationOrTextAnswer: Codable, Hashable, Sendable {
        case ref(String)
        case text(String)

        enum CodingKeys: String, CodingKey { case ref, text }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let ref = try container.decodeIfPresent(String.self, forKey: .ref) {
                self = .ref(ref)
            } else {
                self = .text(try container.decode(String.self, forKey: .text))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .ref(let ref): try container.encode(ref, forKey: .ref)
            case .text(let text): try container.encode(text, forKey: .text)
            }
        }
    }
}

/// The parts of a field that do not depend on its answer type.
protocol FieldDescribing: Encodable {
    var id: String { get }
    var label: String { get }
    var required: Bool { get }
    var onUnsupported: BookingContract.OpenEnum<BookingContract.OnUnsupported>? { get }
    var degradesTo: BookingContract.OpenEnum<BookingContract.FieldType>? { get }
    var visibleWhen: BookingContract.Condition? { get }
    var requiredWhen: BookingContract.Condition? { get }
}

extension BookingContract.FieldSpec: FieldDescribing {}
