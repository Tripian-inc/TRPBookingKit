import Foundation

/// The English wording and number formats the local checkout uses in its steps.
enum LocalFormat {
    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func formatter(_ pattern: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = posix
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    /// `15 October 2026`.
    static func longDate(_ date: BookingDate) -> String {
        guard let day = Calendar.utcGregorian.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) else {
            return date.description
        }
        return formatter("d MMMM yyyy", TimeZone(identifier: "UTC")!).string(from: day)
    }

    /// `14 October, 10:30` in `timeZone`.
    static func dayAndTime(_ date: Date, in timeZone: TimeZone) -> String {
        formatter("d MMMM, HH:mm", timeZone).string(from: date)
    }

    /// `2026-10-02T14:20:00Z`.
    static func iso(_ date: Date) -> String {
        formatter("yyyy-MM-dd'T'HH:mm:ss'Z'", TimeZone(identifier: "UTC")!).string(from: date)
    }

    /// `2026-10-15` of `date` in `timeZone`.
    static func day(_ date: Date, in timeZone: TimeZone) -> String {
        formatter("yyyy-MM-dd", timeZone).string(from: date)
    }

    /// An amount with two decimals and no grouping, as the contract's `Money` carries it.
    static func amount(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = posix
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    static func money(_ value: Decimal, _ currency: String) -> BookingContract.Money {
        BookingContract.Money(amount: amount(value), currency: currency)
    }

    /// `Age 13+` or `Age 4–12`; `nil` when neither bound is known.
    static func ageRange(min: Int?, max: Int?) -> String? {
        switch (min, max) {
        case let (low?, high?) where high < 99: return "Age \(low)–\(high)"
        case let (low?, _): return "Age \(low)+"
        default: return nil
        }
    }

    /// `2 adults, 1 child` from unit counts, in the order of `units`.
    static func party(_ units: [(singular: String, count: Int)]) -> String {
        units.filter { $0.count > 0 }.map { unit in
            let noun = unit.singular.lowercased()
            return "\(unit.count) \(unit.count == 1 ? noun : plural(noun))"
        }.joined(separator: ", ")
    }

    private static func plural(_ noun: String) -> String {
        switch noun {
        case "child": return "children"
        case "person": return "people"
        default: return noun + "s"
        }
    }

    /// The decimal value of a contract amount string.
    static func decimal(_ money: BookingContract.Money?) -> Decimal? {
        money.flatMap { Decimal(string: $0.amount, locale: posix) }
    }
}

extension Calendar {
    static var utcGregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
