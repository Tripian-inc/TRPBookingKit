import XCTest
@testable import TRPBookingKit

final class ViatorSelectionValidatorTests: XCTestCase {

    private let validator = ViatorSelectionValidator()

    private func makeProduct(minTravelers: Int = 1, maxTravelers: Int? = nil, ageBands: String = "") throws -> ViatorProduct {
        let json = """
        {"productCode": "P1",
         "pricingInfo": {"ageBands": [\(ageBands)]},
         "bookingRequirements": {"minTravelersPerBooking": \(minTravelers)\(maxTravelers.map { ", \"maxTravelersPerBooking\": \($0)" } ?? "")}}
        """
        return try decodeJSON(ViatorProduct.self, json)
    }

    private func adultRule(min: Int = 0, max: Int? = nil) -> String {
        #"{"ageBand": "ADULT", "minTravelersPerBooking": \#(min)\#(max.map { ", \"maxTravelersPerBooking\": \($0)" } ?? "")}"#
    }

    private func childRule(min: Int = 0, max: Int? = nil) -> String {
        #"{"ageBand": "CHILD", "minTravelersPerBooking": \#(min)\#(max.map { ", \"maxTravelersPerBooking\": \($0)" } ?? "")}"#
    }

    // MARK: - paxIssues

    func testPaxIssuesReportsNoTravelersWhenEverySelectionIsZero() throws {
        let product = try makeProduct(ageBands: adultRule())

        let issues = validator.paxIssues([ViatorPax(ageBand: .adult, numberOfTravelers: 0)], product: product)

        XCTAssertEqual(issues, [.noTravelers])
    }

    func testPaxIssuesReportsTravelerCountOutsideBookingLevelBounds() throws {
        let product = try makeProduct(minTravelers: 2, maxTravelers: 4, ageBands: adultRule())

        let issues = validator.paxIssues([ViatorPax(ageBand: .adult, numberOfTravelers: 1)], product: product)

        XCTAssertTrue(issues.contains(.travelerCount(requested: 1, minimum: 2, maximum: 4)))
    }

    func testPaxIssuesReportsNeedsAdultWhenNoAdultOrTravelerBandIsSelected() throws {
        let product = try makeProduct(ageBands: "\(adultRule()), \(childRule())")

        let issues = validator.paxIssues([ViatorPax(ageBand: .child, numberOfTravelers: 1)], product: product)

        XCTAssertTrue(issues.contains(.needsAdult))
    }

    func testPaxIssuesAllowsATravelerBandInPlaceOfAnAdult() throws {
        let json = #"{"ageBand": "TRAVELER", "minTravelersPerBooking": 0}"#
        let product = try makeProduct(ageBands: json)

        let issues = validator.paxIssues([ViatorPax(ageBand: .traveler, numberOfTravelers: 2)], product: product)

        XCTAssertFalse(issues.contains(.needsAdult))
    }

    func testPaxIssuesReportsUnknownAgeBandWhenTheProductHasNoRuleForIt() throws {
        let product = try makeProduct(ageBands: adultRule())

        let issues = validator.paxIssues([
            ViatorPax(ageBand: .adult, numberOfTravelers: 1),
            ViatorPax(ageBand: .senior, numberOfTravelers: 1)
        ], product: product)

        XCTAssertTrue(issues.contains(.unknownAgeBand(.senior)))
    }

    func testPaxIssuesReportsAgeBandCountWhenASelectedBandExceedsItsOwnBounds() throws {
        let product = try makeProduct(ageBands: "\(adultRule(min: 1)), \(childRule(min: 0, max: 2))")

        let issues = validator.paxIssues([
            ViatorPax(ageBand: .adult, numberOfTravelers: 1),
            ViatorPax(ageBand: .child, numberOfTravelers: 3)
        ], product: product)

        XCTAssertTrue(issues.contains(.ageBandCount(band: .child, requested: 3, minimum: 0, maximum: 2)))
    }

    func testPaxIssuesReportsAgeBandCountWhenARequiredBandIsAbsentAtZero() throws {
        let product = try makeProduct(ageBands: "\(adultRule(min: 1)), \(childRule(min: 1))")

        let issues = validator.paxIssues([ViatorPax(ageBand: .adult, numberOfTravelers: 1)], product: product)

        XCTAssertTrue(issues.contains(.ageBandCount(band: .child, requested: 0, minimum: 1, maximum: nil)))
    }

    func testPaxIssuesIsEmptyForAValidParty() throws {
        let product = try makeProduct(minTravelers: 1, maxTravelers: 4, ageBands: adultRule(min: 1, max: 4))

        let issues = validator.paxIssues([ViatorPax(ageBand: .adult, numberOfTravelers: 2)], product: product)

        XCTAssertTrue(issues.isEmpty)
    }

    func testValidatePaxThrowsInvalidSelectionWithEveryIssue() throws {
        let product = try makeProduct(ageBands: adultRule())

        XCTAssertThrowsError(try validator.validate([ViatorPax(ageBand: .adult, numberOfTravelers: 0)], product: product)) { error in
            guard case BookingError.invalidSelection(let messages) = error else { return XCTFail("Expected invalidSelection, got \(error)") }
            XCTAssertEqual(messages, [ViatorSelectionIssue.noTravelers.description])
        }
    }

    // MARK: - answerIssues

    private func makeQuestion(id: String, group: String = "PER_BOOKING", required: String = "MANDATORY", maxLength: Int? = nil, allowedAnswers: [String] = [], units: [String] = [], type: String = "STRING") throws -> ViatorBookingQuestion {
        let json = """
        {"id": "\(id)", "group": "\(group)", "required": "\(required)", "type": "\(type)",
         \(maxLength.map { "\"maxLength\": \($0)," } ?? "")
         "allowedAnswers": \(encodeStrings(allowedAnswers)),
         "units": \(encodeStrings(units))}
        """
        return try decodeJSON(ViatorBookingQuestion.self, json)
    }

    private func encodeStrings(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    private func makeProductAsking(_ ids: String...) throws -> ViatorProduct {
        let json = """
        {"productCode": "P1", "bookingQuestions": [\(ids.map { "\"\($0)\"" }.joined(separator: ","))]}
        """
        return try decodeJSON(ViatorProduct.self, json)
    }

    func testAnswerIssuesReportsUnknownQuestionWhenAnsweringSomethingNotAsked() throws {
        let product = try makeProductAsking("Q1")
        let question = try makeQuestion(id: "Q1", required: "OPTIONAL")

        let issues = validator.answerIssues([ViatorAnswer(question: "Q2", answer: "x")], product: product, questions: [question], travelerCount: 1)

        XCTAssertTrue(issues.contains(.unknownQuestion("Q2")))
    }

    func testAnswerIssuesReportsMissingAnswerForAMandatoryPerBookingQuestion() throws {
        let product = try makeProductAsking("Q1")
        let question = try makeQuestion(id: "Q1")

        let issues = validator.answerIssues([], product: product, questions: [question], travelerCount: 1)

        XCTAssertTrue(issues.contains(.missingAnswer(questionId: "Q1", travelerNum: nil)))
    }

    func testAnswerIssuesReportsMissingAnswerPerTravelerWhenGroupIsPerTraveler() throws {
        let product = try makeProductAsking("Q1")
        let question = try makeQuestion(id: "Q1", group: "PER_TRAVELER")

        let issues = validator.answerIssues(
            [ViatorAnswer(question: "Q1", answer: "yes", travelerNum: 1)],
            product: product, questions: [question], travelerCount: 2
        )

        XCTAssertTrue(issues.contains(.missingAnswer(questionId: "Q1", travelerNum: 2)))
        XCTAssertFalse(issues.contains(.missingAnswer(questionId: "Q1", travelerNum: 1)))
    }

    func testAnswerIssuesDoesNotRequireAConditionalQuestionThatWasNeverAnswered() throws {
        let product = try makeProductAsking("Q1")
        let question = try makeQuestion(id: "Q1", required: "CONDITIONAL")

        let issues = validator.answerIssues([], product: product, questions: [question], travelerCount: 1)

        XCTAssertTrue(issues.isEmpty)
    }

    func testAnswerIssuesReportsAnswerTooLong() throws {
        let product = try makeProductAsking("Q1")
        let question = try makeQuestion(id: "Q1", required: "OPTIONAL", maxLength: 3)

        let issues = validator.answerIssues([ViatorAnswer(question: "Q1", answer: "toolong")], product: product, questions: [question], travelerCount: 1)

        XCTAssertTrue(issues.contains(.answerTooLong(questionId: "Q1", maximum: 3)))
    }

    func testAnswerIssuesReportsAnswerNotAllowedWhenOutsideTheAllowedList() throws {
        let product = try makeProductAsking("Q1")
        let question = try makeQuestion(id: "Q1", required: "OPTIONAL", allowedAnswers: ["yes", "no"])

        let issues = validator.answerIssues([ViatorAnswer(question: "Q1", answer: "maybe")], product: product, questions: [question], travelerCount: 1)

        XCTAssertTrue(issues.contains(.answerNotAllowed(questionId: "Q1")))
    }

    func testAnswerIssuesReportsInvalidUnitWhenTheQuestionRequiresAUnitNotInTheAllowList() throws {
        let product = try makeProductAsking("Q1")
        let question = try makeQuestion(id: "Q1", required: "OPTIONAL", units: ["CM", "IN"], type: "NUMBER_AND_UNIT")

        let issues = validator.answerIssues([ViatorAnswer(question: "Q1", answer: "180", unit: "KG")], product: product, questions: [question], travelerCount: 1)

        XCTAssertTrue(issues.contains(.invalidUnit(questionId: "Q1")))
    }

    func testAnswerIssuesIsEmptyForAValidMandatoryAnswer() throws {
        let product = try makeProductAsking("Q1")
        let question = try makeQuestion(id: "Q1")

        let issues = validator.answerIssues([ViatorAnswer(question: "Q1", answer: "yes")], product: product, questions: [question], travelerCount: 1)

        XCTAssertTrue(issues.isEmpty)
    }

    func testValidateAnswersThrowsInvalidSelectionWithEveryIssue() throws {
        let product = try makeProductAsking("Q1")
        let question = try makeQuestion(id: "Q1")
        let details = ViatorBookerDetails(firstName: "A", lastName: "B", email: "a@b.com", phone: "1", answers: [], languageGuide: nil)

        XCTAssertThrowsError(try validator.validate(details, product: product, questions: [question], travelerCount: 1)) { error in
            guard case BookingError.invalidSelection(let messages) = error else { return XCTFail("Expected invalidSelection, got \(error)") }
            XCTAssertEqual(messages, [ViatorSelectionIssue.missingAnswer(questionId: "Q1", travelerNum: nil).description])
        }
    }
}
