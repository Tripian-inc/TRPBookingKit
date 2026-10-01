import Foundation

extension BookingContract {

    /// A `visibleWhen` or `requiredWhen` rule: every clause (`all`) or at least one (`any`) must hold.
    /// Conditions do not nest.
    public enum Condition: Codable, Hashable, Sendable {
        case all([Clause])
        case any([Clause])

        enum CodingKeys: String, CodingKey { case all, any }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let clauses = try container.decodeIfPresent([Clause].self, forKey: .all) {
                self = .all(clauses)
            } else {
                self = .any(try container.decode([Clause].self, forKey: .any))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .all(let clauses): try container.encode(clauses, forKey: .all)
            case .any(let clauses): try container.encode(clauses, forKey: .any)
            }
        }

        /// A test on one answer. `field` is a field id, or `blockId.key` for a key inside an object answer such
        /// as `units.CHILD`; `values` is absent for `exists`.
        public struct Clause: Codable, Hashable, Sendable {
            public let field: String
            public let op: OpenEnum<ConditionOp>
            public let values: [JSONValue]?

            public init(field: String, op: OpenEnum<ConditionOp>, values: [JSONValue]? = nil) {
                self.field = field
                self.op = op
                self.values = values
            }

            public init(field: String, op: ConditionOp, values: [JSONValue]? = nil) {
                self.init(field: field, op: OpenEnum(op), values: values)
            }
        }
    }

    /// Evaluates conditions against the answers collected so far.
    public enum ConditionEvaluator {

        /// Whether `condition` holds for `answers`; a missing condition always holds.
        ///
        /// An unanswered field fails every operator but `notIn`, and an unknown operator never holds.
        public static func isSatisfied(_ condition: Condition?, answers: Answers) -> Bool {
            switch condition {
            case nil: return true
            case .all(let clauses)?: return clauses.allSatisfy { isSatisfied($0, answers: answers) }
            case .any(let clauses)?: return clauses.contains { isSatisfied($0, answers: answers) }
            }
        }

        /// Whether one clause holds for `answers`.
        public static func isSatisfied(_ clause: Condition.Clause, answers: Answers) -> Bool {
            let answer = answers.value(at: clause.field)
            let values = clause.values ?? []
            switch clause.op.value {
            case .exists: return answer.map(isPresent) ?? false
            case .in: return matchesAny(answer, values)
            case .notIn: return !matchesAny(answer, values)
            case .eq:
                guard let answer, let expected = values.first else { return false }
                return isEqual(answer, expected)
            case .gt:
                guard let answer, let expected = values.first, let order = compare(answer, expected) else { return false }
                return order == .orderedDescending
            case .lt:
                guard let answer, let expected = values.first, let order = compare(answer, expected) else { return false }
                return order == .orderedAscending
            case .unknown: return false
            }
        }

        private static func isPresent(_ value: JSONValue) -> Bool {
            switch value {
            case .null: return false
            case .string(let string): return !string.isEmpty
            case .array(let array): return !array.isEmpty
            case .object(let object): return !object.isEmpty
            case .number, .bool: return true
            }
        }

        private static func matchesAny(_ answer: JSONValue?, _ values: [JSONValue]) -> Bool {
            guard let answer, answer != .null else { return false }
            if case .array(let elements) = answer {
                return elements.contains { element in values.contains { isEqual(element, $0) } }
            }
            return values.contains { isEqual(answer, $0) }
        }

        private static func isEqual(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
            switch (lhs, rhs) {
            case let (.number(left), .number(right)): return left == right
            case let (.string(left), .number(right)): return Double(left) == right
            case let (.number(left), .string(right)): return left == Double(right)
            default: return lhs == rhs
            }
        }

        private static func compare(_ lhs: JSONValue, _ rhs: JSONValue) -> ComparisonResult? {
            switch (lhs, rhs) {
            case let (.number(left), .number(right)):
                return left < right ? .orderedAscending : (left > right ? .orderedDescending : .orderedSame)
            case let (.string(left), .string(right)):
                return left.compare(right)
            default:
                return nil
            }
        }
    }
}
