import XCTest
@testable import TRPBookingKit

final class ToristySelectionValidatorTests: XCTestCase {

    private let validator = ToristySelectionValidator()

    private func makeStartTime(id: Int = 1, availableCount: Int = 10, isUnlimited: Bool = false, minParticipants: Int = 0,
                                isSoldOut: Bool = false, isUnavailable: Bool = false,
                                rates: [ToristyStartTimeRate]? = nil) -> ToristyStartTime {
        ToristyStartTime(time: "09:00:00", id: id, availableCount: availableCount, isUnlimited: isUnlimited,
                         minParticipants: minParticipants, isUnavailable: isUnavailable, isSoldOut: isSoldOut,
                         rates: rates ?? [ToristyStartTimeRate(id: 1)])
    }

    private func makeRate(id: String = "1", startTimeIds: [Int] = [], prices: [ToristyPricingCategory]? = nil,
                          extras: [ToristyExtra] = []) -> ToristyRate {
        ToristyRate(id: id, name: "Standard", startTimeIds: startTimeIds,
                   prices: prices ?? [ToristyPricingCategory(id: "ADULT", name: "Adult", price: 50)], extras: extras)
    }

    private func makeInformation(rates: [ToristyRate]? = nil, fields: ToristyBookingFields = ToristyBookingFields(),
                                  pickupPoints: [ToristyMeetingPoint] = [], dropoffPoints: [ToristyMeetingPoint] = []) -> ToristyBookingInformation {
        ToristyBookingInformation(serviceId: 1, currency: "USD", startingPrice: 50, lowestPrice: 50, fields: fields,
                                   rates: rates ?? [makeRate()], cancellationPolicy: nil, cancellationRules: [],
                                   pickupPoints: pickupPoints, dropoffPoints: dropoffPoints)
    }

    private func makeSelection(rateId: String = "1", startTime: ToristyStartTime? = nil, passengers: [ToristyPassenger]? = nil,
                                mainContact: [ToristyAnswer] = [], bookingAnswers: [ToristyAnswer] = [],
                                pickup: ToristyTransferSelection? = nil, dropoff: ToristyTransferSelection? = nil) -> ToristySelection {
        ToristySelection(serviceId: 1, rateId: rateId, date: BookingDate(year: 2026, month: 6, day: 1)!,
                         startTime: startTime ?? makeStartTime(), mainContact: mainContact,
                         passengers: passengers ?? [ToristyPassenger(pricingCategoryId: "ADULT")],
                         bookingAnswers: bookingAnswers, pickup: pickup, dropoff: dropoff, currency: "USD")
    }

    // MARK: - a valid selection

    func testIssuesIsEmptyForAValidSelection() {
        let issues = validator.issues(for: makeSelection(), information: makeInformation())

        XCTAssertTrue(issues.isEmpty)
    }

    // MARK: - rate and departure

    func testIssuesReportsOnlyUnknownRateWhenTheRateDoesNotExist() {
        let issues = validator.issues(for: makeSelection(rateId: "unknown"), information: makeInformation())

        XCTAssertEqual(issues, [.unknownRate("unknown")])
    }

    func testIssuesReportsRateNotOfferedAtStartTimeWhenTheRateExcludesIt() {
        let information = makeInformation(rates: [makeRate(startTimeIds: [999])])

        let issues = validator.issues(for: makeSelection(), information: information)

        XCTAssertTrue(issues.contains(.rateNotOfferedAtStartTime(rateId: "1", startTimeId: 1)))
    }

    func testIssuesReportsDepartureNotBookableWhenSoldOut() {
        let selection = makeSelection(startTime: makeStartTime(isSoldOut: true))

        let issues = validator.issues(for: selection, information: makeInformation())

        XCTAssertTrue(issues.contains(.departureNotBookable))
    }

    // MARK: - party size

    func testIssuesReportsNotEnoughSeatsWhenTheDepartureHasFewerSeatsThanRequested() {
        let selection = makeSelection(startTime: makeStartTime(availableCount: 0))

        let issues = validator.issues(for: selection, information: makeInformation())

        XCTAssertTrue(issues.contains(.notEnoughSeats(requested: 1, available: 0)))
    }

    func testIssuesReportsBelowMinimumParticipantsWhenThePartyIsSmallerThanTheDepartureRequires() {
        let selection = makeSelection(startTime: makeStartTime(minParticipants: 2))

        let issues = validator.issues(for: selection, information: makeInformation())

        XCTAssertTrue(issues.contains(.belowMinimumParticipants(requested: 1, minimum: 2)))
    }

    func testIssuesReportsNoPassengersWhenThePartyIsEmpty() {
        let issues = validator.issues(for: makeSelection(passengers: []), information: makeInformation())

        XCTAssertTrue(issues.contains(.noPassengers))
    }

    // MARK: - rate and category booking bounds

    func testIssuesReportsRateBookingBoundsWhenThePartyIsBelowTheDepartureRatesMinimum() {
        let selection = makeSelection(startTime: makeStartTime(rates: [ToristyStartTimeRate(id: 1, minPerBooking: 2)]))

        let issues = validator.issues(for: selection, information: makeInformation())

        XCTAssertTrue(issues.contains(.rateBookingBounds(requested: 1, minimum: 2, maximum: nil)))
    }

    func testIssuesReportsUnknownPricingCategoryWhenTheCategoryIsNotOfferedByTheRate() {
        let selection = makeSelection(passengers: [ToristyPassenger(pricingCategoryId: "CHILD")])

        let issues = validator.issues(for: selection, information: makeInformation())

        XCTAssertTrue(issues.contains(.unknownPricingCategory("CHILD")))
    }

    func testIssuesReportsCategoryBookingBoundsWhenACategoryExceedsItsOwnMaximum() {
        let information = makeInformation(rates: [makeRate(prices: [ToristyPricingCategory(id: "ADULT", name: "Adult", price: 50, maxPerBooking: 1)])])
        let selection = makeSelection(passengers: [ToristyPassenger(pricingCategoryId: "ADULT"), ToristyPassenger(pricingCategoryId: "ADULT")])

        let issues = validator.issues(for: selection, information: information)

        XCTAssertTrue(issues.contains(.categoryBookingBounds(categoryId: "ADULT", requested: 2, minimum: nil, maximum: 1)))
    }

    // MARK: - answers

    func testIssuesReportsMissingMainContactWhenARequiredContactFieldIsUnanswered() {
        let information = makeInformation(fields: ToristyBookingFields(mainContact: [ToristyContactField(questionId: "firstName", required: true)]))

        let issues = validator.issues(for: makeSelection(), information: information)

        XCTAssertTrue(issues.contains(.missingMainContact(questionId: "firstName")))
    }

    func testIssuesReportsMissingPassengerDetailWhenARequiredPassengerFieldIsUnanswered() {
        let information = makeInformation(fields: ToristyBookingFields(passengerContact: [ToristyContactField(questionId: "passportNumber", required: true)]))

        let issues = validator.issues(for: makeSelection(), information: information)

        XCTAssertTrue(issues.contains(.missingPassengerDetail(passengerIndex: 0, questionId: "passportNumber")))
    }

    func testIssuesReportsMissingQuestionWhenARequiredBookingQuestionIsUnanswered() {
        let information = makeInformation(fields: ToristyBookingFields(mainContactQuestions: [ToristyQuestion(questionId: "Q1", question: "Q", required: true)]))

        let issues = validator.issues(for: makeSelection(), information: information)

        XCTAssertTrue(issues.contains(.missingQuestion(questionId: "Q1")))
    }

    func testIssuesReportsMissingPassengerAnswerWhenARequiredPassengerQuestionIsUnanswered() {
        let information = makeInformation(fields: ToristyBookingFields(passengerQuestions: [ToristyQuestion(questionId: "Q2", question: "Q", required: true)]))

        let issues = validator.issues(for: makeSelection(), information: information)

        XCTAssertTrue(issues.contains(.missingPassengerAnswer(passengerIndex: 0, questionId: "Q2")))
    }

    // MARK: - extras

    func testIssuesReportsUnknownExtraWhenAPassengerChoosesAnExtraTheRateDoesNotOffer() {
        let selection = makeSelection(passengers: [ToristyPassenger(pricingCategoryId: "ADULT", extras: [ToristyExtraSelection(extraId: "UNKNOWN", quantity: 1)])])

        let issues = validator.issues(for: selection, information: makeInformation())

        XCTAssertTrue(issues.contains(.unknownExtra("UNKNOWN")))
    }

    func testIssuesReportsExtraLimitExceededWhenAPerPassengerExtraIsOverTheLimit() {
        let information = makeInformation(rates: [makeRate(extras: [ToristyExtra(id: "EX1", name: "Extra", price: 10, pricePer: .person, limitType: "per_passenger", limit: 1)])])
        let selection = makeSelection(passengers: [ToristyPassenger(pricingCategoryId: "ADULT", extras: [ToristyExtraSelection(extraId: "EX1", quantity: 2)])])

        let issues = validator.issues(for: selection, information: information)

        XCTAssertTrue(issues.contains(.extraLimitExceeded(extraId: "EX1", requested: 2, limit: 1)))
    }

    // MARK: - pickup and dropoff

    func testIssuesReportsPickupUnavailableWhenTheDepartureRateDisallowsIt() {
        let selection = makeSelection(startTime: makeStartTime(rates: [ToristyStartTimeRate(id: 1, pickupSelection: .unavailable)]),
                                      pickup: ToristyTransferSelection())

        let issues = validator.issues(for: selection, information: makeInformation())

        XCTAssertTrue(issues.contains(.pickupUnavailable))
    }

    func testIssuesReportsDropoffUnavailableWhenTheDepartureRateDisallowsIt() {
        let selection = makeSelection(startTime: makeStartTime(rates: [ToristyStartTimeRate(id: 1, dropoffSelection: .unavailable)]),
                                      dropoff: ToristyTransferSelection())

        let issues = validator.issues(for: selection, information: makeInformation())

        XCTAssertTrue(issues.contains(.dropoffUnavailable))
    }

    func testIssuesReportsUnknownMeetingPointWhenThePickupPlaceIsNotAmongTheOffered() {
        let information = makeInformation(pickupPoints: [ToristyMeetingPoint(id: 1, title: "Hotel")])
        let selection = makeSelection(pickup: ToristyTransferSelection(placeId: 999))

        let issues = validator.issues(for: selection, information: information)

        XCTAssertTrue(issues.contains(.unknownMeetingPoint(999)))
    }

    // MARK: - validate

    func testValidateThrowsInvalidSelectionWithEveryIssue() {
        XCTAssertThrowsError(try validator.validate(makeSelection(passengers: []), information: makeInformation())) { error in
            guard case BookingError.invalidSelection(let messages) = error else { return XCTFail("Expected invalidSelection, got \(error)") }
            XCTAssertEqual(messages, [ToristySelectionIssue.noPassengers.description])
        }
    }

    func testValidateDoesNotThrowForAValidSelection() throws {
        try validator.validate(makeSelection(), information: makeInformation())
    }
}
