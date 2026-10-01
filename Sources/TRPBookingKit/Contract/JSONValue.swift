import Foundation

extension BookingContract {

    /// Any JSON value, used where the contract leaves the shape open: answers, condition values, `requires`,
    /// three-D Secure parameters and the raw body of an unknown block, field or action.
    public enum JSONValue: Codable, Hashable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
        case array([JSONValue])
        case object([String: JSONValue])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let array = try? container.decode([JSONValue].self) {
                self = .array(array)
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .null: try container.encodeNil()
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }

        public var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        public var numberValue: Double? {
            if case .number(let value) = self { return value }
            return nil
        }

        public var boolValue: Bool? {
            if case .bool(let value) = self { return value }
            return nil
        }

        public var arrayValue: [JSONValue]? {
            if case .array(let value) = self { return value }
            return nil
        }

        public var objectValue: [String: JSONValue]? {
            if case .object(let value) = self { return value }
            return nil
        }

        public var isNull: Bool { self == .null }

        /// Re-encodes `value` as a `JSONValue`.
        public init<T: Encodable>(encoding value: T) throws {
            let data = try JSONEncoder().encode(value)
            self = try JSONDecoder().decode(JSONValue.self, from: data)
        }

        /// Decodes this value as `T`.
        public func decode<T: Decodable>(as type: T.Type) throws -> T {
            try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
        }
    }
}

extension BookingContract.JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: BookingContract.JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }

    public init(dictionaryLiteral elements: (String, BookingContract.JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// A coding key built from any string, for objects whose keys are not known up front.
struct ContractDynamicKey: CodingKey, Hashable {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
