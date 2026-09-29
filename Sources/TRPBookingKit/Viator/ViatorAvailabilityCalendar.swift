import Foundation

/// Works out which days a Viator product can be booked on from its schedule, for the date picker.
///
/// The schedule only narrows the choice; the price and the final yes come from `availability/check`.
public struct ViatorAvailabilityCalendar: Sendable {

    private static let weekdayNames = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]

    public let schedule: ViatorSchedule
    public let timeZone: TimeZone

    public init(schedule: ViatorSchedule, timeZone: TimeZone) {
        self.schedule = schedule
        self.timeZone = timeZone
    }

    /// Tomorrow in the product's time zone; Viator does not sell same-day from the partner API.
    public func earliestBookableDate(now: Date = Date()) -> BookingDate {
        BookingDate(date: now, timeZone: timeZone).adding(days: 1)
    }

    /// Whether any option has a start time on `date` that is not blocked.
    public func isAvailable(_ date: BookingDate, optionCode: String? = nil, now: Date = Date()) -> Bool {
        guard date >= earliestBookableDate(now: now) else { return false }
        let weekday = Self.weekday(of: date)
        return schedule.bookableItems
            .filter { optionCode == nil || $0.productOptionCode == optionCode }
            .flatMap(\.seasons)
            .filter { $0.contains(date) }
            .flatMap(\.pricingRecords)
            .filter { $0.daysOfWeek.isEmpty || $0.daysOfWeek.contains(weekday) }
            .contains { record in
                record.timedEntries.isEmpty || record.timedEntries.contains { !$0.unavailableDates.contains(date) }
            }
    }

    /// The bookable days between two dates, inclusive.
    public func availableDates(from start: BookingDate, through end: BookingDate, optionCode: String? = nil, now: Date = Date()) -> [BookingDate] {
        let first = max(start, earliestBookableDate(now: now))
        guard first <= end else { return [] }
        return (0...first.days(until: end)).map { first.adding(days: $0) }.filter { isAvailable($0, optionCode: optionCode, now: now) }
    }

    /// The start times scheduled on `date` for an option, before the live check.
    public func startTimes(on date: BookingDate, optionCode: String) -> [String] {
        let weekday = Self.weekday(of: date)
        let times = schedule.bookableItems
            .filter { $0.productOptionCode == optionCode }
            .flatMap(\.seasons)
            .filter { $0.contains(date) }
            .flatMap(\.pricingRecords)
            .filter { $0.daysOfWeek.isEmpty || $0.daysOfWeek.contains(weekday) }
            .flatMap(\.timedEntries)
            .filter { !$0.unavailableDates.contains(date) }
            .compactMap(\.startTime)
        return Array(Set(times)).sorted()
    }

    static func weekday(of date: BookingDate) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))!
        return weekdayNames[calendar.component(.weekday, from: day) - 1]
    }
}
