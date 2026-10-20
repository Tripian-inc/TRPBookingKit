import Foundation

/// Toristy behind the contract: date, start time, rate, travelers, contact and traveler details and
/// summary, then a Stripe PaymentIntent.
///
/// The steps and the held cart are `ToristyCheckoutSteps`'.
/// Paying runs `ToristyCheckout.pay`, which charges and confirms the cart.
final class ToristyCheckoutFlow: ProviderCheckoutFlow {
    typealias BC = BookingContract

    private let steps: ToristyCheckoutSteps
    private let context: FlowContext
    private let toristy: ToristyCheckout

    var snapshot: FlowSnapshot {
        get { steps.snapshot }
        set { steps.snapshot = newValue }
    }

    init(context: FlowContext, toristy: ToristyCheckout, stripe: StripePaymentIntentProviding) {
        self.context = context
        self.toristy = toristy
        steps = ToristyCheckoutSteps(context: context, toristy: toristy) { hold, email in
            let intent = try await stripe.paymentIntent(for: PaymentRequest(amount: hold.total, currency: hold.currency, description: hold.title,
                                                                            reference: hold.reference, customerEmail: email))
            return .stripePaymentIntent(BC.NextAction.Payload(
                id: context.identifiers.next("act_"),
                params: BC.StripePaymentIntentParams(clientSecret: intent.clientSecret, publishableKey: intent.publishableKey,
                                                     merchantName: intent.merchantName),
                expiresAt: LocalFormat.iso(hold.deadline.expiresAt)))
        }
    }

    func start() async throws {
        try await steps.start()
    }

    func submit(answers submitted: BC.Answers, expectedAmount: BC.Money?) async throws {
        try await steps.submit(answers: submitted, expectedAmount: expectedAmount)
    }

    func back() async throws {
        try await steps.back()
    }

    func act(result: BC.ActionResult) async throws {
        if result.status?.value == .canceled { return }
        guard let hold = steps.hold else { throw FlowRejection.stepMismatch }
        guard result.status?.value == .succeeded else {
            try await steps.offerPayment()
            throw FlowRejection.paymentDeclined
        }
        snapshot.status = .processing
        snapshot.nextAction = nil
        snapshot.allowed = []
        do {
            let confirmed = try await toristy.pay(hold, customerEmail: steps.email)
            await steps.finish(reference: confirmed.reference, total: confirmed.total, currency: confirmed.currency)
        } catch BookingError.paymentFailed, BookingError.paymentCancelled {
            try await steps.offerPayment()
            throw FlowRejection.paymentDeclined
        } catch BookingError.holdExpired {
            throw FlowRejection.holdExpired
        } catch {
            snapshot.status = .failed
            snapshot.clearHold()
            snapshot.bookingStatus = .rejected
            snapshot.result = BC.CheckoutResult(title: "Your booking could not be completed",
                                                message: "Toristy did not confirm this booking. Any charge will be refunded.",
                                                bookingUuid: context.bookingUuid)
        }
    }

    /// Releases an unconfirmed cart at Toristy without emailing anyone, so its seats are not held until it expires.
    func cancel() async {
        await steps.cancel()
    }

    func expire() async {
        await steps.expire()
    }
}
