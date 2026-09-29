import Foundation

/// Decoding helpers for provider payloads that send the same field as a number in one call and a
/// string in another.
extension KeyedDecodingContainer {

    func flexibleDecimal(_ key: Key) -> Decimal? {
        if let double = try? decodeIfPresent(Double.self, forKey: key) {
            return Decimal(string: String(double), locale: Locale(identifier: "en_US_POSIX"))
        }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return Decimal(string: string.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX"))
        }
        return nil
    }

    func flexibleInt(_ key: Key) -> Int? {
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return int }
        if let double = try? decodeIfPresent(Double.self, forKey: key), double.rounded() == double { return Int(double) }
        if let string = try? decodeIfPresent(String.self, forKey: key) { return Int(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    func flexibleString(_ key: Key) -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) { return string }
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return String(int) }
        if let double = try? decodeIfPresent(Double.self, forKey: key) { return String(double) }
        return nil
    }

    func flexibleBool(_ key: Key) -> Bool? {
        if let bool = try? decodeIfPresent(Bool.self, forKey: key) { return bool }
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return int != 0 }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    /// Decodes an array, dropping elements that fail rather than failing the whole payload.
    func lossyArray<Element: Decodable>(_ key: Key) -> [Element] {
        guard var container = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(DiscardedValue.self)
            }
        }
        return elements
    }

    func flexibleIntArray(_ key: Key) -> [Int] {
        if let ints = try? decodeIfPresent([Int].self, forKey: key) { return ints }
        if let strings = try? decodeIfPresent([String].self, forKey: key) { return strings.compactMap { Int($0) } }
        return []
    }
}

private struct DiscardedValue: Decodable {}

/// Parses the ISO 8601 timestamps providers send, with or without fractional seconds.
enum ISO8601 {
    static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
