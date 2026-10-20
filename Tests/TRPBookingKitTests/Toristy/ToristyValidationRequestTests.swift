import XCTest
@testable import TRPBookingKit

final class ToristyValidationRequestTests: XCTestCase {

    private func makeSelection(startTime: ToristyStartTime) -> ToristySelection {
        ToristySelection(serviceId: 48213, rateId: "RATE_STD", date: BookingDate(year: 2026, month: 10, day: 15)!,
                         startTime: startTime, mainContact: [], passengers: [ToristyPassenger(pricingCategoryId: "ADULT")],
                         currency: "eur")
    }

    private func startTimeIdValue(in body: Data) throws -> Any {
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let directBooking = json?["directBooking"] as? [String: Any]
        let bookings = directBooking?["activityBookings"] as? [[String: Any]]
        return try XCTUnwrap(bookings?.first?["startTimeId"])
    }

    func testEncodesStartTimeIdAsAnIntegerWhenTheAvailabilityGaveANumber() throws {
        let startTime = ToristyStartTime(time: "10:00:00", id: 7, availableCount: 5)
        let request = ToristyValidationRequest(selection: makeSelection(startTime: startTime))

        let body = try JSONEncoder().encode(request)
        let value = try startTimeIdValue(in: body)

        XCTAssertTrue(value is NSNumber)
        XCTAssertEqual((value as? NSNumber)?.intValue, 7)
    }

    func testEncodesStartTimeIdAsAnIntegerWhenTheAvailabilityJsonSentAString() throws {
        let decoded = try JSONDecoder().decode(ToristyStartTime.self, from: Data(#"{"time": "10:00:00", "starttimeid": "7"}"#.utf8))
        let request = ToristyValidationRequest(selection: makeSelection(startTime: decoded))

        let body = try JSONEncoder().encode(request)
        let value = try startTimeIdValue(in: body)

        XCTAssertTrue(value is NSNumber)
        XCTAssertEqual((value as? NSNumber)?.intValue, 7)
        XCTAssertFalse(value is String)
    }
}
