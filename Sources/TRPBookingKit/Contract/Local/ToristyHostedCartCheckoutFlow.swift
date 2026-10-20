import Foundation

/// Toristy behind the contract with the customer paying on Toristy's hosted cart page instead of a Stripe form.
///
/// The steps and the held cart are `ToristyCheckoutSteps`'. The summary offers the held cart as a
/// `provider_hosted_cart` action; the page reports nothing back, so the client polls `settlement(of:)`, which asks
/// Toristy where the cart stands, and reports `succeeded` once it is confirmed or `canceled` when the customer leaves.
/// A cart Toristy has confirmed is never released, whether the checkout is canceled, expires or is left.
final class ToristyHostedCartCheckoutFlow: ProviderCheckoutFlow {
    typealias BC = BookingContract

    private let steps: ToristyCheckoutSteps
    private let context: FlowContext
    private let toristy: ToristyCheckout

    static let leftNote = "Hosted cart left before payment."
    static let cancelledReason = "The cart was cancelled."
    static let timedOutReason = "The reservation expired."

    var snapshot: FlowSnapshot {
        get { steps.snapshot }
        set { steps.snapshot = newValue }
    }

    init(context: FlowContext, toristy: ToristyCheckout, cart: ToristyHostedCart) {
        self.context = context
        self.toristy = toristy
        steps = ToristyCheckoutSteps(context: context, toristy: toristy) { hold, _ in
            guard let url = cart.url(cartId: hold.reference.primary, languageCode: context.request.lang, currency: hold.currency) else {
                throw FlowRejection.supplierUnavailable(retryable: false)
            }
            return .providerHostedCart(BC.NextAction.Payload(
                id: context.identifiers.next("act_"),
                params: BC.ProviderHostedCartParams(url: url.absoluteString),
                expiresAt: LocalFormat.iso(hold.deadline.expiresAt)))
        }
    }

    func start() async throws {
        try await steps.start()
    }

    /// Runs the step and, once the cart is offered for payment, keeps the booking it becomes on the cart's record,
    /// so a cart paid after the app stopped can still be finished by `ToristyCheckout.resolveUnfinished()`.
    func submit(answers submitted: BC.Answers, expectedAmount: BC.Money?) async throws {
        try await steps.submit(answers: submitted, expectedAmount: expectedAmount)
        guard snapshot.status == .awaitingPayment, let hold = steps.hold else { return }
        let pending = steps.contractBooking(reference: hold.reference, total: hold.total, currency: hold.currency)
        await context.store.update(hold.reference) { $0.pendingContractBooking = pending }
    }

    func back() async throws {
        try await steps.back()
    }

    func settlement(of actionId: String) async throws -> BC.ActionSettlement {
        if snapshot.status == .confirmed { return .succeeded }
        guard let hold = steps.hold, snapshot.nextActionId == actionId else { throw FlowRejection.stepMismatch }
        switch try await toristy.status(of: hold.reference).status {
        case .confirmed: return .succeeded
        case .cancelled: return .failed(reason: Self.cancelledReason)
        case .timedOut: return .failed(reason: Self.timedOutReason)
        default: return .pending
        }
    }

    /// Finishes the checkout when Toristy has confirmed the cart. A `succeeded` result for a cart that is still
    /// reserved changes nothing; any other result releases the cart and shows the summary again, unless Toristy
    /// cannot be reached, in which case the cart is kept and lapses on its own.
    func act(result: BC.ActionResult) async throws {
        guard snapshot.status != .confirmed else { return }
        guard let hold = steps.hold else { throw FlowRejection.stepMismatch }
        guard result.status?.value == .succeeded else { return await leave(hold) }
        let data = try await toristy.status(of: hold.reference)
        switch data.status {
        case .confirmed:
            await confirm(data, hold: hold)
        case .cancelled, .timedOut:
            lapse()
            throw FlowRejection.holdExpired
        default:
            break
        }
    }

    /// Releases the cart unless Toristy has confirmed it, which finishes the checkout instead; a cart whose state
    /// cannot be read is kept and lapses on its own.
    func cancel() async {
        if snapshot.status != .confirmed, let hold = steps.hold {
            guard let data = try? await toristy.status(of: hold.reference) else {
                snapshot.nextAction = nil
                snapshot.allowed = []
                return
            }
            if data.status == .confirmed { return await confirm(data, hold: hold) }
        }
        await steps.cancel()
    }

    /// Finishes the checkout when Toristy confirmed the cart before it expired; otherwise marks the record expired.
    func expire() async {
        if let hold = steps.hold, let data = try? await toristy.status(of: hold.reference), data.status == .confirmed {
            await confirm(data, hold: hold)
        } else {
            await steps.expire()
        }
    }

    private func leave(_ hold: ToristyHold) async {
        guard let data = try? await toristy.status(of: hold.reference) else { return }
        if data.status == .confirmed {
            await confirm(data, hold: hold)
        } else {
            await steps.releaseHold(note: Self.leftNote)
        }
    }

    private func confirm(_ data: ToristyBookingData, hold: ToristyHold) async {
        snapshot.step = nil
        snapshot.nextAction = nil
        snapshot.allowed = []
        let reference = BookingReference(provider: .toristy, primary: hold.reference.primary,
                                         secondary: data.confirmationCode ?? hold.reference.secondary)
        await steps.finish(reference: reference, total: data.totalPrice ?? hold.total, currency: data.currency ?? hold.currency)
    }

    private func lapse() {
        snapshot.status = .expired
        snapshot.clearHold()
        snapshot.step = nil
        snapshot.nextAction = nil
        snapshot.allowed = []
        snapshot.bookingStatus = .expired
        snapshot.result = BC.CheckoutResult(title: "Your reservation has expired",
                                            message: "Toristy no longer holds this cart. Please start again.",
                                            bookingUuid: context.bookingUuid)
    }
}
