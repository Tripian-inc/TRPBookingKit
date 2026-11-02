import Foundation
import XCTest
@testable import TRPBookingKit

/// `FieldError.code` is optional on the wire: present when a local rejection names a reason, absent from the
/// server fixtures that predate it.
final class FieldErrorCodeTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func testDecodesWithoutCode() throws {
        let json = #"{"field": "lead.email", "message": "Enter a valid email address."}"#
        let error = try decoder.decode(BookingContract.ErrorData.FieldError.self, from: Data(json.utf8))
        XCTAssertEqual(error.field, "lead.email")
        XCTAssertNil(error.code)
        XCTAssertEqual(error.message, "Enter a valid email address.")
    }

    func testDecodesWithCode() throws {
        let json = #"{"field": "date", "code": "missing_date", "message": "Choose one of the available dates."}"#
        let error = try decoder.decode(BookingContract.ErrorData.FieldError.self, from: Data(json.utf8))
        XCTAssertEqual(error.code, "missing_date")
    }

    func testEncodesWithoutCodeKeyWhenNil() throws {
        let error = BookingContract.ErrorData.FieldError(field: "date", message: "Choose one of the available dates.")
        let data = try encoder.encode(error)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(object?["code"])
    }

    func testEncodesCodeWhenPresent() throws {
        let error = BookingContract.ErrorData.FieldError(field: "date", code: "missing_date", message: "Choose one of the available dates.")
        let data = try encoder.encode(error)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["code"] as? String, "missing_date")
    }

    func testFieldErrorCodeRawValuesAreSnakeCaseAndUnique() {
        let pattern = "^[a-z]+(_[a-z]+)*$"
        let rawValues = FieldErrorCode.allCases.map(\.rawValue)
        for rawValue in rawValues {
            XCTAssertNotNil(rawValue.range(of: pattern, options: .regularExpression), "\(rawValue) is not snake_case")
        }
        XCTAssertEqual(rawValues.count, Set(rawValues).count, "duplicate FieldErrorCode raw values")
    }

    func testInvalidSelectionReportsInvalidAnswerCode() {
        let rejection = FlowRejection.from(BookingError.invalidSelection(["x"]))
        XCTAssertEqual(rejection.code, .validation)
        let fieldError = rejection.errors.first
        XCTAssertEqual(fieldError?.field, "answers")
        XCTAssertEqual(fieldError?.code, "invalid_answer")
        XCTAssertEqual(fieldError?.message, "x")
    }

    func testCreateWithUnknownProductReportsProductNotBookableCode() async throws {
        let checkout = LocalCheckoutClient(viator: nil, store: InMemoryBookingRecordStore(), catalog: StaticProductCatalog([]))
        do {
            _ = try await checkout.create(BookingContract.CreateCheckoutRequest(
                productId: "UNKNOWN-PRODUCT", currency: "EUR", bookingUuid: "3f6c1a9e-8d2b-4b7a-a1c4-5e9f0d2b7c11", lang: "en"))
            XCTFail("Expected VALIDATION")
        } catch let error as BookingContract.ContractError {
            let fieldError = try XCTUnwrap(error.data.errors.first)
            XCTAssertEqual(fieldError.field, "productId")
            XCTAssertEqual(fieldError.code, "product_not_bookable")
            XCTAssertEqual(fieldError.message, "This product cannot be booked in the app.")
        }
    }
}
