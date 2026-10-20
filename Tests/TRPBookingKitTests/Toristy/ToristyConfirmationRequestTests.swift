import XCTest
@testable import TRPBookingKit

/// Reads the confirmation body as the bytes `ProviderHTTPClient` puts on the wire, so a rounding drift in the amount or a
/// local time zone in the date cannot hide behind a parsed number or a lenient date parser.
final class ToristyConfirmationRequestTests: XCTestCase {

    private let reference = BookingReference(provider: .toristy, primary: "cart1", secondary: "conf1")

    private func makeReceipt(paidAt: Date) -> PaymentReceipt {
        PaymentReceipt(chargeId: "ch1", amount: 30.53, currency: "EUR", cardBrand: "Visa", last4: "4242", paidAt: paidAt)
    }

    private func sentBody(amount: Decimal, currency: String, paidAt: Date = Date()) async throws -> String {
        let transport = RecordingHTTPTransport()
        let client = ToristyAPIClient(credentials: ToristyCredentials(apiKey: "tor-key"), transport: transport)
        try await client.confirm(reference, receipt: makeReceipt(paidAt: paidAt), amount: amount, currency: currency)
        let body = try XCTUnwrap(transport.requests.first?.httpBody)
        return try XCTUnwrap(String(data: body, encoding: .utf8))
    }

    func testTransactionDateIsSentAsTheUtcInstantOfReceiptPaidAt() async throws {
        let body = try await sentBody(amount: 30.53, currency: "EUR", paidAt: Date(timeIntervalSince1970: 1_760_000_000))

        XCTAssertTrue(body.contains(#""transactionDate":"2025-10-09T08:53:20Z""#), body)
        XCTAssertNotNil(body.range(of: #""transactionDate":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z""#, options: .regularExpression))
    }

    func testAmountIsSentExactlyAsTheValidationTotalPriceWhenItArrivedAsAStringOrANumber() async throws {
        let stringDecoded = try JSONDecoder().decode(ToristyValidation.self,
            from: Data(#"{"cartid": "c1", "confirmationCode": "cc1", "totalPrice": "30.53", "currency": "EUR"}"#.utf8))
        let numberDecoded = try JSONDecoder().decode(ToristyValidation.self,
            from: Data(#"{"cartid": "c1", "confirmationCode": "cc1", "totalPrice": 30.53, "currency": "EUR"}"#.utf8))

        for validation in [stringDecoded, numberDecoded] {
            let body = try await sentBody(amount: validation.totalPrice, currency: validation.currency)

            XCTAssertTrue(body.hasPrefix(#"{"amount":30.53,"currency":"EUR","#), body)
        }
    }

    func testCurrencyIsSentUppercased() async throws {
        let body = try await sentBody(amount: 30.53, currency: "eur")

        XCTAssertTrue(body.contains(#""currency":"EUR""#), body)
        XCTAssertFalse(body.contains(#""currency":"eur""#), body)
    }
}
