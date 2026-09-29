import XCTest
@testable import TRPBookingKit

final class ViatorModelsTests: XCTestCase {

    // MARK: - ViatorProduct

    func testProductDecodesAgeBandsRequirementsAndQuestionIds() throws {
        let json = """
        {
          "productCode": "P1",
          "title": "City Tour",
          "timeZone": "America/New_York",
          "pricingInfo": {"ageBands": [{"ageBand": "ADULT", "minTravelersPerBooking": 1, "maxTravelersPerBooking": 10}]},
          "bookingRequirements": {"minTravelersPerBooking": 1, "maxTravelersPerBooking": 20},
          "bookingQuestions": ["Q1", "Q2"],
          "productOptions": [{"productOptionCode": "OPT1", "title": "Standard"}],
          "logistics": {
            "travelerPickup": {"pickupOptionType": "PICKUP", "locations": [{"location": {"ref": "L1"}}]},
            "start": [{"location": {"ref": "S1"}}],
            "end": [{"location": {"ref": "S1"}}]
          }
        }
        """
        let product = try decodeJSON(ViatorProduct.self, json)

        XCTAssertEqual(product.minTravelersPerBooking, 1)
        XCTAssertEqual(product.maxTravelersPerBooking, 20)
        XCTAssertEqual(product.bookingQuestionIds, ["Q1", "Q2"])
        XCTAssertEqual(product.ageBands.first?.ageBand, .adult)
        XCTAssertEqual(product.option(code: "OPT1")?.title, "Standard")
        XCTAssertEqual(product.pickupOptionType, "PICKUP")
        XCTAssertEqual(product.locationRefs, ["L1", "S1"])
        XCTAssertEqual(product.timeZone, TimeZone(identifier: "America/New_York"))
    }

    func testProductDefaultsMinTravelersToOneAndTimeZoneToUTCWhenAbsent() throws {
        let product = try decodeJSON(ViatorProduct.self, #"{"productCode": "P1"}"#)

        XCTAssertEqual(product.minTravelersPerBooking, 1)
        XCTAssertNil(product.maxTravelersPerBooking)
        XCTAssertEqual(product.timeZone, TimeZone(identifier: "UTC"))
        XCTAssertTrue(product.locationRefs.isEmpty)
    }

    func testProductUsesTravelerBandWhenAnAgeBandRuleIsTraveler() throws {
        let json = #"{"productCode":"P1","pricingInfo":{"ageBands":[{"ageBand":"TRAVELER","minTravelersPerBooking":1}]}}"#
        let product = try decodeJSON(ViatorProduct.self, json)

        XCTAssertTrue(product.usesTravelerBand)
    }

    // MARK: - ViatorPrice wrapped vs flat

    func testPriceDecodesFromAWrappedPriceObject() throws {
        let price = try decodeJSON(ViatorPrice.self, #"{"price": {"recommendedRetailPrice": 42.5}}"#)
        XCTAssertEqual(price.recommendedRetailPrice, 42.5)
    }

    func testPriceDecodesFromAFlatObject() throws {
        let price = try decodeJSON(ViatorPrice.self, #"{"recommendedRetailPrice": 42.5}"#)
        XCTAssertEqual(price.recommendedRetailPrice, 42.5)
    }

    // MARK: - ViatorSchedule / Season / TimedEntry

    func testSeasonContainsIsInclusiveOfBothEndsAndOpenEndedWhenEndDateIsNil() throws {
        let openEnded = try decodeJSON(ViatorSchedule.Season.self, #"{"startDate": "2026-01-01"}"#)
        XCTAssertTrue(openEnded.contains(BookingDate(year: 2026, month: 1, day: 1)!))
        XCTAssertTrue(openEnded.contains(BookingDate(year: 2030, month: 1, day: 1)!))
        XCTAssertFalse(openEnded.contains(BookingDate(year: 2025, month: 12, day: 31)!))

        let bounded = try decodeJSON(ViatorSchedule.Season.self, #"{"startDate": "2026-01-01", "endDate": "2026-01-31"}"#)
        XCTAssertTrue(bounded.contains(BookingDate(year: 2026, month: 1, day: 31)!))
        XCTAssertFalse(bounded.contains(BookingDate(year: 2026, month: 2, day: 1)!))
    }

    func testTimedEntryUppercasesDaysOfWeekAndCollectsUnavailableDates() throws {
        let json = #"{"daysOfWeek": ["monday", "TUESDAY"], "timedEntries": [{"startTime": "09:00", "unavailableDates": [{"date": "2026-05-01"}]}]}"#
        let record = try decodeJSON(ViatorSchedule.PricingRecord.self, json)

        XCTAssertEqual(record.daysOfWeek, ["MONDAY", "TUESDAY"])
        XCTAssertEqual(record.timedEntries.first?.startTime, "09:00")
        XCTAssertTrue(record.timedEntries.first?.unavailableDates.contains(BookingDate(year: 2026, month: 5, day: 1)!) ?? false)
    }

    // MARK: - ViatorBookingQuestion

    func testBookingQuestionDefaultsGroupToPerBookingAndRequiredToOptional() throws {
        let question = try decodeJSON(ViatorBookingQuestion.self, #"{"id": "Q1"}"#)

        XCTAssertEqual(question.group, .perBooking)
        XCTAssertEqual(question.required, .optional)
        XCTAssertEqual(question.label, "Q1")
        XCTAssertFalse(question.requiresUnit)
    }

    func testBookingQuestionRequiresUnitOnlyForNumberAndUnitType() throws {
        let question = try decodeJSON(ViatorBookingQuestion.self, #"{"id": "Q1", "type": "NUMBER_AND_UNIT"}"#)
        XCTAssertTrue(question.requiresUnit)
    }

    // MARK: - ViatorLocation

    func testLocationJoinsAddressLinesAndDecodesCenter() throws {
        let json = """
        {"reference": "L1", "name": "Hotel", "address": {"street": "1 Main St", "postcode": "10001"}, "center": {"latitude": 1.5, "longitude": -2.5}}
        """
        let location = try decodeJSON(ViatorLocation.self, json)

        XCTAssertEqual(location.address, "1 Main St, 10001")
        XCTAssertEqual(location.latitude, 1.5)
        XCTAssertEqual(location.longitude, -2.5)
    }

    // MARK: - ViatorAvailability

    func testAvailabilityGroupsBookableItemsByOptionInOrderEncountered() throws {
        let json = """
        {
          "productCode": "P1",
          "currency": "USD",
          "bookableItems": [
            {"productOptionCode": "B", "available": true},
            {"productOptionCode": "A", "available": false, "unavailableReason": "SOLD_OUT"},
            {"productOptionCode": "B", "available": true}
          ]
        }
        """
        let availability = try decodeJSON(ViatorAvailability.self, json)

        let grouped = availability.itemsByOption
        XCTAssertEqual(grouped.map(\.optionCode), ["B", "A"])
        XCTAssertEqual(grouped.first?.items.count, 2)
        XCTAssertEqual(grouped.last?.items.first?.unavailableReason, "SOLD_OUT")
    }

    // MARK: - ViatorHold deadline

    func testHoldDeadlineIsTheEarliestOfAvailabilityAndPricingValidity() throws {
        let json = """
        {
          "cartRef": "cart1",
          "currency": "USD",
          "items": [{
            "bookingRef": "book1",
            "status": "BOOKABLE",
            "bookingHoldInfo": {
              "availability": {"validUntil": "2026-01-01T00:10:00Z"},
              "pricing": {"validUntil": "2026-01-01T00:05:00Z"}
            }
          }]
        }
        """
        let hold = try decodeJSON(ViatorHold.self, json)
        let item = hold.items.first

        XCTAssertTrue(item?.isBookable ?? false)
        XCTAssertEqual(item?.deadline?.expiresAt, ISO8601.date(from: "2026-01-01T00:05:00Z"))
    }

    // MARK: - ViatorBookingStatus

    func testBookingStatusMapsKnownRawValuesToRecordStatus() {
        XCTAssertEqual(ViatorBookingStatus("CONFIRMED").recordStatus, .confirmed)
        XCTAssertEqual(ViatorBookingStatus("ON_HOLD").recordStatus, .pending)
        XCTAssertEqual(ViatorBookingStatus("IN_PROGRESS").recordStatus, .pending)
        XCTAssertEqual(ViatorBookingStatus("REJECTED").recordStatus, .failed)
        XCTAssertEqual(ViatorBookingStatus("FAILED").recordStatus, .failed)
        XCTAssertEqual(ViatorBookingStatus("CANCELLED").recordStatus, .cancelled)
        XCTAssertEqual(ViatorBookingStatus("CANCELED").recordStatus, .cancelled)
        XCTAssertNil(ViatorBookingStatus("SOMETHING_ELSE").recordStatus)
    }

    // MARK: - ViatorCancellation

    func testCancellationIsAcceptedIsCaseInsensitive() throws {
        let accepted = try decodeJSON(ViatorCancellation.self, #"{"bookingId": "b1", "status": "accepted"}"#)
        XCTAssertTrue(accepted.isAccepted)

        let declined = try decodeJSON(ViatorCancellation.self, #"{"bookingId": "b1", "status": "DECLINED"}"#)
        XCTAssertFalse(declined.isAccepted)
    }

    // MARK: - ViatorCancellationPolicy summary

    func testCancellationPolicySummaryIsAllSalesFinalRegardlessOfWindows() throws {
        let json = #"{"type": "ALL_SALES_FINAL", "cancelIfBadWeather": false, "cancelIfInsufficientTravelers": false, "refundEligibility": []}"#
        let policy = try decodeJSON(ViatorCancellationPolicy.self, json)

        XCTAssertEqual(policy.summary(), .allSalesFinal)
    }

    func testCancellationPolicySummaryIsFreeCancellationWithinAWindow() throws {
        let json = """
        {"type": "STANDARD", "cancelIfBadWeather": false, "cancelIfInsufficientTravelers": false,
         "refundEligibility": [{"percentageRefundable": 100, "endTimestamp": "2099-01-01T00:00:00Z"}]}
        """
        let policy = try decodeJSON(ViatorCancellationPolicy.self, json)

        XCTAssertEqual(policy.summary(at: ISO8601.date(from: "2026-01-01T00:00:00Z")!), .freeCancellation(until: ISO8601.date(from: "2099-01-01T00:00:00Z"), percentage: 100))
    }

    func testCancellationPolicySummaryIsNoRefundOutsideAnyWindow() throws {
        let json = """
        {"type": "STANDARD", "cancelIfBadWeather": false, "cancelIfInsufficientTravelers": false,
         "refundEligibility": [{"percentageRefundable": 100, "endTimestamp": "2020-01-01T00:00:00Z"}]}
        """
        let policy = try decodeJSON(ViatorCancellationPolicy.self, json)

        XCTAssertEqual(policy.summary(at: ISO8601.date(from: "2026-01-01T00:00:00Z")!), .noRefund)
    }
}
