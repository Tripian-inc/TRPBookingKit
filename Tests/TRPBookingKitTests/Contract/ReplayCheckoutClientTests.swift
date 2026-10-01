import Foundation
import XCTest
@testable import TRPBookingKit

/// The replay clients walk the recorded provider flows and surface error envelopes as `ContractError`.
final class ReplayCheckoutClientTests: XCTestCase {

    func testViatorFlowWalksFromCreateToCancelledBooking() async throws {
        let exchanges = try ContractFixtures.exchanges(in: "viator")
        XCTAssertEqual(exchanges.map(\.name).first, "01-create")
        XCTAssertEqual(exchanges.count, 13)
        let script = BC.ReplayScript(exchanges)
        let checkout = BC.ReplayCheckoutClient(script: script)
        let bookings = BC.ReplayBookingClient(script: script)

        var statuses: [String] = []
        var lastActionId: String?
        for exchange in exchanges {
            if exchange.request.path.contains("/actions/") {
                XCTAssertEqual(lastActionId.map { exchange.request.path.contains("/actions/\($0)") }, true, exchange.name)
            }
            switch try await performContractRequest(exchange.request, checkout: checkout, bookings: bookings) {
            case .checkout(let response):
                statuses.append(response.checkout.status.rawValue)
                lastActionId = response.checkout.nextAction?.id ?? lastActionId
                if exchange.name == "09-payment" {
                    XCTAssertEqual(response.httpStatus, 202)
                    XCTAssertEqual(response.retryAfter, 2)
                    XCTAssertTrue(response.isProcessing)
                }
            case .booking(let booking):
                statuses.append("booking:" + booking.status.rawValue)
            case .page(let page):
                XCTAssertFalse(page.bookings.isEmpty)
                XCTAssertNotNil(page.pagination)
                statuses.append("page")
            }
        }

        XCTAssertEqual(statuses, Array(repeating: "collecting_details", count: 7)
            + ["awaiting_payment", "processing", "confirmed", "page", "booking:confirmed", "booking:cancelled"])

        let remaining = await script.remaining
        XCTAssertTrue(remaining.isEmpty)
        let sent = await script.sent
        XCTAssertEqual(sent.count, exchanges.count)
        for (request, exchange) in zip(sent, exchanges) {
            XCTAssertEqual(request.signature, exchange.request.signature, exchange.name)
            XCTAssertEqual(try canonical(request.body), try canonical(exchange.request.body), exchange.name)
            if exchange.request.method == "POST" {
                XCTAssertEqual(request.idempotencyKey?.rawValue, exchange.request.headers["Idempotency-Key"], exchange.name)
            }
        }
    }

    func testEveryErrorFixtureThrowsItsContractError() async throws {
        var checked = 0
        for directory in ["toristy/errors", "viator/errors", "victory/errors"] {
            for exchange in try ContractFixtures.exchanges(in: directory) {
                let script = BC.ReplayScript([exchange])
                do {
                    _ = try await performContractRequest(exchange.request, checkout: BC.ReplayCheckoutClient(script: script),
                                          bookings: BC.ReplayBookingClient(script: script))
                    XCTFail("\(directory)/\(exchange.name) did not throw")
                } catch let error as BC.ContractError {
                    XCTAssertEqual(error.code.rawValue, exchange.name, "\(directory)/\(exchange.name)")
                    XCTAssertEqual(error.httpStatus, exchange.response.status, "\(directory)/\(exchange.name)")
                    XCTAssertGreaterThanOrEqual(error.httpStatus, 400)
                }
                checked += 1
            }
        }
        XCTAssertEqual(checked, 11)
    }

    func testPaymentDeclinedCarriesTheCheckoutStillAwaitingPayment() async throws {
        let exchange = try ContractFixtures.exchange("viator/errors", "PAYMENT_DECLINED")
        let script = BC.ReplayScript([exchange])
        do {
            _ = try await performContractRequest(exchange.request, checkout: BC.ReplayCheckoutClient(script: script),
                                  bookings: BC.ReplayBookingClient(script: script))
            XCTFail("PAYMENT_DECLINED did not throw")
        } catch let error as BC.ContractError {
            XCTAssertEqual(error.code, .paymentDeclined)
            XCTAssertEqual(error.data.checkout?.status.value, .awaitingPayment)
        }
    }

    func testVersionUnsupportedListsTheSupportedVersions() async throws {
        let exchange = try ContractFixtures.exchange("viator/errors", "VERSION_UNSUPPORTED")
        let script = BC.ReplayScript([exchange])
        do {
            _ = try await performContractRequest(exchange.request, checkout: BC.ReplayCheckoutClient(script: script),
                                  bookings: BC.ReplayBookingClient(script: script))
            XCTFail("VERSION_UNSUPPORTED did not throw")
        } catch let error as BC.ContractError {
            XCTAssertEqual(error.data.supported, [BookingContract.version])
        }
    }

    func testARequestOffScriptIsRejected() async throws {
        let script = BC.ReplayScript(try ContractFixtures.exchanges(in: "viator"))
        let client = BC.ReplayCheckoutClient(script: script)
        do {
            _ = try await client.get(id: "chk_missing", lang: "en")
            XCTFail("an unexpected request was answered")
        } catch BC.CheckoutClientError.unexpectedRequest(_, let actual) {
            XCTAssertEqual(actual, "GET /tour-api/checkouts/chk_missing?lang=en")
        }
    }

    func testAnExhaustedScriptIsRejected() async throws {
        let client = BC.ReplayCheckoutClient(script: BC.ReplayScript([]))
        do {
            _ = try await client.get(id: "chk_1", lang: "en")
            XCTFail("an empty script answered")
        } catch BC.CheckoutClientError.fixturesExhausted {
        }
    }

    private func canonical(_ value: BC.JSONValue?) throws -> CanonicalJSON {
        guard let value, !value.isNull else { return .null }
        return try CanonicalJSON(data: JSONEncoder().encode(value))
    }
}
