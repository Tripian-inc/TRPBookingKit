import Foundation
import XCTest
@testable import TRPBookingKit

/// `ConditionEvaluator` against hand-written clauses and the conditions in the `a-full-flow` fixtures.
final class ConditionEvaluatorTests: XCTestCase {

    private typealias Clause = BC.Condition.Clause

    private func holds(_ field: String, _ op: BC.ConditionOp, _ values: [BC.JSONValue]? = nil,
                       in answers: BC.Answers) -> Bool {
        BC.ConditionEvaluator.isSatisfied(Clause(field: field, op: op, values: values), answers: answers)
    }

    func testIn() {
        XCTAssertTrue(holds("pickup_type", .in, ["hotel", "port"], in: ["pickup_type": "port"]))
        XCTAssertFalse(holds("pickup_type", .in, ["hotel", "port"], in: ["pickup_type": "none"]))
        XCTAssertTrue(holds("diet", .in, ["vegan"], in: ["diet": ["gluten", "vegan"]]))
        XCTAssertFalse(holds("pickup_type", .in, ["hotel"], in: [:]))
    }

    func testNotIn() {
        XCTAssertTrue(holds("nationality", .notIn, ["ES", "FR"], in: ["nationality": "GB"]))
        XCTAssertFalse(holds("nationality", .notIn, ["ES", "FR"], in: ["nationality": "ES"]))
    }

    func testEq() {
        XCTAssertTrue(holds("newsletter", .eq, [true], in: ["newsletter": true]))
        XCTAssertFalse(holds("newsletter", .eq, [true], in: ["newsletter": false]))
        XCTAssertTrue(holds("count", .eq, [2], in: ["count": "2"]))
    }

    func testGtAndLt() {
        XCTAssertTrue(holds("age", .gt, [65], in: ["age": 70]))
        XCTAssertFalse(holds("age", .gt, [65], in: ["age": 65]))
        XCTAssertTrue(holds("age", .lt, [16], in: ["age": 9]))
        XCTAssertFalse(holds("age", .lt, [16], in: ["age": "nine"]))
        XCTAssertTrue(holds("date", .lt, ["2026-11-01"], in: ["date": "2026-10-14"]))
    }

    func testExists() {
        XCTAssertTrue(holds("allergies", .exists, in: ["allergies": ["nuts"]]))
        XCTAssertFalse(holds("allergies", .exists, in: ["allergies": []]))
        XCTAssertFalse(holds("note", .exists, in: ["note": ""]))
        XCTAssertFalse(holds("note", .exists, in: ["note": nil]))
        XCTAssertFalse(holds("note", .exists, in: [:]))
    }

    func testUnknownOpIsFalseAndMissingConditionIsTrue() {
        let clause = Clause(field: "age", op: BC.OpenEnum<BC.ConditionOp>(rawValue: "between"), values: [1, 2])
        XCTAssertFalse(BC.ConditionEvaluator.isSatisfied(clause, answers: ["age": 1]))
        XCTAssertTrue(BC.ConditionEvaluator.isSatisfied(nil as BC.Condition?, answers: [:]))
    }

    func testAllAndAny() {
        let all = BC.Condition.all([Clause(field: "a", op: .eq, values: [1]), Clause(field: "b", op: .eq, values: [2])])
        let any = BC.Condition.any([Clause(field: "a", op: .eq, values: [1]), Clause(field: "b", op: .eq, values: [2])])
        XCTAssertTrue(BC.ConditionEvaluator.isSatisfied(all, answers: ["a": 1, "b": 2]))
        XCTAssertFalse(BC.ConditionEvaluator.isSatisfied(all, answers: ["a": 1, "b": 3]))
        XCTAssertTrue(BC.ConditionEvaluator.isSatisfied(any, answers: ["a": 0, "b": 2]))
        XCTAssertFalse(BC.ConditionEvaluator.isSatisfied(any, answers: ["a": 0, "b": 0]))
    }

    func testDetailsStepConditionsFromTheFullFlow() throws {
        let fields = try fields(in: "_synthetic/a-full-flow/04-guests.response.json")
        let answers = try submittedAnswers("_synthetic/a-full-flow/05-details.request.json")

        XCTAssertTrue(try field("newsletterEmail", fields).isVisible(answers: answers))
        XCTAssertFalse(try field("newsletterEmail", fields).isVisible(answers: with(answers, "newsletter", false)))

        let pickup = try field("pickup", fields)
        XCTAssertTrue(pickup.isVisible(answers: answers))
        XCTAssertTrue(pickup.isRequired(answers: answers))
        XCTAssertFalse(pickup.isVisible(answers: with(answers, "pickup_type", "none")))
        XCTAssertFalse(pickup.isRequired(answers: with(answers, "pickup_type", "none")))

        let pickupTime = try field("pickup_time", fields)
        XCTAssertTrue(pickupTime.isVisible(answers: answers))
        XCTAssertFalse(pickupTime.isVisible(answers: with(answers, "pickup", nil)))

        let dietary = try field("dietary_notes", fields)
        XCTAssertTrue(dietary.isVisible(answers: answers))
        XCTAssertTrue(dietary.isVisible(answers: with(answers, "diet_pref", "none")))
        XCTAssertFalse(dietary.isVisible(answers: with(with(answers, "diet_pref", "none"), "allergies", [])))

        let passport = try field("t1.passport", fields)
        XCTAssertTrue(passport.isRequired(answers: answers))
        XCTAssertFalse(passport.isRequired(answers: with(answers, "t1.nationality", "ES")))

        let weight = try field("t1.weight", fields)
        XCTAssertFalse(weight.isRequired(answers: answers))
        XCTAssertTrue(weight.isRequired(answers: with(answers, "t1.age", 70)))
        XCTAssertTrue(weight.isRequired(answers: with(answers, "t1.age", 12)))

        let guardian = try field("t3.guardian", fields)
        XCTAssertTrue(guardian.isVisible(answers: answers))
        XCTAssertFalse(guardian.isVisible(answers: with(answers, "t3.age", 30)))
    }

    func testPackageStepConditionReadsIntoQuantityUnits() throws {
        let fields = try fields(in: "_synthetic/a-full-flow/03-package.response.json")
        let childSeat = try field("childSeat", fields)
        let units = try submittedAnswers("_synthetic/a-full-flow/04-guests.request.json")
        XCTAssertTrue(childSeat.isVisible(answers: units))
        XCTAssertFalse(childSeat.isVisible(answers: with(units, "units", ["ADULT": 2, "CHILD": 0, "CABIN": 0])))
    }

    private func fields(in file: String) throws -> [BC.Field] {
        let body = try XCTUnwrap(ContractFixtures.body(file))
        let checkout = try XCTUnwrap(JSONDecoder().decode(BC.Envelope<BC.Checkout>.self, from: body).data)
        return Self.fields(in: try XCTUnwrap(checkout.currentStep?.blocks))
    }

    private static func fields(in blocks: [BC.Block]) -> [BC.Field] {
        blocks.flatMap { block -> [BC.Field] in
            switch block {
            case .field(let field): return [field]
            case .section(let section): return fields(in: section.blocks)
            default: return []
            }
        }
    }

    private func field(_ id: String, _ fields: [BC.Field]) throws -> BC.Field {
        try XCTUnwrap(fields.first { $0.id == id }, "no field \(id)")
    }

    private func submittedAnswers(_ file: String) throws -> BC.Answers {
        let body = try XCTUnwrap(ContractFixtures.body(file))
        return try JSONDecoder().decode(BC.SubmitStepRequest.self, from: body).answers
    }

    private func with(_ answers: BC.Answers, _ key: String, _ value: BC.JSONValue) -> BC.Answers {
        var copy = answers
        copy.values[key] = value
        return copy
    }
}
