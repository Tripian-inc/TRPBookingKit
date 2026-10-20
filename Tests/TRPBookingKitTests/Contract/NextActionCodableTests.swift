import Foundation
import XCTest
@testable import TRPBookingKit

/// Round-trips the `provider_hosted_cart` `NextAction` case through `JSONEncoder`/`JSONDecoder`.
final class NextActionCodableTests: XCTestCase {
    private typealias BC = BookingContract

    func testProviderHostedCartRoundTripsWithAnExplicitPollInterval() throws {
        let action = BC.NextAction.providerHostedCart(BC.NextAction.Payload(
            id: "act_01J9ZTB4", params: BC.ProviderHostedCartParams(url: "https://embed.toristy.com/cart?apikey=test-key", pollIntervalSeconds: 5),
            expiresAt: "2026-10-02T09:42:00Z"))

        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(BC.NextAction.self, from: data)

        XCTAssertEqual(decoded, action)
        XCTAssertEqual(decoded.typeRawValue, "provider_hosted_cart")
        XCTAssertEqual(decoded.id, "act_01J9ZTB4")
    }

    func testProviderHostedCartParamsDefaultsThePollIntervalWhenTheKeyIsMissing() throws {
        let json = Data("{\"url\": \"https://embed.toristy.com/cart?apikey=test-key\"}".utf8)
        let params = try JSONDecoder().decode(BC.ProviderHostedCartParams.self, from: json)
        XCTAssertEqual(params.pollIntervalSeconds, 3)
    }

    // MARK: - ProviderHostedCartParams.settlement

    func testProviderHostedCartParamsDefaultsSettlementToPollWhenTheKeyIsMissing() throws {
        let json = Data(#"{"url": "https://checkout.ticketevolution.com/x"}"#.utf8)
        let params = try JSONDecoder().decode(BC.ProviderHostedCartParams.self, from: json)
        XCTAssertEqual(params.settlement, .poll)
    }

    func testProviderHostedCartParamsDecodesANoneSettlement() throws {
        let json = Data(#"{"url": "https://checkout.ticketevolution.com/x", "settlement": "none"}"#.utf8)
        let params = try JSONDecoder().decode(BC.ProviderHostedCartParams.self, from: json)
        XCTAssertEqual(params.settlement, .handOff)
    }

    func testProviderHostedCartParamsFallsBackToPollForAnUnknownSettlementValue() throws {
        let json = Data(#"{"url": "https://checkout.ticketevolution.com/x", "settlement": "mystery"}"#.utf8)
        let params = try JSONDecoder().decode(BC.ProviderHostedCartParams.self, from: json)
        XCTAssertEqual(params.settlement, .poll)
    }

    func testProviderHostedCartParamsEncodingOmitsSettlementWhenItIsPoll() throws {
        let params = BC.ProviderHostedCartParams(url: "https://checkout.ticketevolution.com/x", pollIntervalSeconds: 3, settlement: .poll)
        let data = try JSONEncoder().encode(params)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(object?["settlement"])
    }

    func testProviderHostedCartParamsRoundTripsANoneSettlement() throws {
        let params = BC.ProviderHostedCartParams(url: "https://checkout.ticketevolution.com/x", pollIntervalSeconds: 0, settlement: .handOff)
        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(BC.ProviderHostedCartParams.self, from: data)
        XCTAssertEqual(decoded.settlement, .handOff)
    }

    // MARK: - OpenEnum handed_off

    func testCheckoutStatusHandedOffRoundTripsAndIsTerminal() throws {
        let status = BC.OpenEnum<BC.CheckoutStatus>(.handedOff)
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(BC.OpenEnum<BC.CheckoutStatus>.self, from: data)

        XCTAssertEqual(decoded.value, .handedOff)
        XCTAssertTrue(decoded.value.isTerminal)
    }

    func testActionStatusHandedOffRoundTrips() throws {
        let status = BC.OpenEnum<BC.ActionStatus>(.handedOff)
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(BC.OpenEnum<BC.ActionStatus>.self, from: data)

        XCTAssertEqual(decoded.value, .handedOff)
    }

    func testActionResultDecodesAHandedOffStatus() throws {
        let data = Data(#"{"status":"handed_off"}"#.utf8)
        let result = try JSONDecoder().decode(BC.ActionResult.self, from: data)

        XCTAssertEqual(result.status?.value, .handedOff)
    }
}
