import Foundation
import XCTest
@testable import TRPBookingKit

/// Ticket Evolution behind the contract with the purchase made on TE's own hosted checkout page.
///
/// Unlike `LocalVictoryContractTests` (Braintree drop-in, `group → quantity → summary → buyer → payment`), the
/// hosted-checkout flow only collects a ticket group and a quantity before handing the customer to TE's page.
final class LocalVictoryHostedCheckoutTests: XCTestCase {
    private typealias BC = BookingContract

    private var clock: TestClock!
    private var service: MockVictoryBookingService!
    private var store: InMemoryBookingRecordStore!
    private var hostedCheckout: VictoryHostedCheckout!
    private var victory: VictoryCheckout!
    private var checkout: LocalCheckoutClient!

    private static let checkoutId = "chk_01HOSTED"
    private static let actionId = "act_01HOSTED"
    private static let eventId = 2817364

    private static let eventWithDetailsJSON = """
        {"id": \(eventId), "name": "Hamilton", "occurs_at": "2026-10-15T23:00:00Z", "occurs_at_local": "2026-10-15T19:00:00",
         "venue": {"name": "Richard Rodgers Theatre", "address": {"locality": "New York", "country_code": "US"}},
         "configuration": {"seating_chart": {"medium": "https://cdn.te.com/chart-medium.png",
                                             "large": "https://cdn.te.com/chart-large.png"}},
         "performances": [{"performer": {"id": 1, "name": "Ensemble"}, "primary": false},
                          {"performer": {"id": 2, "name": "Lin-Manuel Miranda"}, "primary": true}],
         "category": {"id": 7, "name": "Broadway"}}
        """

    private static let eventWithNoDetailsJSON = """
        {"id": \(eventId), "name": "Hamilton", "tbd": true}
        """

    override func setUp() async throws {
        clock = TestClock(ISO8601DateFormatter().date(from: "2026-10-02T16:05:00Z")!)
        service = MockVictoryBookingService()
        service.eventResult = .success(try decodeJSON(VictoryEvent.self, Self.eventWithDetailsJSON))
        service.listingsResult = .success(try Self.groups())
        store = InMemoryBookingRecordStore()
        hostedCheckout = VictoryHostedCheckout(baseURL: URL(string: "https://checkout.ticketevolution.com")!)
        let now: @Sendable () -> Date = { [clock] in clock!.now }
        victory = VictoryCheckout(service: service, store: store, backgroundTasks: ImmediateTaskRunner(), now: now,
                                  hostedCheckout: hostedCheckout)
        checkout = makeCheckout(victory: victory, identifiers: .sequence([Self.checkoutId, Self.actionId]), now: now)
    }

    private func makeCheckout(victory: VictoryCheckout?, braintree: BraintreeClientTokenProviding? = nil,
                              victoryPaymentMode: VictoryPaymentMode = .hostedCheckout,
                              identifiers: LocalIdentifiers, now: @escaping @Sendable () -> Date) -> LocalCheckoutClient {
        let product = LocalProduct(
            id: "TEVO-2817364", provider: .victory, providerProductId: String(Self.eventId), title: "Hamilton on Broadway",
            imageUrl: "https://cdn.tripian.com/p/TEVO-2817364.jpg", timeZone: TimeZone(identifier: "America/New_York")!,
            durationMinutes: 165,
            meetingPoint: .init(name: "Richard Rodgers Theatre", address: "226 W 46th St, New York, NY 10036",
                                lat: 40.759, lng: -73.9866))
        return LocalCheckoutClient(viator: nil, victory: victory, braintree: braintree, victoryPaymentMode: victoryPaymentMode,
                                   store: store, catalog: StaticProductCatalog([product]),
                                   fallbackWebBase: "https://book.tripian.com/c/", identifiers: identifiers, now: now)
    }

    /// Cheapest-to-pricier once sorted: the in-hand group (60), the floor group (90), the e-ticket group (150);
    /// the sold-out group is filtered out before it ever reaches a block.
    private static func groups() throws -> [VictoryTicketGroup] {
        try [
            decodeJSON(VictoryTicketGroup.self, """
                {"id": 9001, "section": "101", "row": "A", "quantity": 10, "available_quantity": 10, "splits": [2, 4],
                 "retail_price": 150.00, "service_fee": 12.00, "eticket": true}
                """),
            decodeJSON(VictoryTicketGroup.self, """
                {"id": 9002, "section": "102", "quantity": 0, "available_quantity": 0, "splits": []}
                """),
            decodeJSON(VictoryTicketGroup.self, """
                {"id": 9003, "quantity": 5, "available_quantity": 5, "splits": [], "retail_price": 60.00,
                 "in_hand": true, "in_hand_on": "2026-10-10", "public_notes": "Obstructed view"}
                """),
            decodeJSON(VictoryTicketGroup.self, """
                {"id": 9004, "section": "Floor", "row": "1", "quantity": 20, "available_quantity": 20, "splits": [2],
                 "retail_price": 90.00, "in_hand": false, "in_hand_on": "2026-10-05"}
                """)
        ]
    }

    private func create() async throws -> BC.CheckoutResponse {
        try await checkout.create(BC.CreateCheckoutRequest(
            productId: "TEVO-2817364", currency: "USD", bookingUuid: "3f6c1a9e-8d2b-4b7a-a1c4-5e9f0d2b7c11", lang: "en"))
    }

    private func submitTickets(_ optionId: String) async throws -> BC.CheckoutResponse {
        try await checkout.submit(checkoutId: Self.checkoutId, stepId: "tickets", answers: ["tickets": .string(optionId)], lang: "en")
    }

    private func submitQuantity(_ quantity: Int) async throws -> BC.CheckoutResponse {
        try await checkout.submit(checkoutId: Self.checkoutId, stepId: "quantity",
                                  answers: ["units": .object(["TICKET": .number(Double(quantity))])], lang: "en")
    }

    private func replayToAwaitingPayment(optionId: String = "TG_9004", quantity: Int = 2) async throws -> BC.CheckoutResponse {
        _ = try await create()
        _ = try await submitTickets(optionId)
        return try await submitQuantity(quantity)
    }

    private func choiceOptions(_ response: BC.CheckoutResponse) throws -> [BC.ChoiceBlock.Option] {
        guard case .choice(let block) = response.checkout.currentStep?.blocks.first(where: { $0.id == "tickets" }) else {
            XCTFail("Expected a tickets choice block")
            throw BookingError.transport("no tickets choice block")
        }
        return block.options
    }

    private func hostedCartParams(_ response: BC.CheckoutResponse) throws -> BC.ProviderHostedCartParams {
        guard case .providerHostedCart(let payload) = response.checkout.nextAction else {
            XCTFail("Expected a provider hosted cart action")
            throw BookingError.transport("no provider_hosted_cart action")
        }
        return payload.params
    }

    // MARK: - Tickets step blocks

    func testTicketsStepPrefersTheLargeSeatingChartImageOverTheMedium() async throws {
        let response = try await create()
        guard case .image(let block) = response.checkout.currentStep?.blocks.first(where: { $0.id == "seating-chart" }) else {
            return XCTFail("Expected a seating chart image block")
        }
        XCTAssertEqual(block.url, "https://cdn.te.com/chart-large.png")
    }

    func testTicketsStepShowsEventDetailsWithPrimaryPerformersFirst() async throws {
        let response = try await create()
        guard case .section(let section) = response.checkout.currentStep?.blocks.first(where: { $0.id == "event" }) else {
            return XCTFail("Expected an event section block")
        }
        let performers = section.blocks.first { $0.id == "event-performers" }
        guard case .notice(let notice) = performers else { return XCTFail("Expected an event-performers notice") }
        XCTAssertEqual(notice.text, "Lin-Manuel Miranda, Ensemble")
        XCTAssertEqual(section.blocks.first { $0.id == "event-venue" }.map { _ in true }, true)
        XCTAssertEqual(section.blocks.first { $0.id == "event-address" }.map { _ in true }, true)
    }

    func testTicketsStepShowsTimeToBeAnnouncedAndOmitsAbsentRows() async throws {
        service.eventResult = .success(try decodeJSON(VictoryEvent.self, Self.eventWithNoDetailsJSON))
        let response = try await create()
        guard case .section(let section) = response.checkout.currentStep?.blocks.first(where: { $0.id == "event" }) else {
            return XCTFail("Expected an event section block")
        }
        XCTAssertNil(section.blocks.first { $0.id == "event-venue" })
        XCTAssertNil(section.blocks.first { $0.id == "event-address" })
        XCTAssertNil(section.blocks.first { $0.id == "event-performers" })
        guard case .notice(let date) = section.blocks.first(where: { $0.id == "event-date" }) else {
            return XCTFail("Expected an event-date notice")
        }
        XCTAssertEqual(date.text, "Time to be announced")
    }

    func testChoiceOptionsOmitTheSoldOutGroup() async throws {
        let response = try await create()
        let options = try choiceOptions(response)
        XCTAssertFalse(options.contains { $0.value == "TG_9002" })
        XCTAssertEqual(options.count, 3)
    }

    func testChoiceOptionsAreSortedByPriceAscending() async throws {
        let response = try await create()
        let options = try choiceOptions(response)
        XCTAssertEqual(options.map(\.value), ["TG_9003", "TG_9004", "TG_9001"])
    }

    func testChoiceOptionWithNoSplitThatFitsIsDisabled() async throws {
        let response = try await create()
        let options = try choiceOptions(response)
        let disabled = try XCTUnwrap(options.first { $0.value == "TG_9003" })
        XCTAssertEqual(disabled.disabled, true)
        let enabled = try XCTUnwrap(options.first { $0.value == "TG_9004" })
        XCTAssertNil(enabled.disabled)
    }

    func testChoiceOptionTitleFallsBackToTicketsWhenSectionAndRowAreAbsent() async throws {
        let response = try await create()
        let options = try choiceOptions(response)
        XCTAssertEqual(options.first { $0.value == "TG_9003" }?.title, "Tickets")
        XCTAssertEqual(options.first { $0.value == "TG_9001" }?.title, "Section 101 · Row A")
    }

    func testChoiceOptionSubtitleCombinesNotesAndServiceFee() async throws {
        let response = try await create()
        let options = try choiceOptions(response)
        XCTAssertEqual(options.first { $0.value == "TG_9003" }?.subtitle, "Obstructed view")
        let withFee = try XCTUnwrap(options.first { $0.value == "TG_9001" })
        XCTAssertEqual(withFee.subtitle, "+ fee \(LocalFormat.amount(12.00)) USD")
    }

    func testChoiceOptionBadgesPreferEticketThenInHandDate() async throws {
        let response = try await create()
        let options = try choiceOptions(response)
        XCTAssertEqual(options.first { $0.value == "TG_9001" }?.badge, "E-ticket")
        let inHandDate = try XCTUnwrap(BookingDate("2026-10-05"))
        XCTAssertEqual(options.first { $0.value == "TG_9004" }?.badge, "In hand on \(LocalFormat.longDate(inHandDate))")
        XCTAssertNil(options.first { $0.value == "TG_9003" }?.badge)
    }

    // MARK: - Happy path

    func testHappyPathOffersTheHostedCheckoutUrlAndMakesNoProviderBookingCalls() async throws {
        let response = try await replayToAwaitingPayment(optionId: "TG_9004", quantity: 2)
        let params = try hostedCartParams(response)

        XCTAssertEqual(params.url, hostedCheckout.url(eventId: Self.eventId, ticketGroupId: 9004, quantity: 2).absoluteString)
        XCTAssertEqual(params.pollIntervalSeconds, 0)
        XCTAssertEqual(params.settlement, .handOff)
        XCTAssertEqual(response.checkout.status.value, .awaitingPayment)
        XCTAssertEqual(service.eventCallCount, 1)
        XCTAssertEqual(service.listingsCallCount, 1)
        XCTAssertEqual(service.taxQuoteCallCount, 0)
        XCTAssertEqual(service.createClientCallCount, 0)
        XCTAssertEqual(service.placeOrderCallCount, 0)
    }

    // MARK: - Validation

    func testSubmittingAQuantityThatIsNotSellableIsRejectedWithValidation() async throws {
        _ = try await create()
        _ = try await submitTickets("TG_9004")
        do {
            _ = try await submitQuantity(3)
            XCTFail("Expected VALIDATION")
        } catch let error as BC.ContractError {
            XCTAssertEqual(error.data.code.value, .validation)
        }
    }

    func testSubmittingADisabledGroupIsRejectedWithValidation() async throws {
        _ = try await create()
        do {
            _ = try await submitTickets("TG_9003")
            XCTFail("Expected VALIDATION")
        } catch let error as BC.ContractError {
            XCTAssertEqual(error.data.code.value, .validation)
        }
    }

    // MARK: - Back

    func testBackFromQuantityReturnsToTickets() async throws {
        _ = try await create()
        _ = try await submitTickets("TG_9004")
        let back = try await checkout.back(checkoutId: Self.checkoutId, fromStepId: "quantity", lang: "en")
        XCTAssertEqual(back.checkout.currentStep?.id, "tickets")
        XCTAssertEqual(back.checkout.status.value, .collectingDetails)
    }

    func testBackFromAwaitingPaymentReturnsToQuantity() async throws {
        _ = try await replayToAwaitingPayment(optionId: "TG_9004", quantity: 2)
        let back = try await checkout.back(checkoutId: Self.checkoutId, fromStepId: "quantity", lang: "en")
        XCTAssertEqual(back.checkout.currentStep?.id, "quantity")
        XCTAssertNil(back.checkout.nextAction)
    }

    // MARK: - Cancel and actions

    func testCancelEndsTheCheckoutCancelledWithoutEverCreatingABookingRecord() async throws {
        _ = try await replayToAwaitingPayment(optionId: "TG_9004", quantity: 2)
        let response = try await checkout.cancel(checkoutId: Self.checkoutId, lang: "en")
        XCTAssertEqual(response.checkout.status.value, .cancelled)
        let records = await store.all()
        XCTAssertTrue(records.isEmpty)
    }

    func testHandedOffActionEndsTheCheckoutHandedOffWithoutABookingReference() async throws {
        let awaiting = try await replayToAwaitingPayment(optionId: "TG_9004", quantity: 2)
        let actionId = try XCTUnwrap(awaiting.checkout.nextAction?.id)
        let response = try await checkout.action(checkoutId: Self.checkoutId, actionId: actionId,
                                                 result: BC.ActionResult(status: .init(.handedOff)), lang: "en")
        XCTAssertEqual(response.checkout.status.value, .handedOff)
        XCTAssertTrue(response.checkout.status.value.isTerminal)
        XCTAssertNil(response.checkout.result?.bookingUuid)
        let records = await store.all()
        XCTAssertTrue(records.isEmpty)
    }

    func testCanceledActionEndsTheCheckoutCancelled() async throws {
        let awaiting = try await replayToAwaitingPayment(optionId: "TG_9004", quantity: 2)
        let actionId = try XCTUnwrap(awaiting.checkout.nextAction?.id)
        let response = try await checkout.action(checkoutId: Self.checkoutId, actionId: actionId,
                                                 result: BC.ActionResult(status: .init(.canceled)), lang: "en")
        XCTAssertEqual(response.checkout.status.value, .cancelled)
        XCTAssertNil(response.checkout.currentStep)
        XCTAssertNil(response.checkout.nextAction)
        XCTAssertTrue(response.checkout.allowedActions.isEmpty)
        let records = await store.all()
        XCTAssertTrue(records.isEmpty)
    }

    func testSucceededActionIsRejectedAndLeavesTheCheckoutAwaitingPayment() async throws {
        let awaiting = try await replayToAwaitingPayment(optionId: "TG_9004", quantity: 2)
        let actionId = try XCTUnwrap(awaiting.checkout.nextAction?.id)
        do {
            _ = try await checkout.action(checkoutId: Self.checkoutId, actionId: actionId,
                                          result: BC.ActionResult(status: .init(.succeeded)), lang: "en")
            XCTFail("Expected STEP_MISMATCH")
        } catch let error as BC.ContractError {
            XCTAssertEqual(error.httpStatus, 409)
            XCTAssertEqual(error.data.code.value, .stepMismatch)
            XCTAssertEqual(error.data.checkout?.status.value, .awaitingPayment)
            XCTAssertEqual(error.data.checkout?.nextAction?.id, actionId)
        }
    }

    func testUnknownStatusActionIsRejectedAndLeavesTheCheckoutAwaitingPayment() async throws {
        let awaiting = try await replayToAwaitingPayment(optionId: "TG_9004", quantity: 2)
        let actionId = try XCTUnwrap(awaiting.checkout.nextAction?.id)
        do {
            _ = try await checkout.action(checkoutId: Self.checkoutId, actionId: actionId,
                                          result: BC.ActionResult(status: nil), lang: "en")
            XCTFail("Expected STEP_MISMATCH")
        } catch let error as BC.ContractError {
            XCTAssertEqual(error.httpStatus, 409)
            XCTAssertEqual(error.data.code.value, .stepMismatch)
            XCTAssertEqual(error.data.checkout?.status.value, .awaitingPayment)
            XCTAssertEqual(error.data.checkout?.nextAction?.id, actionId)
        }
    }

    func testHandedOffResultMessageTellsTheCustomerToCheckTicketEvolution() async throws {
        let awaiting = try await replayToAwaitingPayment(optionId: "TG_9004", quantity: 2)
        let actionId = try XCTUnwrap(awaiting.checkout.nextAction?.id)
        let response = try await checkout.action(checkoutId: Self.checkoutId, actionId: actionId,
                                                 result: BC.ActionResult(status: .init(.handedOff)), lang: "en")
        XCTAssertEqual(response.checkout.result?.title, "Continued on Ticket Evolution")
        XCTAssertEqual(response.checkout.result?.message,
                       "If you completed the purchase on Ticket Evolution's page, it is confirmed there.")
    }

    // MARK: - Changing the ticket group

    func testChangingTheTicketGroupAfterQuantityForgetsTheStoredQuantityDefault() async throws {
        _ = try await create()
        _ = try await submitTickets("TG_9004")
        _ = try await submitQuantity(2)
        _ = try await checkout.back(checkoutId: Self.checkoutId, fromStepId: "quantity", lang: "en")
        _ = try await checkout.back(checkoutId: Self.checkoutId, fromStepId: "quantity", lang: "en")
        let response = try await submitTickets("TG_9001")

        guard case .quantity(let block) = response.checkout.currentStep?.blocks.first(where: { $0.id == "units" }) else {
            return XCTFail("Expected a quantity block")
        }
        XCTAssertNil(block.defaultValue)
    }

    func testResubmittingTheSameTicketGroupKeepsTheStoredQuantityDefault() async throws {
        _ = try await create()
        _ = try await submitTickets("TG_9004")
        _ = try await submitQuantity(2)
        _ = try await checkout.back(checkoutId: Self.checkoutId, fromStepId: "quantity", lang: "en")
        _ = try await checkout.back(checkoutId: Self.checkoutId, fromStepId: "quantity", lang: "en")
        let response = try await submitTickets("TG_9004")

        guard case .quantity(let block) = response.checkout.currentStep?.blocks.first(where: { $0.id == "units" }) else {
            return XCTFail("Expected a quantity block")
        }
        XCTAssertEqual(block.defaultValue?["TICKET"], 2)
    }

    func testSettlementDefaultsToPending() async throws {
        let awaiting = try await replayToAwaitingPayment(optionId: "TG_9004", quantity: 2)
        let actionId = try XCTUnwrap(awaiting.checkout.nextAction?.id)
        let settlement = try await checkout.settlement(checkoutId: Self.checkoutId, actionId: actionId)
        XCTAssertEqual(settlement, .pending)
    }

    // MARK: - Payment mode wiring

    func testBraintreeDropinModeStartsAtTheGroupStepInsteadOfTickets() async throws {
        let braintree = MockBraintreeClientToken()
        let now: @Sendable () -> Date = { [clock] in clock!.now }
        let braintreeCheckout = makeCheckout(victory: victory, braintree: braintree, victoryPaymentMode: .braintreeDropin,
                                             identifiers: .sequence(["chk_01BRAINTREE"]), now: now)
        let response = try await braintreeCheckout.create(BC.CreateCheckoutRequest(
            productId: "TEVO-2817364", currency: "USD", bookingUuid: "3f6c1a9e-8d2b-4b7a-a1c4-5e9f0d2b7c11", lang: "en"))
        XCTAssertEqual(response.checkout.currentStep?.id, "group")
    }

    func testHostedCheckoutModeWithoutAHostedCheckoutIsSupplierUnavailable() async throws {
        let now: @Sendable () -> Date = { [clock] in clock!.now }
        let victoryWithoutHostedCheckout = VictoryCheckout(service: service, store: store, backgroundTasks: ImmediateTaskRunner(), now: now)
        let noHostedCheckout = makeCheckout(victory: victoryWithoutHostedCheckout, identifiers: .sequence(["chk_01NOHOST"]), now: now)
        do {
            _ = try await noHostedCheckout.create(BC.CreateCheckoutRequest(
                productId: "TEVO-2817364", currency: "USD", bookingUuid: "3f6c1a9e-8d2b-4b7a-a1c4-5e9f0d2b7c11", lang: "en"))
            XCTFail("Expected SUPPLIER_UNAVAILABLE")
        } catch let error as BC.ContractError {
            XCTAssertEqual(error.data.code, .init(.supplierUnavailable))
        }
        XCTAssertEqual(service.eventCallCount, 0)
        XCTAssertEqual(service.listingsCallCount, 0)
    }

    func testBraintreeDropinModeWithoutABraintreeTokenProviderIsSupplierUnavailable() async throws {
        let now: @Sendable () -> Date = { [clock] in clock!.now }
        let noBraintree = makeCheckout(victory: victory, braintree: nil, victoryPaymentMode: .braintreeDropin,
                                       identifiers: .sequence(["chk_01NOBT"]), now: now)
        do {
            _ = try await noBraintree.create(BC.CreateCheckoutRequest(
                productId: "TEVO-2817364", currency: "USD", bookingUuid: "3f6c1a9e-8d2b-4b7a-a1c4-5e9f0d2b7c11", lang: "en"))
            XCTFail("Expected SUPPLIER_UNAVAILABLE")
        } catch let error as BC.ContractError {
            XCTAssertEqual(error.data.code, .init(.supplierUnavailable))
        }
    }
}
