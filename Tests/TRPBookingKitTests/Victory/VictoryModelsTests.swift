import XCTest
@testable import TRPBookingKit

final class VictoryModelsTests: XCTestCase {

    // MARK: - VictoryEvent

    func testEventDecodesTimeToBeAnnouncedAndVenueTimeZone() throws {
        let json = """
        {
          "id": 123,
          "name": "Concert",
          "occurs_at": "2026-05-01T20:00:00+00:00",
          "occurs_at_local": "2026-05-01T20:00:00",
          "tbd": true,
          "state": "active",
          "available_count": 10,
          "venue": {
            "id": 5,
            "name": "Arena",
            "time_zone": "America/New_York",
            "address": {"latitude": 40.7, "longitude": -73.9}
          },
          "configuration": {
            "id": 9,
            "seating_chart": {"medium": "https://example.com/m.png", "large": "https://example.com/l.png"}
          }
        }
        """
        let event = try decodeJSON(VictoryEvent.self, json)

        XCTAssertTrue(event.isTimeToBeAnnounced)
        XCTAssertEqual(event.venue?.timeZone, TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(event.venue?.latitude ?? 0, 40.7, accuracy: 0.0001)
        XCTAssertEqual(event.configurationId, 9)
        XCTAssertEqual(event.seatingChartMedium, URL(string: "https://example.com/m.png"))
    }

    func testEventDefaultsTimeToBeAnnouncedToFalseAndToleratesANullVenueTimeZone() throws {
        let json = """
        {"id": 1, "venue": {"id": 5, "name": "Arena", "time_zone": null}}
        """
        let event = try decodeJSON(VictoryEvent.self, json)

        XCTAssertFalse(event.isTimeToBeAnnounced)
        XCTAssertNotNil(event.venue)
        XCTAssertNil(event.venue?.timeZone)
    }

    func testEventThrowsWithoutAnId() {
        let json = "{\"name\": \"Concert\"}"
        XCTAssertThrowsError(try decodeJSON(VictoryEvent.self, json))
    }

    // MARK: - VictoryTicketGroup.isDigital

    func testIsDigitalTrueWhenETicket() throws {
        let group = try decodeJSON(VictoryTicketGroup.self, #"{"id":1,"quantity":1,"splits":[1],"eticket":true,"format":"Physical"}"#)
        XCTAssertTrue(group.isDigital)
    }

    func testIsDigitalTrueWhenInstantDelivery() throws {
        let group = try decodeJSON(VictoryTicketGroup.self, #"{"id":1,"quantity":1,"splits":[1],"instant_delivery":true}"#)
        XCTAssertTrue(group.isDigital)
    }

    func testIsDigitalFalseWhenFormatIsPhysicalCaseInsensitive() throws {
        let group = try decodeJSON(VictoryTicketGroup.self, #"{"id":1,"quantity":1,"splits":[1],"format":"PHYSICAL"}"#)
        XCTAssertFalse(group.isDigital)
    }

    func testIsDigitalTrueWhenFormatIsNotPhysical() throws {
        let group = try decodeJSON(VictoryTicketGroup.self, #"{"id":1,"quantity":1,"splits":[1],"format":"PDF"}"#)
        XCTAssertTrue(group.isDigital)
    }

    func testIsDigitalFalseWhenFormatIsAbsentAndNeitherETicketNorInstantDelivery() throws {
        let group = try decodeJSON(VictoryTicketGroup.self, #"{"id":1,"quantity":1,"splits":[1]}"#)
        XCTAssertFalse(group.isDigital)
    }

    // MARK: - VictoryTicketGroup.sellableQuantities

    func testSellableQuantitiesFiltersToPositiveSplitsWithinAvailableQuantityAndDedupsSorted() throws {
        let group = try decodeJSON(
            VictoryTicketGroup.self,
            #"{"id":1,"quantity":5,"splits":[1,2,3,10,0,-1,2],"available_quantity":4}"#
        )
        XCTAssertEqual(group.sellableQuantities, [1, 2, 3])
    }

    func testTicketGroupThrowsWithoutAnId() {
        XCTAssertThrowsError(try decodeJSON(VictoryTicketGroup.self, "{\"quantity\":1}"))
    }

    // MARK: - VictoryTaxQuote wrapped vs flat

    func testTaxQuoteDecodesFromAWrappedTaxQuoteObject() throws {
        let json = """
        {"tax_quote": {"id":"abc","signature":"sig","retail_tax_amount": 1.23, "wholesale_tax_amount": 1.0, "expires_at": "2026-01-01T00:00:00Z"}}
        """
        let quote = try decodeJSON(VictoryTaxQuote.self, json)

        XCTAssertEqual(quote.id, "abc")
        XCTAssertEqual(quote.signature, "sig")
        XCTAssertTrue(quote.isUsable)
    }

    func testTaxQuoteDecodesFromAFlatObject() throws {
        let json = """
        {"id":"abc","signature":"sig","retail_tax_amount":1.23,"wholesale_tax_amount":1.0,"expires_at":"2026-01-01T00:00:00Z"}
        """
        let quote = try decodeJSON(VictoryTaxQuote.self, json)

        XCTAssertEqual(quote.id, "abc")
        XCTAssertEqual(quote.signature, "sig")
        XCTAssertTrue(quote.isUsable)
    }

    func testTaxQuoteIsNotUsableWithoutASignature() throws {
        let quote = try decodeJSON(VictoryTaxQuote.self, #"{"retail_tax_amount": 1.0}"#)
        XCTAssertFalse(quote.isUsable)
    }

    func testTaxQuoteExpiryIsRelativeToTheGivenDate() throws {
        let quote = try decodeJSON(VictoryTaxQuote.self, #"{"signature":"sig","retail_tax_amount":1.0,"expires_at":"2026-01-01T00:00:00Z"}"#)
        let before = ISO8601.date(from: "2025-12-31T00:00:00Z")!
        let after = ISO8601.date(from: "2026-06-01T00:00:00Z")!

        XCTAssertFalse(quote.isExpired(at: before))
        XCTAssertTrue(quote.isExpired(at: after))
    }

    // MARK: - VictoryOrderRequest

    func testOrderRequestThrowsWhenClientHasNoEmailOrAddress() throws {
        let client = try decodeJSON(VictoryClient.self, "{\"id\":1}")
        let group = try decodeJSON(VictoryTicketGroup.self, #"{"id":1,"quantity":1,"splits":[1],"retail_price":10,"wholesale_price":5}"#)

        XCTAssertThrowsError(try VictoryOrderRequest(
            client: client, group: group, quantity: 1, paymentToken: "tok", taxQuote: nil, reference: "ref", sessionId: nil
        ))
    }

    func testOrderRequestThrowsWhenTicketGroupHasNoPrice() throws {
        let client = try decodeJSON(VictoryClient.self, #"{"id":1,"email_addresses":[{"id":2}],"addresses":[{"id":3}]}"#)
        let group = try decodeJSON(VictoryTicketGroup.self, #"{"id":1,"quantity":1,"splits":[1]}"#)

        XCTAssertThrowsError(try VictoryOrderRequest(
            client: client, group: group, quantity: 1, paymentToken: "tok", taxQuote: nil, reference: "ref", sessionId: nil
        ))
    }

    func testOrderEncodingOmitsTaxWhenTheTaxQuoteIsNotUsable() throws {
        let client = try decodeJSON(VictoryClient.self, #"{"id":1,"email_addresses":[{"id":2}],"addresses":[{"id":3}]}"#)
        let group = try decodeJSON(VictoryTicketGroup.self, #"{"id":1,"quantity":1,"splits":[1],"retail_price":10,"wholesale_price":5}"#)
        let unusableTax = try decodeJSON(VictoryTaxQuote.self, #"{"retail_tax_amount": 1.0}"#)

        let request = try VictoryOrderRequest(
            client: client, group: group, quantity: 1, paymentToken: "tok", taxQuote: unusableTax, reference: "ref", sessionId: nil
        )
        let object = try encodeToJSONObject(request)
        let order = object["order"] as? [String: Any]

        XCTAssertNil(order?["tax"])
        XCTAssertNil(order?["tax_signature"])
    }

    func testOrderEncodingIncludesTaxAndSignatureTogetherWhenUsable() throws {
        let client = try decodeJSON(VictoryClient.self, #"{"id":1,"email_addresses":[{"id":2}],"addresses":[{"id":3}]}"#)
        let group = try decodeJSON(VictoryTicketGroup.self, #"{"id":1,"quantity":1,"splits":[1],"retail_price":10,"wholesale_price":5}"#)
        let usableTax = try decodeJSON(VictoryTaxQuote.self, #"{"signature":"sig","retail_tax_amount": 1.5}"#)

        let request = try VictoryOrderRequest(
            client: client, group: group, quantity: 1, paymentToken: "tok", taxQuote: usableTax, reference: "ref", sessionId: nil
        )
        let object = try encodeToJSONObject(request)
        let order = object["order"] as? [String: Any]

        XCTAssertEqual(order?["tax"] as? Double, 1.5)
        XCTAssertEqual(order?["tax_signature"] as? String, "sig")
    }

    // MARK: - VictoryOrderState

    func testOrderStateMapsKnownRawValuesToRecordStatus() {
        XCTAssertEqual(VictoryOrderState("pending").recordStatus, .pending)
        XCTAssertEqual(VictoryOrderState("open").recordStatus, .pending)
        XCTAssertEqual(VictoryOrderState("accepted").recordStatus, .confirmed)
        XCTAssertEqual(VictoryOrderState("completed").recordStatus, .confirmed)
        XCTAssertEqual(VictoryOrderState("shipped").recordStatus, .confirmed)
        XCTAssertEqual(VictoryOrderState("delivered").recordStatus, .confirmed)
        XCTAssertEqual(VictoryOrderState("rejected").recordStatus, .failed)
        XCTAssertEqual(VictoryOrderState("cancelled").recordStatus, .cancelled)
        XCTAssertEqual(VictoryOrderState("canceled").recordStatus, .cancelled)
        XCTAssertEqual(VictoryOrderState("voided").recordStatus, .cancelled)
    }

    func testOrderStateOfAnUnknownOrMissingRawValueHasNoRecordStatus() {
        XCTAssertNil(VictoryOrderState("something-else").recordStatus)
        XCTAssertNil(VictoryOrderState(nil).recordStatus)
    }

    // MARK: - VictoryOrder lenient item decoding

    func testOrderSkipsMalformedItemsWithoutFailingTheWholeDecode() throws {
        let json = """
        {
          "id": "ord1",
          "state": "accepted",
          "total": 100.5,
          "items": [
            {"quantity": 2, "price": 50.25, "ticket_group": {"section":"A","row":"1","seats":[101,102]}},
            "not-an-object",
            42
          ]
        }
        """
        let order = try decodeJSON(VictoryOrder.self, json)

        XCTAssertEqual(order.items.count, 1)
        XCTAssertEqual(order.items.first?.quantity, 2)
        XCTAssertEqual(order.items.first?.section, "A")
        XCTAssertEqual(order.items.first?.seats, [101, 102])
    }

    func testOrderThrowsWithoutAnId() {
        XCTAssertThrowsError(try decodeJSON(VictoryOrder.self, "{\"state\":\"accepted\"}"))
    }

    // MARK: - VictoryErrorBody

    func testErrorBodyPrefersMessageOverErrorsArray() throws {
        let body = try decodeJSON(VictoryErrorBody.self, #"{"message":"Bad request","errors":["e1","e2"]}"#)
        XCTAssertEqual(body.message, "Bad request")
    }

    func testErrorBodyFallsBackToErrorsArrayJoinedByNewline() throws {
        let body = try decodeJSON(VictoryErrorBody.self, #"{"errors":["e1","e2"]}"#)
        XCTAssertEqual(body.message, "e1\ne2")
        XCTAssertEqual(body.error, "e1")
    }
}

private func encodeToJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}
