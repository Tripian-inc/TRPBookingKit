import Foundation
import XCTest
@testable import TRPBookingKit

/// The local clients answer the Toristy fixtures from a mocked Toristy service and a mocked Stripe.
///
/// Excluded fixture paths, which the local flow cannot produce from what Toristy returns:
/// - `03-time` `currentStep.blocks[0].options[1].subtitle`: "Up to 8 people" needs a per-booking departure rate,
///   and Toristy keys departure rates by a numeric id that a string rate id such as `RATE_PRIV` never matches.
/// - `09-booking` `vouchers[0]`: Toristy hands back no voucher, so the local booking lists none.
final class LocalToristyContractTests: XCTestCase {
    private let directory = "toristy"
    private var clock: TestClock!
    private var service: MockToristyBookingService!
    private var stripe: MockStripePaymentIntents!
    private var store: InMemoryBookingRecordStore!
    private var checkout: LocalCheckoutClient!
    private var bookings: LocalBookingClient!

    private static let flow = ["01-create", "02-date", "03-time", "04-rate", "05-travelers", "06-details", "07-summary", "08-payment"]
    private static let exclusions = ["03-time": ["currentStep.blocks[0].options[1].subtitle"], "09-booking": ["vouchers[0]"]]

    override func setUp() async throws {
        clock = TestClock(ISO8601DateFormatter().date(from: "2026-10-02T09:12:00Z")!)
        service = MockToristyBookingService()
        service.bookingInformationResult = .success(Self.information)
        service.availabilityResult = .success(Self.availability)
        service.validateResult = .success(ToristyValidation(cartId: "cart-48213", confirmationCode: "TRS-20261015-48213",
                                                            totalPrice: Decimal(string: "62.50")!, currency: "EUR"))
        service.bookingDataResult = .success(ToristyBookingData(
            cartId: "cart-48213", confirmationCode: "TRS-20261015-48213", currency: "EUR", totalPrice: Decimal(string: "62.50")!,
            createdAt: clock.now, expiresAt: ISO8601DateFormatter().date(from: "2026-10-02T09:42:00Z")!, status: .reserved,
            activityDate: "2026-10-15"))
        stripe = MockStripePaymentIntents()
        store = InMemoryBookingRecordStore()
        let now: @Sendable () -> Date = { [clock] in clock!.now }
        let toristy = ToristyCheckout(service: service, payment: stripe, store: store, backgroundTasks: ImmediateTaskRunner(),
                                      confirmationAttempts: 1, retryDelay: 0, now: now)
        let product = LocalProduct(
            id: "TOR-PMI-CATHEDRAL", provider: .toristy, providerProductId: "48213", title: "Palma Cathedral and Old Town walking tour",
            imageUrl: "https://cdn.tripian.com/p/TOR-PMI-CATHEDRAL.jpg", timeZone: TimeZone(identifier: "Europe/Madrid")!,
            durationMinutes: 120,
            meetingPoint: .init(name: "Plaça de la Seu, cathedral main door", address: "Plaça de la Seu s/n, 07001 Palma",
                                lat: 39.5676, lng: 2.6484))
        checkout = LocalCheckoutClient(viator: nil, toristy: toristy, stripe: stripe, store: store,
                                       catalog: StaticProductCatalog([product]), fallbackWebBase: "https://book.tripian.com/c/",
                                       identifiers: .sequence(["chk_01J9ZT7P2N", "act_01J9ZTB4"]), now: now)
        bookings = LocalBookingClient(store: store, viator: nil, toristy: toristy, contractVersion: BookingContract.version, now: now)
    }

    private func replay(_ names: ArraySlice<String>) async throws {
        for name in names {
            try await assertLocalSnapshot(directory, name, checkout: checkout, bookings: bookings, excluding: Self.exclusions[name] ?? [])
        }
    }

    func testHappyPath() async throws {
        try await replay(Self.flow[...])
        try await assertLocalSnapshot(directory, "09-booking", checkout: checkout, bookings: bookings,
                                      excluding: Self.exclusions["09-booking"] ?? [])
        XCTAssertEqual(stripe.chargeCallCount, 1)
        XCTAssertEqual(stripe.lastIntentRequest?.amount, Decimal(string: "62.50"))
    }

    func testHoldExpired() async throws {
        try await replay(Self.flow[0..<6])
        clock.now = ISO8601DateFormatter().date(from: "2026-10-02T09:43:00Z")!
        try await assertLocalSnapshot("toristy/errors", "HOLD_EXPIRED", checkout: checkout, bookings: bookings)
    }

    func testCanceledPaymentLeavesCheckoutUnchanged() async throws {
        try await replay(Self.flow[0..<7])
        let recordsBefore = await store.all().map(\.status)
        let response = try await checkout.action(checkoutId: "chk_01J9ZT7P2N", actionId: "act_01J9ZTB4",
                                                 result: BookingContract.ActionResult(status: .init(.canceled)), lang: "en")
        XCTAssertEqual(response.checkout.status.value, .awaitingPayment)
        XCTAssertEqual(response.checkout.nextAction?.id, "act_01J9ZTB4")
        XCTAssertEqual(response.checkout.allowedActions.map(\.value), [.back, .cancel])
        XCTAssertEqual(stripe.intentCallCount, 1)
        XCTAssertEqual(stripe.chargeCallCount, 0)
        XCTAssertEqual(service.confirmCallCount, 0)
        let recordsAfter = await store.all().map(\.status)
        XCTAssertEqual(recordsAfter, recordsBefore)
    }

    func testBackFromAwaitingPaymentShowsSummaryAndKeepsHold() async throws {
        try await replay(Self.flow[0..<7])
        let validations = service.validateCallCount
        let back = try await checkout.back(checkoutId: "chk_01J9ZT7P2N", fromStepId: "summary", lang: "en")
        XCTAssertEqual(back.checkout.status.value, .collectingDetails)
        XCTAssertEqual(back.checkout.currentStep?.id, "summary")
        XCTAssertNil(back.checkout.nextAction)
        XCTAssertTrue(back.checkout.allowedActions.contains { $0.value == .submit })
        let resubmitted = try await checkout.submit(checkoutId: "chk_01J9ZT7P2N", stepId: "summary", answers: [:], lang: "en")
        XCTAssertEqual(resubmitted.checkout.status.value, .awaitingPayment)
        XCTAssertNotNil(resubmitted.checkout.nextAction)
        XCTAssertEqual(service.validateCallCount, validations)
        XCTAssertEqual(stripe.chargeCallCount, 0)
    }

    func testDeclinedPaymentActionNeverCallsConfirm() async throws {
        try await replay(Self.flow[0..<7])
        do {
            _ = try await checkout.action(checkoutId: "chk_01J9ZT7P2N", actionId: "act_01J9ZTB4",
                                          result: BookingContract.ActionResult(status: .init(rawValue: "failed")), lang: "en")
            XCTFail("Expected a payment decline")
        } catch let error as BookingContract.ContractError {
            XCTAssertEqual(error.data.code.value, .paymentDeclined)
        }
        XCTAssertEqual(service.confirmCallCount, 0)
    }

    func testCancelOfAHeldUnconfirmedCartReleasesItAtToristyWithoutNotifying() async throws {
        try await replay(Self.flow[0..<7])
        service.cancelResult = .success(ToristyCancellation(message: "never confirmed", confirmationCode: "TRS-20261015-48213"))
        let response = try await checkout.cancel(checkoutId: "chk_01J9ZT7P2N", lang: "en")
        XCTAssertEqual(response.checkout.status.value, .cancelled)
        XCTAssertEqual(service.cancelledReferences.map(\.primary), ["cart-48213"])
        XCTAssertEqual(service.cancelledNotes, ["Checkout cancelled before payment."])
        XCTAssertEqual(service.cancelledNotifyValues, [false])
        let status = await recordStatus("cart-48213")
        XCTAssertEqual(status, .cancelled)
    }

    func testCancelStillCancelsTheCheckoutWhenToristyRefusesTheRelease() async throws {
        try await replay(Self.flow[0..<7])
        service.cancelResult = .failure(BookingError.server(status: 500, code: nil, message: "unavailable"))
        let response = try await checkout.cancel(checkoutId: "chk_01J9ZT7P2N", lang: "en")
        XCTAssertEqual(response.checkout.status.value, .cancelled)
        XCTAssertEqual(service.cancelCallCount, 1)
        XCTAssertEqual(service.cancelledNotifyValues, [false])
        let status = await recordStatus("cart-48213")
        XCTAssertEqual(status, .cancelled)
    }

    func testAPaymentResultArrivingWhileTheReleaseIsInFlightCannotConfirmTheCart() async throws {
        try await replay(Self.flow[0..<7])
        let release = SuspendedCall()
        service.cancelHandler = { await release.suspend() }
        service.cancelResult = .success(ToristyCancellation(message: "never confirmed", confirmationCode: "TRS-20261015-48213"))
        let client: LocalCheckoutClient = checkout
        let cancelling = Task { try await client.cancel(checkoutId: "chk_01J9ZT7P2N", lang: "en") }
        await release.waitUntilEntered()
        do {
            _ = try await client.action(checkoutId: "chk_01J9ZT7P2N", actionId: "act_01J9ZTB4",
                                        result: BookingContract.ActionResult(status: .init(.succeeded)), lang: "en")
            XCTFail("Expected STEP_MISMATCH")
        } catch let error as BookingContract.ContractError {
            XCTAssertEqual(error.data.code.value, .stepMismatch)
        }
        release.resume()
        let response = try await cancelling.value
        XCTAssertEqual(response.checkout.status.value, .cancelled)
        XCTAssertEqual(stripe.chargeCallCount, 0)
        XCTAssertEqual(service.confirmCallCount, 0)
        let status = await recordStatus("cart-48213")
        XCTAssertEqual(status, .cancelled)
    }

    func testChangingTheSelectionReleasesThePreviousCartWithoutNotifying() async throws {
        try await replay(Self.flow[0..<7])
        service.cancelResult = .success(ToristyCancellation(message: "never confirmed", confirmationCode: "TRS-20261015-48213"))
        service.validateResult = .success(ToristyValidation(cartId: "cart-48214", confirmationCode: "TRS-20261015-48214",
                                                            totalPrice: Decimal(string: "62.50")!, currency: "EUR"))
        _ = try await checkout.back(checkoutId: "chk_01J9ZT7P2N", fromStepId: "summary", lang: "en")
        let details = try await checkout.back(checkoutId: "chk_01J9ZT7P2N", fromStepId: "summary", lang: "en")
        XCTAssertEqual(details.checkout.currentStep?.id, "details")
        var answers = Self.detailsAnswers
        answers["lead.firstName"] = "Ayşe"
        _ = try await checkout.submit(checkoutId: "chk_01J9ZT7P2N", stepId: "details", answers: answers, lang: "en")
        XCTAssertEqual(service.validateCallCount, 2)
        XCTAssertEqual(service.cancelledReferences.map(\.primary), ["cart-48213"])
        XCTAssertEqual(service.cancelledNotes, ["Selection changed before payment."])
        XCTAssertEqual(service.cancelledNotifyValues, [false])
        let replaced = await recordStatus("cart-48213")
        XCTAssertEqual(replaced, .cancelled)
        let current = await recordStatus("cart-48214")
        XCTAssertEqual(current, .held)
    }

    func testResubmittingAnUnchangedSelectionKeepsTheCartAndReleasesNothing() async throws {
        try await replay(Self.flow[0..<7])
        _ = try await checkout.back(checkoutId: "chk_01J9ZT7P2N", fromStepId: "summary", lang: "en")
        _ = try await checkout.back(checkoutId: "chk_01J9ZT7P2N", fromStepId: "summary", lang: "en")
        _ = try await checkout.submit(checkoutId: "chk_01J9ZT7P2N", stepId: "details", answers: Self.detailsAnswers, lang: "en")
        XCTAssertEqual(service.validateCallCount, 1)
        XCTAssertEqual(service.cancelCallCount, 0)
    }

    func testADeclinedChargeKeepsTheCartForAnotherCard() async throws {
        try await replay(Self.flow[0..<7])
        stripe.chargeResult = .failure(BookingError.paymentFailed("Card declined"))
        do {
            _ = try await checkout.action(checkoutId: "chk_01J9ZT7P2N", actionId: "act_01J9ZTB4",
                                          result: BookingContract.ActionResult(status: .init(.succeeded)), lang: "en")
            XCTFail("Expected a payment decline")
        } catch let error as BookingContract.ContractError {
            XCTAssertEqual(error.data.code.value, .paymentDeclined)
        }
        let current = try await checkout.get(id: "chk_01J9ZT7P2N", lang: "en")
        XCTAssertEqual(current.checkout.status.value, .awaitingPayment)
        XCTAssertNotNil(current.checkout.nextAction)
        XCTAssertEqual(service.cancelCallCount, 0)
        XCTAssertEqual(service.confirmCallCount, 0)
        let status = await recordStatus("cart-48213")
        XCTAssertEqual(status, .held)
    }

    func testCancelBeforeAnyHoldIsPlacedDoesNotCallToristyCancel() async throws {
        try await replay(Self.flow[0..<5])
        _ = try await checkout.cancel(checkoutId: "chk_01J9ZT7P2N", lang: "en")
        XCTAssertEqual(service.cancelCallCount, 0)
    }

    func testBackFromAwaitingPaymentRejectsOtherStep() async throws {
        try await replay(Self.flow[0..<7])
        do {
            _ = try await checkout.back(checkoutId: "chk_01J9ZT7P2N", fromStepId: "details", lang: "en")
            XCTFail("Expected STEP_MISMATCH")
        } catch let error as BookingContract.ContractError {
            XCTAssertEqual(error.data.code.value, .stepMismatch)
        }
    }

    private func recordStatus(_ cartId: String) async -> BookingRecordStatus? {
        await store.all().first { $0.reference.primary == cartId }?.status
    }

    private static let detailsAnswers: BookingContract.Answers = [
        "lead.firstName": "Elif", "lead.lastName": "Demir", "lead.email": "elif@example.com", "lead.phone": "+905551112233",
        "t1.fullName": "Elif Demir", "t2.fullName": "Can Demir", "t3.fullName": "Deniz Demir", "t3.birthDate": "2017-05-09"
    ]

    static let information = ToristyBookingInformation(
        serviceId: 48213, currency: "EUR", startingPrice: 25, lowestPrice: 25, fields: ToristyBookingFields(),
        rates: [
            ToristyRate(id: "RATE_STD", name: "Standard group", startingPrice: 25, prices: [
                ToristyPricingCategory(id: "ADULT", name: "Adult", price: 25, minAge: 16),
                ToristyPricingCategory(id: "CHILD", name: "Child", price: Decimal(string: "12.50")!, minAge: 6, maxAge: 15)
            ]),
            ToristyRate(id: "RATE_PRIV", name: "Private group", startingPrice: 180, prices: [
                ToristyPricingCategory(id: "GROUP", name: "Group", price: 180)
            ])
        ],
        cancellationPolicy: nil, cancellationRules: [ToristyCancellationRule(feePercentage: 100, cutoffHours: 24)],
        pickupPoints: [], dropoffPoints: [])

    static let availability = ToristyAvailability(serviceId: 48213, days: [
        ToristyAvailabilityDay(date: BookingDate("2026-10-15")!, times: [
            ToristyStartTime(time: "10:00", id: 1, availableCount: 12),
            ToristyStartTime(time: "15:30", id: 2, availableCount: 3)
        ]),
        ToristyAvailabilityDay(date: BookingDate("2026-10-17")!, times: [ToristyStartTime(time: "10:00", id: 3, availableCount: 20)]),
        ToristyAvailabilityDay(date: BookingDate("2026-10-22")!, times: [ToristyStartTime(time: "10:00", id: 4, availableCount: 20)]),
        ToristyAvailabilityDay(date: BookingDate("2026-10-24")!, times: [ToristyStartTime(time: "10:00", id: 5, availableCount: 20)])
    ])
}

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// A Stripe that issues one fixed PaymentIntent and charges it.
final class MockStripePaymentIntents: StripePaymentIntentProviding, @unchecked Sendable {
    var intentResult: Result<StripePaymentIntent, Error> = .success(StripePaymentIntent(
        id: "pi_3QAbCdEf12345678", clientSecret: "pi_3QAbCdEf12345678_secret_9ZyXwVuTsR",
        publishableKey: "pk_test_51Tripian0000000000000000", merchantName: "Tripian"))
    var chargeResult: Result<PaymentReceipt, Error> = .success(PaymentReceipt(
        chargeId: "pi_3QAbCdEf12345678", amount: Decimal(string: "62.50")!, currency: "EUR", cardBrand: "visa", last4: "4242",
        paidAt: Date(timeIntervalSince1970: 0)))
    var lastIntentRequest: PaymentRequest?
    var intentCallCount = 0
    var chargeCallCount = 0

    func paymentIntent(for request: PaymentRequest) async throws -> StripePaymentIntent {
        intentCallCount += 1
        lastIntentRequest = request
        return try intentResult.get()
    }

    func charge(_ request: PaymentRequest) async throws -> PaymentReceipt {
        chargeCallCount += 1
        return try chargeResult.get()
    }

    func refund(_ receipt: PaymentReceipt, reason: String) async throws {}
}
