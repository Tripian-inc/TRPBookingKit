import XCTest
import CryptoKit
@testable import TRPBookingKit

final class VictoryRequestSignerTests: XCTestCase {

    func testSignatureStringForGETWithNoQueryEndsWithTrailingQuestionMark() throws {
        var request = URLRequest(url: URL(string: "https://api.sandbox.ticketevolution.com/v9/events/123")!)
        request.httpMethod = "GET"

        let signed = try VictoryRequestSigner.signatureString(for: request)

        XCTAssertEqual(signed, "GET api.sandbox.ticketevolution.com/v9/events/123?")
    }

    func testSignatureStringSortsQueryItemsRegardlessOfInputOrder() throws {
        var request = URLRequest(url: URL(string: "https://api.sandbox.ticketevolution.com/v9/listings?zeta=1&event_id=42")!)
        request.httpMethod = "GET"

        let signed = try VictoryRequestSigner.signatureString(for: request)

        XCTAssertEqual(signed, "GET api.sandbox.ticketevolution.com/v9/listings?event_id=42&zeta=1")
    }

    func testSignatureStringForPOSTUsesRawBodyString() throws {
        var request = URLRequest(url: URL(string: "https://api.sandbox.ticketevolution.com/v9/clients")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"a":1}"#.utf8)

        let signed = try VictoryRequestSigner.signatureString(for: request)

        XCTAssertEqual(signed, #"POST api.sandbox.ticketevolution.com/v9/clients?{"a":1}"#)
    }

    func testSignatureStringForPOSTWithNoBodyUsesEmptyString() throws {
        var request = URLRequest(url: URL(string: "https://api.sandbox.ticketevolution.com/v9/clients")!)
        request.httpMethod = "POST"

        let signed = try VictoryRequestSigner.signatureString(for: request)

        XCTAssertEqual(signed, "POST api.sandbox.ticketevolution.com/v9/clients?")
    }

    func testSignatureMatchesHMACSHA256Base64OfSecret() {
        let signer = VictoryRequestSigner(token: "tok", secret: "secret")
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data("hello".utf8), using: SymmetricKey(data: Data("secret".utf8))))
            .base64EncodedString()

        XCTAssertEqual(signer.signature(of: "hello"), expected)
    }

    func testSignatureDiffersForDifferentSecrets() {
        let a = VictoryRequestSigner(token: "tok", secret: "secret-a")
        let b = VictoryRequestSigner(token: "tok", secret: "secret-b")

        XCTAssertNotEqual(a.signature(of: "same string"), b.signature(of: "same string"))
    }

    func testAuthorizeSetsTokenAndSignatureHeadersAndSortsTheURLQuery() throws {
        let signer = VictoryRequestSigner(token: "tok-123", secret: "sekret")
        var request = URLRequest(url: URL(string: "https://api.sandbox.ticketevolution.com/v9/listings?zeta=1&event_id=42")!)
        request.httpMethod = "GET"

        try signer.authorize(&request)

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Token"), "tok-123")
        XCTAssertEqual(request.url?.query, "event_id=42&zeta=1")
        let expectedSignature = signer.signature(of: try VictoryRequestSigner.signatureString(for: request))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Signature"), expectedSignature)
    }

    func testAuthorizeLeavesAURLWithNoQueryUnchanged() throws {
        let signer = VictoryRequestSigner(token: "tok", secret: "sekret")
        var request = URLRequest(url: URL(string: "https://api.sandbox.ticketevolution.com/v9/events/1")!)
        request.httpMethod = "GET"

        try signer.authorize(&request)

        XCTAssertEqual(request.url?.absoluteString, "https://api.sandbox.ticketevolution.com/v9/events/1")
    }
}
