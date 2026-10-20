import Foundation
import XCTest
@testable import TRPBookingKit

/// A Toristy checkout paid on Toristy's own hosted cart page instead of through Stripe.
///
/// Builds the same steps as `LocalToristyContractTests` but wires `LocalCheckoutClient` with
/// `toristyPaymentMode: .hostedCart` and no `StripePaymentIntentProviding`, so the summary step offers a
/// `provider_hosted_cart` action and the client learns whether it was paid from `settlement(of:)`.
final class LocalToristyHostedCartCheckoutTests: XCTestCase {
    private var clock: TestClock!
    private var service: MockToristyBookingService!
    private var store: InMemoryBookingRecordStore!
    private var toristy: ToristyCheckout!
    private var checkout: LocalCheckoutClient!

    private static let checkoutId = "chk_01J9ZT7P2N"
    private static let actionId = "act_01J9ZTB4"
    private static let expiresAt = ISO8601DateFormatter().date(from: "2026-10-02T09:42:00Z")!
    private static let detailsAnswers: BookingContract.Answers = [
        "lead.firstName": "Elif", "lead.lastName": "Demir", "lead.email": "elif@example.com", "lead.phone": "+905551112233",
        "t1.fullName": "Elif Demir", "t2.fullName": "Can Demir", "t3.fullName": "Deniz Demir", "t3.birthDate": "2017-05-09"
    ]

    override func setUp() async throws {
        clock = TestClock(ISO8601DateFormatter().date(from: "2026-10-02T09:12:00Z")!)
        service = MockToristyBookingService()
        service.bookingInformationResult = .success(LocalToristyContractTests.information)
        service.availabilityResult = .success(LocalToristyContractTests.availability)
        service.validateResult = .success(ToristyValidation(cartId: "cart-48213", confirmationCode: "TRS-20261015-48213",
                                                             totalPrice: Decimal(string: "62.50")!, currency: "EUR"))
        service.bookingDataResult = .success(ToristyBookingData(
            cartId: "cart-48213", confirmationCode: "TRS-20261015-48213", currency: "EUR", totalPrice: Decimal(string: "62.50")!,
            createdAt: clock.now, expiresAt: Self.expiresAt, status: .reserved, activityDate: "2026-10-15"))
        store = InMemoryBookingRecordStore()
        let now: @Sendable () -> Date = { [clock] in clock!.now }
        let hostedCart = ToristyHostedCart(apiKey: "test-key", pageURL: URL(string: "https://embed.toristy.com/cart")!,
                                           hostOrigin: "https://embed.toristy.com")
        toristy = ToristyCheckout(service: service, hostedCart: hostedCart, payment: nil, store: store,
                                  backgroundTasks: ImmediateTaskRunner(), confirmationAttempts: 1, retryDelay: 0, now: now)
        let product = LocalProduct(
            id: "TOR-PMI-CATHEDRAL", provider: .toristy, providerProductId: "48213", title: "Palma Cathedral and Old Town walking tour",
            imageUrl: "https://cdn.tripian.com/p/TOR-PMI-CATHEDRAL.jpg", timeZone: TimeZone(identifier: "Europe/Madrid")!,
            durationMinutes: 120,
            meetingPoint: .init(name: "Plaça de la Seu, cathedral main door", address: "Plaça de la Seu s/n, 07001 Palma",
                                lat: 39.5676, lng: 2.6484))
        checkout = LocalCheckoutClient(viator: nil, toristy: toristy, stripe: nil, toristyPaymentMode: .hostedCart, store: store,
                                       catalog: StaticProductCatalog([product]), fallbackWebBase: "https://book.tripian.com/c/",
                                       identifiers: .sequence([Self.checkoutId, Self.actionId]), now: now)
    }

    private func replayToSummary(lang: String = "en") async throws -> BookingContract.CheckoutResponse {
        _ = try await checkout.create(BookingContract.CreateCheckoutRequest(
            productId: "TOR-PMI-CATHEDRAL", currency: "EUR", bookingUuid: "3f6c1a9e-8d2b-4b7a-a1c4-5e9f0d2b7c11", lang: lang),
            idempotencyKey: BookingContract.IdempotencyKey())
        _ = try await checkout.submit(checkoutId: Self.checkoutId, stepId: "date", answers: ["date": "2026-10-15"],
                                      expectedAmount: nil, lang: lang, idempotencyKey: BookingContract.IdempotencyKey())
        _ = try await checkout.submit(checkoutId: Self.checkoutId, stepId: "time", answers: ["time": "10:00"],
                                      expectedAmount: nil, lang: lang, idempotencyKey: BookingContract.IdempotencyKey())
        _ = try await checkout.submit(checkoutId: Self.checkoutId, stepId: "rate", answers: ["rate": "RATE_STD"],
                                      expectedAmount: nil, lang: lang, idempotencyKey: BookingContract.IdempotencyKey())
        _ = try await checkout.submit(checkoutId: Self.checkoutId, stepId: "travelers",
                                      answers: ["units": .object(["ADULT": .number(2), "CHILD": .number(1)])],
                                      expectedAmount: nil, lang: lang, idempotencyKey: BookingContract.IdempotencyKey())
        _ = try await checkout.submit(checkoutId: Self.checkoutId, stepId: "details", answers: Self.detailsAnswers,
                                      expectedAmount: nil, lang: lang, idempotencyKey: BookingContract.IdempotencyKey())
        return try await checkout.submit(checkoutId: Self.checkoutId, stepId: "summary", answers: [:],
                                         expectedAmount: nil, lang: lang, idempotencyKey: BookingContract.IdempotencyKey())
    }

    private func hostedCartParams(_ response: BookingContract.CheckoutResponse) throws -> BookingContract.ProviderHostedCartParams {
        guard case .providerHostedCart(let payload) = response.checkout.nextAction else {
            XCTFail("Expected a provider hosted cart action")
            throw BookingError.transport("no provider_hosted_cart action")
        }
        return payload.params
    }

    func testHostedCartUrlCarriesCartIdApiKeyEncodedHostCurrencyAndMappedLanguage() async throws {
        let response = try await replayToSummary(lang: "de-DE")
        let params = try hostedCartParams(response)
        let components = URLComponents(url: URL(string: params.url)!, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["apikey"], "test-key")
        XCTAssertEqual(query["cartid"], "cart-48213")
        XCTAssertEqual(query["host"], "https://embed.toristy.com")
        XCTAssertEqual(query["lang"], "de")
        XCTAssertEqual(query["currency"], "EUR")
    }

    func testHostedCartActionCarriesPollIntervalAndTheHoldsExpiry() async throws {
        let response = try await replayToSummary()
        guard case .providerHostedCart(let payload) = response.checkout.nextAction else {
            return XCTFail("Expected a provider hosted cart action")
        }
        XCTAssertEqual(payload.params.pollIntervalSeconds, 3)
        XCTAssertEqual(payload.expiresAt, LocalFormat.iso(Self.expiresAt))
    }

    func testHostedCartLanguageFallsBackToEnglishForAnUnservedLanguage() async throws {
        let response = try await replayToSummary(lang: "tr-TR")
        let params = try hostedCartParams(response)
        let components = URLComponents(url: URL(string: params.url)!, resolvingAgainstBaseURL: false)!
        let lang = (components.queryItems ?? []).first { $0.name == "lang" }?.value
        XCTAssertEqual(lang, "en")
    }

    func testSettlementMapsReservedCancelledTimedOutAndConfirmedBookingdataStatus() async throws {
        _ = try await replayToSummary()

        service.bookingDataResult = .success(makeBookingData(status: .reserved))
        var settlement = try await checkout.settlement(checkoutId: Self.checkoutId, actionId: Self.actionId)
        XCTAssertEqual(settlement, .pending)

        service.bookingDataResult = .success(makeBookingData(status: .cancelled))
        settlement = try await checkout.settlement(checkoutId: Self.checkoutId, actionId: Self.actionId)
        XCTAssertEqual(settlement, .failed(reason: ToristyHostedCartCheckoutFlow.cancelledReason))

        service.bookingDataResult = .success(makeBookingData(status: .timedOut))
        settlement = try await checkout.settlement(checkoutId: Self.checkoutId, actionId: Self.actionId)
        XCTAssertEqual(settlement, .failed(reason: ToristyHostedCartCheckoutFlow.timedOutReason))

        service.bookingDataResult = .success(makeBookingData(status: .confirmed))
        settlement = try await checkout.settlement(checkoutId: Self.checkoutId, actionId: Self.actionId)
        XCTAssertEqual(settlement, .succeeded)
    }

    func testSettlementWithAMismatchedActionIdIsRejected() async throws {
        _ = try await replayToSummary()
        do {
            _ = try await checkout.settlement(checkoutId: Self.checkoutId, actionId: "act_other")
            XCTFail("Expected STEP_MISMATCH")
        } catch let error as BookingContract.ContractError {
            XCTAssertEqual(error.data.code.value, .stepMismatch)
        }
    }

    func testSettlementAfterConfirmedAlwaysSucceedsWithoutAskingToristyAgain() async throws {
        _ = try await replayToSummary()
        service.bookingDataResult = .success(makeBookingData(status: .confirmed))
        _ = try await checkout.action(checkoutId: Self.checkoutId, actionId: Self.actionId,
                                      result: BookingContract.ActionResult(status: .init(.succeeded)), lang: "en",
                                      idempotencyKey: BookingContract.IdempotencyKey())
        let callsBefore = service.bookingDataCallCount
        let settlement = try await checkout.settlement(checkoutId: Self.checkoutId, actionId: Self.actionId)
        XCTAssertEqual(settlement, .succeeded)
        XCTAssertEqual(service.bookingDataCallCount, callsBefore)
    }

    func testSucceededActionWhileStillReservedLeavesTheCheckoutAwaitingPayment() async throws {
        _ = try await replayToSummary()
        service.bookingDataResult = .success(makeBookingData(status: .reserved))
        let response = try await checkout.action(checkoutId: Self.checkoutId, actionId: Self.actionId,
                                                  result: BookingContract.ActionResult(status: .init(.succeeded)), lang: "en",
                                                  idempotencyKey: BookingContract.IdempotencyKey())
        XCTAssertEqual(response.checkout.status.value, .awaitingPayment)
        XCTAssertNotNil(response.checkout.nextAction)
        let status = await recordStatus("cart-48213")
        XCTAssertEqual(status, .held)
    }

    func testSucceededActionWhenConfirmedFinishesWithTheConfirmationCodeAsTheProviderReference() async throws {
        _ = try await replayToSummary()
        service.bookingDataResult = .success(makeBookingData(status: .confirmed, confirmationCode: "TRS-FINAL-99"))
        let response = try await checkout.action(checkoutId: Self.checkoutId, actionId: Self.actionId,
                                                  result: BookingContract.ActionResult(status: .init(.succeeded)), lang: "en",
                                                  idempotencyKey: BookingContract.IdempotencyKey())
        XCTAssertEqual(response.checkout.status.value, .confirmed)
        let records = await store.all()
        XCTAssertEqual(records.first?.contractBooking?.providerReference, "TRS-FINAL-99")
    }

    func testCanceledActionReleasesTheHoldExactlyOnceAndReturnsToSummary() async throws {
        _ = try await replayToSummary()
        service.cancelResult = .success(ToristyCancellation(message: "never confirmed", confirmationCode: "TRS-20261015-48213"))
        let response = try await checkout.action(checkoutId: Self.checkoutId, actionId: Self.actionId,
                                                  result: BookingContract.ActionResult(status: .init(.canceled)), lang: "en",
                                                  idempotencyKey: BookingContract.IdempotencyKey())
        XCTAssertEqual(response.checkout.status.value, .collectingDetails)
        XCTAssertEqual(response.checkout.currentStep?.id, "summary")
        XCTAssertEqual(service.cancelCallCount, 1)
        let status = await recordStatus("cart-48213")
        XCTAssertEqual(status, .cancelled)
    }

    /// Toristy can confirm a cart between the client's "cancel" request leaving and this flow actually cancelling
    /// it; the flow re-checks Toristy before releasing, so a cart that confirmed in that window is kept, not cancelled.
    func testCancelAfterConfirmedIsIgnoredAndKeepsTheBooking() async throws {
        _ = try await replayToSummary()
        service.bookingDataResult = .success(makeBookingData(status: .confirmed))
        let response = try await checkout.cancel(checkoutId: Self.checkoutId, lang: "en", idempotencyKey: BookingContract.IdempotencyKey())
        XCTAssertEqual(response.checkout.status.value, .confirmed)
        XCTAssertEqual(service.cancelCallCount, 0)
        let records = await store.all()
        XCTAssertNotNil(records.first?.contractBooking)
    }

    func testChangingTheSelectionReleasesThePreviousCartOnTheHostedCartFlowToo() async throws {
        _ = try await replayToSummary()
        service.cancelResult = .success(ToristyCancellation(message: "never confirmed", confirmationCode: "TRS-20261015-48213"))
        service.validateResult = .success(ToristyValidation(cartId: "cart-48214", confirmationCode: "TRS-20261015-48214",
                                                             totalPrice: Decimal(string: "62.50")!, currency: "EUR"))
        _ = try await checkout.back(checkoutId: Self.checkoutId, fromStepId: "summary", lang: "en", idempotencyKey: BookingContract.IdempotencyKey())
        _ = try await checkout.back(checkoutId: Self.checkoutId, fromStepId: "summary", lang: "en", idempotencyKey: BookingContract.IdempotencyKey())
        var answers = Self.detailsAnswers
        answers["lead.firstName"] = "Ayşe"
        _ = try await checkout.submit(checkoutId: Self.checkoutId, stepId: "details", answers: answers, expectedAmount: nil,
                                      lang: "en", idempotencyKey: BookingContract.IdempotencyKey())
        XCTAssertEqual(service.cancelledReferences.map(\.primary), ["cart-48213"])
        XCTAssertEqual(service.cancelledNotifyValues, [false])
        let replaced = await recordStatus("cart-48213")
        XCTAssertEqual(replaced, .cancelled)
        let current = await recordStatus("cart-48214")
        XCTAssertEqual(current, .held)
    }

    func testARecheckOfAReleasedCartToristyConfirmedFinishesTheBooking() async throws {
        try await releaseTheCartFromThePaymentPage()
        service.bookingDataResult = .success(makeBookingData(status: .confirmed, confirmationCode: "TRS-LATE-77"))

        _ = await toristy.resolveUnfinished()

        let record = await store.all().first { $0.reference.primary == "cart-48213" }
        XCTAssertEqual(record?.status, .confirmed)
        XCTAssertEqual(record?.contractBooking?.providerReference, "TRS-LATE-77")
        XCTAssertNil(record?.pendingContractBooking)
    }

    func testAReleasedCartToristyStillReportsCancelledStaysClearedAndIsNotAskedAboutAfterTheWindow() async throws {
        try await releaseTheCartFromThePaymentPage()
        service.bookingDataResult = .success(makeBookingData(status: .cancelled))
        let callsBeforeRecheck = service.bookingDataCallCount

        _ = await toristy.resolveUnfinished()
        XCTAssertEqual(service.bookingDataCallCount, callsBeforeRecheck + 1)
        let afterRecheck = await store.all().first { $0.reference.primary == "cart-48213" }
        XCTAssertEqual(afterRecheck?.status, .cancelled)
        XCTAssertNil(afterRecheck?.contractBooking)

        let deadline = try XCTUnwrap(afterRecheck?.deadline)
        clock.now = deadline.expiresAt.addingTimeInterval(ToristyCheckout.releasedCartRecheckWindow + 1)
        service.bookingDataResult = .success(makeBookingData(status: .confirmed))
        let callsBefore = service.bookingDataCallCount
        _ = await toristy.resolveUnfinished()

        XCTAssertEqual(service.bookingDataCallCount, callsBefore)
        let afterWindow = await recordStatus("cart-48213")
        XCTAssertEqual(afterWindow, .cancelled)
    }

    func testStripeModeWithoutStripeOffersNoToristyCheckout() async throws {
        let product = LocalProduct(
            id: "TOR-PMI-CATHEDRAL", provider: .toristy, providerProductId: "48213", title: "Palma Cathedral and Old Town walking tour",
            imageUrl: nil, timeZone: TimeZone(identifier: "Europe/Madrid")!, durationMinutes: 120, meetingPoint: nil)
        let stripeMode = LocalCheckoutClient(viator: nil, toristy: toristy, stripe: nil, toristyPaymentMode: .stripe, store: store,
                                             catalog: StaticProductCatalog([product]), identifiers: .sequence([Self.checkoutId]))
        do {
            _ = try await stripeMode.create(BookingContract.CreateCheckoutRequest(
                productId: "TOR-PMI-CATHEDRAL", currency: "EUR", bookingUuid: "3f6c1a9e-8d2b-4b7a-a1c4-5e9f0d2b7c11", lang: "en"),
                idempotencyKey: BookingContract.IdempotencyKey())
            XCTFail("Expected SUPPLIER_UNAVAILABLE")
        } catch let error as BookingContract.ContractError {
            XCTAssertEqual(error.data.code, .init(.supplierUnavailable))
        }
        XCTAssertEqual(service.bookingInformationCallCount, 0)
    }

    private func releaseTheCartFromThePaymentPage() async throws {
        _ = try await replayToSummary()
        service.cancelResult = .success(ToristyCancellation(message: "never confirmed", confirmationCode: "TRS-20261015-48213"))
        _ = try await checkout.action(checkoutId: Self.checkoutId, actionId: Self.actionId,
                                      result: BookingContract.ActionResult(status: .init(.canceled)), lang: "en",
                                      idempotencyKey: BookingContract.IdempotencyKey())
        let status = await recordStatus("cart-48213")
        XCTAssertEqual(status, .cancelled)
    }

    private func makeBookingData(status: ToristyPaymentStatus, confirmationCode: String = "TRS-20261015-48213") -> ToristyBookingData {
        ToristyBookingData(cartId: "cart-48213", confirmationCode: confirmationCode, currency: "EUR",
                          totalPrice: Decimal(string: "62.50")!, createdAt: clock.now, expiresAt: Self.expiresAt,
                          status: status, activityDate: "2026-10-15")
    }

    private func recordStatus(_ cartId: String) async -> BookingRecordStatus? {
        await store.all().first { $0.reference.primary == cartId }?.status
    }
}
