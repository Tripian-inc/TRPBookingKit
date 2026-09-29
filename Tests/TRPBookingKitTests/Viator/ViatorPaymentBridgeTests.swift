import XCTest
@testable import TRPBookingKit

final class ViatorPaymentBridgeTests: XCTestCase {

    // MARK: - ViatorPaymentMessage

    func testMessageParsesReady() {
        XCTAssertEqual(ViatorPaymentMessage(body: ["event": "ready"]), .ready)
    }

    func testMessageParsesSuccessWithANonEmptyToken() {
        XCTAssertEqual(ViatorPaymentMessage(body: ["event": "success", "paymentToken": "tok"]), .success(paymentToken: "tok"))
    }

    func testMessageIsNilForASuccessEventWithAnEmptyToken() {
        XCTAssertNil(ViatorPaymentMessage(body: ["event": "success", "paymentToken": ""]))
    }

    func testMessageIsNilForASuccessEventWithNoToken() {
        XCTAssertNil(ViatorPaymentMessage(body: ["event": "success"]))
    }

    func testMessageParsesErrorWithCodeCoercedToString() {
        XCTAssertEqual(ViatorPaymentMessage(body: ["event": "error", "code": 42, "message": "boom"]),
                       .error(code: "42", message: "boom"))
    }

    func testMessageParsesErrorWithNoCodeOrMessage() {
        XCTAssertEqual(ViatorPaymentMessage(body: ["event": "error"]), .error(code: nil, message: nil))
    }

    func testMessageParsesCancel() {
        XCTAssertEqual(ViatorPaymentMessage(body: ["event": "cancel"]), .cancel)
    }

    func testMessageIsNilForAnUnrecognizedEvent() {
        XCTAssertNil(ViatorPaymentMessage(body: ["event": "something-else"]))
    }

    func testMessageIsNilForANonDictionaryBody() {
        XCTAssertNil(ViatorPaymentMessage(body: "not-a-dictionary"))
    }

    func testMessageIsNilWhenTheEventKeyIsMissing() {
        XCTAssertNil(ViatorPaymentMessage(body: ["paymentToken": "tok"]))
    }

    // MARK: - ViatorPaymentScript

    func testStartScriptEmbedsTheSessionTokenAndSupportedLanguage() {
        let script = ViatorPaymentScript.start(sessionToken: "sess-1", languageCode: "fr")

        XCTAssertTrue(script.contains("window.trpViatorPayment && window.trpViatorPayment.start("))
        XCTAssertTrue(script.contains("\"sessionToken\":\"sess-1\""))
        XCTAssertTrue(script.contains("\"language\":\"fr\""))
    }

    func testStartScriptFallsBackToEnglishForAnUnsupportedLanguage() {
        let script = ViatorPaymentScript.start(sessionToken: "sess-1", languageCode: "tr")

        XCTAssertTrue(script.contains("\"language\":\"en\""))
    }
}
