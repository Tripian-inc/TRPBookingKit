import XCTest
@testable import TRPBookingKit

final class ViatorAvailabilityCalendarTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private func makeSchedule(optionCode: String = "OPT1", daysOfWeek: [String] = [], startTimes: [String?] = [nil], unavailableDates: [String] = [], startDate: String = "2020-01-01", endDate: String? = nil) throws -> ViatorSchedule {
        let entries = startTimes.map { time -> String in
            let startJSON = time.map { "\"\($0)\"" } ?? "null"
            let unavailable = unavailableDates.map { "{\"date\": \"\($0)\"}" }.joined(separator: ",")
            return "{\"startTime\": \(startJSON), \"unavailableDates\": [\(unavailable)]}"
        }.joined(separator: ",")
        let days = daysOfWeek.map { "\"\($0)\"" }.joined(separator: ",")
        let endJSON = endDate.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"productCode": "P1", "currency": "USD",
         "bookableItems": [{"productOptionCode": "\(optionCode)",
           "seasons": [{"startDate": "\(startDate)", "endDate": \(endJSON),
             "pricingRecords": [{"daysOfWeek": [\(days)], "timedEntries": [\(entries)]}]}]}]}
        """
        return try decodeJSON(ViatorSchedule.self, json)
    }

    private func now(_ string: String) -> Date {
        ISO8601.date(from: string)!
    }

    // MARK: - earliestBookableDate

    func testEarliestBookableDateIsTomorrowInTheGivenTimeZone() throws {
        let schedule = try makeSchedule()
        let calendar = ViatorAvailabilityCalendar(schedule: schedule, timeZone: utc)

        let earliest = calendar.earliestBookableDate(now: now("2026-03-10T12:00:00Z"))

        XCTAssertEqual(earliest, BookingDate(year: 2026, month: 3, day: 11))
    }

    // MARK: - isAvailable

    func testIsAvailableIsFalseBeforeTheEarliestBookableDate() throws {
        let schedule = try makeSchedule()
        let calendar = ViatorAvailabilityCalendar(schedule: schedule, timeZone: utc)

        let today = BookingDate(date: now("2026-03-10T12:00:00Z"), timeZone: utc)

        XCTAssertFalse(calendar.isAvailable(today, now: now("2026-03-10T12:00:00Z")))
    }

    func testIsAvailableRespectsDaysOfWeekFilter() throws {
        let schedule = try makeSchedule(daysOfWeek: ["MONDAY"])
        let calendar = ViatorAvailabilityCalendar(schedule: schedule, timeZone: utc)

        let monday = BookingDate(year: 2026, month: 3, day: 16)!
        let tuesday = BookingDate(year: 2026, month: 3, day: 17)!
        let referenceNow = now("2026-03-01T00:00:00Z")

        XCTAssertTrue(calendar.isAvailable(monday, now: referenceNow))
        XCTAssertFalse(calendar.isAvailable(tuesday, now: referenceNow))
    }

    func testIsAvailableIsTrueEveryDayWhenDaysOfWeekIsEmpty() throws {
        let schedule = try makeSchedule(daysOfWeek: [])
        let calendar = ViatorAvailabilityCalendar(schedule: schedule, timeZone: utc)

        let anyDay = BookingDate(year: 2026, month: 3, day: 18)!

        XCTAssertTrue(calendar.isAvailable(anyDay, now: now("2026-03-01T00:00:00Z")))
    }

    func testIsAvailableIsFalseWhenTheOnlyTimedEntryIsBlockedByAnUnavailableDate() throws {
        let blocked = "2026-03-18"
        let schedule = try makeSchedule(startTimes: ["09:00"], unavailableDates: [blocked])
        let calendar = ViatorAvailabilityCalendar(schedule: schedule, timeZone: utc)

        let date = BookingDate(blocked)!
        let referenceNow = now("2026-03-01T00:00:00Z")

        XCTAssertFalse(calendar.isAvailable(date, now: referenceNow))
    }

    func testIsAvailableFiltersByOptionCodeWhenGiven() throws {
        let schedule = try makeSchedule(optionCode: "OPT1")
        let calendar = ViatorAvailabilityCalendar(schedule: schedule, timeZone: utc)

        let date = BookingDate(year: 2026, month: 3, day: 18)!
        let referenceNow = now("2026-03-01T00:00:00Z")

        XCTAssertTrue(calendar.isAvailable(date, optionCode: "OPT1", now: referenceNow))
        XCTAssertFalse(calendar.isAvailable(date, optionCode: "OTHER", now: referenceNow))
    }

    // MARK: - availableDates

    func testAvailableDatesClampsTheRangeToTheEarliestBookableDate() throws {
        let schedule = try makeSchedule()
        let calendar = ViatorAvailabilityCalendar(schedule: schedule, timeZone: utc)

        let referenceNow = now("2026-03-10T00:00:00Z")
        let dates = calendar.availableDates(from: BookingDate(year: 2026, month: 3, day: 1)!,
                                             through: BookingDate(year: 2026, month: 3, day: 13)!,
                                             now: referenceNow)

        XCTAssertEqual(dates.first, BookingDate(year: 2026, month: 3, day: 11))
        XCTAssertEqual(dates.last, BookingDate(year: 2026, month: 3, day: 13))
    }

    func testAvailableDatesIsEmptyWhenTheEarliestBookableDateIsAfterTheRange() throws {
        let schedule = try makeSchedule()
        let calendar = ViatorAvailabilityCalendar(schedule: schedule, timeZone: utc)

        let referenceNow = now("2026-03-20T00:00:00Z")
        let dates = calendar.availableDates(from: BookingDate(year: 2026, month: 3, day: 1)!,
                                             through: BookingDate(year: 2026, month: 3, day: 5)!,
                                             now: referenceNow)

        XCTAssertTrue(dates.isEmpty)
    }

    // MARK: - startTimes

    func testStartTimesDedupsAndSortsTheTimesScheduledOnADay() throws {
        let entries = "{\"startTime\": \"10:00\", \"unavailableDates\": []},{\"startTime\": \"09:00\", \"unavailableDates\": []},{\"startTime\": \"09:00\", \"unavailableDates\": []}"
        let json = """
        {"productCode": "P1", "bookableItems": [{"productOptionCode": "OPT1",
           "seasons": [{"startDate": "2020-01-01", "pricingRecords": [{"daysOfWeek": [], "timedEntries": [\(entries)]}]}]}]}
        """
        let schedule = try decodeJSON(ViatorSchedule.self, json)
        let calendar = ViatorAvailabilityCalendar(schedule: schedule, timeZone: utc)

        let times = calendar.startTimes(on: BookingDate(year: 2026, month: 3, day: 18)!, optionCode: "OPT1")

        XCTAssertEqual(times, ["09:00", "10:00"])
    }

    func testStartTimesExcludesEntriesUnavailableOnThatDate() throws {
        let blocked = "2026-03-18"
        let schedule = try makeSchedule(startTimes: ["09:00"], unavailableDates: [blocked])
        let calendar = ViatorAvailabilityCalendar(schedule: schedule, timeZone: utc)

        let times = calendar.startTimes(on: BookingDate(blocked)!, optionCode: "OPT1")

        XCTAssertTrue(times.isEmpty)
    }
}
