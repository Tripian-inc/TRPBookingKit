import Foundation

/// A calendar day with no time zone, written `yyyy-MM-dd` as every provider expects.
public struct BookingDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {

    public let year: Int
    public let month: Int
    public let day: Int

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public init?(year: Int, month: Int, day: Int) {
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = Self.calendar.date(from: components) else { return nil }
        let resolved = Self.calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `yyyy-MM-dd`, also accepting a longer string that starts with it.
    public init?(_ string: String) {
        let parts = string.prefix(10).split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The day `date` falls on in `timeZone`.
    public init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = components.year ?? 1970
        self.month = components.month ?? 1
        self.day = components.day ?? 1
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let date = BookingDate(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a yyyy-MM-dd date: \(string)")
        }
        self = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public func adding(days: Int) -> BookingDate {
        let start = Self.calendar.date(from: DateComponents(year: year, month: month, day: day))!
        let moved = Self.calendar.date(byAdding: .day, value: days, to: start)!
        return BookingDate(date: moved, timeZone: Self.calendar.timeZone)
    }

    /// Whole days from `self` to `other`; negative when `other` is earlier.
    public func days(until other: BookingDate) -> Int {
        let start = Self.calendar.date(from: DateComponents(year: year, month: month, day: day))!
        let end = Self.calendar.date(from: DateComponents(year: other.year, month: other.month, day: other.day))!
        return Self.calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    public static func < (lhs: BookingDate, rhs: BookingDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Splits an inclusive range into consecutive inclusive windows of at most `maximumDays` days.
    public static func windows(from start: BookingDate, through end: BookingDate, maximumDays: Int) -> [ClosedRange<BookingDate>] {
        guard start <= end, maximumDays > 0 else { return [] }
        var windows: [ClosedRange<BookingDate>] = []
        var windowStart = start
        while windowStart <= end {
            let windowEnd = min(windowStart.adding(days: maximumDays - 1), end)
            windows.append(windowStart...windowEnd)
            windowStart = windowEnd.adding(days: 1)
        }
        return windows
    }
}
