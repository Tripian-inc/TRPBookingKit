import Foundation
import XCTest
@testable import TRPBookingKit

/// Every contract fixture body decodes into the contract types and encodes back to the same JSON.
final class ContractFixturesTests: XCTestCase {

    func testEveryResponseBodyRoundTrips() throws {
        let responses = try ContractFixtures.allFiles().filter { $0.hasSuffix(".response.json") }
        XCTAssertEqual(responses.count, 80)
        for file in responses {
            let requestFile = file.replacingOccurrences(of: ".response.json", with: ".request.json")
            let request = try ContractFixtures.object(requestFile)
            let method = try XCTUnwrap(request["method"] as? String)
            let path = try XCTUnwrap(request["path"] as? String)
            let body = try XCTUnwrap(ContractFixtures.body(file), file)
            let success = (try ContractFixtures.object(file)["body"] as? [String: Any])?["success"] as? Bool
            try assertRoundTrip(body, as: responseType(method: method, path: path, success: success ?? true), file: file)
        }
    }

    func testEveryRequestBodyRoundTrips() throws {
        let requests = try ContractFixtures.allFiles().filter { $0.hasSuffix(".request.json") }
        XCTAssertEqual(requests.count, 80)
        var checked = 0
        for file in requests {
            let request = try ContractFixtures.object(file)
            let path = try XCTUnwrap(request["path"] as? String)
            guard let body = try ContractFixtures.body(file) else {
                XCTAssertEqual(request["method"] as? String, "GET", file)
                continue
            }
            try assertRoundTrip(body, as: try requestType(path: path), file: file)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testUnknownBlocksAndFieldsDecodeAsUnknown() throws {
        let body = try XCTUnwrap(ContractFixtures.body("_synthetic/g-forward-compat/01-unknown-blocks.response.json"))
        let checkout = try XCTUnwrap(JSONDecoder().decode(BC.Envelope<BC.Checkout>.self, from: body).data)
        let blocks = try XCTUnwrap(checkout.currentStep?.blocks)
        let unknownTypes = blocks.compactMap { block -> String? in
            if case let .unknown(type, _) = block { return type }
            return nil
        }
        XCTAssertEqual(unknownTypes, ["carousel", "seat_map"])
        XCTAssertEqual(blocks.first { $0.typeRawValue == "carousel" }?.onUnsupported, .skip)

        let signature = try XCTUnwrap(blocks.first { block in
            if case let .field(.unknown(fieldType, _)) = block { return fieldType == "signature" }
            return false
        })
        guard case let .field(field) = signature else { return XCTFail("signature is not a field") }
        XCTAssertEqual(field.degradesTo?.rawValue, "text")
        XCTAssertEqual(field.label.isEmpty, false)
    }

    func testUnknownNextActionDecodesAsUnknown() throws {
        let body = try XCTUnwrap(ContractFixtures.body("_synthetic/g-forward-compat/02-unknown-action.response.json"))
        let checkout = try XCTUnwrap(JSONDecoder().decode(BC.Envelope<BC.Checkout>.self, from: body).data)
        guard case let .unknown(type, raw) = try XCTUnwrap(checkout.nextAction) else {
            return XCTFail("wallet_pass_payment decoded as a known action")
        }
        XCTAssertEqual(type, "wallet_pass_payment")
        XCTAssertNotNil(raw.objectValue?["params"]?.objectValue?["walletToken"])
    }

    func testUnknownEnumValueSurvivesARoundTrip() throws {
        let decoded = try JSONDecoder().decode(BC.OpenEnum<BC.CheckoutStatus>.self, from: Data(#""on_hold""#.utf8))
        XCTAssertTrue(decoded.isUnknown)
        XCTAssertEqual(decoded.rawValue, "on_hold")
        XCTAssertEqual(String(data: try JSONEncoder().encode(decoded), encoding: .utf8), #""on_hold""#)
    }

    private func responseType(method: String, path: String, success: Bool) -> Decodable.Type {
        guard success else { return BC.Envelope<BC.ErrorData>.self }
        let route = path.split(separator: "?").first.map(String.init) ?? path
        if route.hasPrefix("/tour-api/checkouts") { return BC.Envelope<BC.Checkout>.self }
        if route == "/tour-api/bookings" { return BC.Envelope<[BC.Booking]>.self }
        return BC.Envelope<BC.Booking>.self
    }

    private func requestType(path: String) throws -> Decodable.Type {
        let route = path.split(separator: "?").first.map(String.init) ?? path
        if route == "/tour-api/checkouts" { return BC.CreateCheckoutRequest.self }
        if route.contains("/steps/") { return BC.SubmitStepRequest.self }
        if route.hasSuffix("/back") { return BC.BackRequest.self }
        if route.contains("/actions/") { return BC.ActionResultRequest.self }
        if route.hasPrefix("/tour-api/bookings/") && route.hasSuffix("/cancel") { return BC.CancelBookingRequest.self }
        if route.hasSuffix("/extend") || route.hasSuffix("/cancel") { return BC.LangRequest.self }
        throw XCTSkip("no request type for \(path)")
    }

    private func assertRoundTrip(_ data: Data, as type: Decodable.Type, file: String) throws {
        let reencoded: Data
        do {
            reencoded = try Self.roundTrip(data, as: type)
        } catch {
            return XCTFail("\(file): \(type) does not decode: \(error)")
        }
        let original = try CanonicalJSON(data: data)
        let roundTripped = try CanonicalJSON(data: reencoded)
        if let difference = roundTripped.firstDifference(from: original) {
            XCTFail("\(file): \(type) round trip differs at \(difference)")
        }
    }

    private static func roundTrip(_ data: Data, as type: Decodable.Type) throws -> Data {
        func open<T: Decodable>(_: T.Type) throws -> Data {
            let value = try JSONDecoder().decode(T.self, from: data)
            guard let encodable = value as? Encodable else { throw CocoaError(.coderInvalidValue) }
            return try JSONEncoder().encode(AnyEncodable(encodable))
        }
        return try open(type)
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
