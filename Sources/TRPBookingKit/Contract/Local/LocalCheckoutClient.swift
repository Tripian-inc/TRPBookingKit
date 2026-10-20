import Foundation

/// A `CheckoutClient` that runs the contract's checkout on the device, over the Viator, Toristy and
/// Ticket Evolution checkouts of this package, until the Tripian backend serves it.
///
/// Limits of this local phase:
/// - idempotency keys are accepted but not enforced, so `IDEMPOTENCY_MISMATCH` and `IN_PROGRESS` never occur;
/// - only Viator answers `202` with `Retry-After`, while its booking call is still running;
/// - bookings live on the device in `BookingRecordStore`, and checkouts only in memory;
/// - `extend` is never offered, and an unknown checkout id answers `404` with the code `NOT_FOUND`.
/// Tokens, nonces and session tokens are kept in memory only.
public actor LocalCheckoutClient: CheckoutClient {
    public typealias BC = BookingContract

    private struct Session {
        let flow: ProviderCheckoutFlow
        let context: FlowContext
    }

    private let catalog: LocalProductCatalog
    private let store: BookingRecordStore
    private let contractVersion: String
    private let fallbackWebBase: String?
    private let identifiers: LocalIdentifiers
    private let now: @Sendable () -> Date
    private let makeFlow: @Sendable (FlowContext) -> ProviderCheckoutFlow?
    private var sessions: [String: Session] = [:]

    init(catalog: LocalProductCatalog,
         store: BookingRecordStore,
         contractVersion: String,
         fallbackWebBase: String?,
         identifiers: LocalIdentifiers,
         now: @escaping @Sendable () -> Date,
         makeFlow: @escaping @Sendable (FlowContext) -> ProviderCheckoutFlow?) {
        self.catalog = catalog
        self.store = store
        self.contractVersion = contractVersion
        self.fallbackWebBase = fallbackWebBase
        self.identifiers = identifiers
        self.now = now
        self.makeFlow = makeFlow
    }

    public func create(_ request: BC.CreateCheckoutRequest, idempotencyKey: BC.IdempotencyKey) async throws -> BC.CheckoutResponse {
        try checkVersion()
        guard let product = await catalog.product(id: request.productId) else {
            throw BC.ContractError(httpStatus: 422, data: BC.ErrorData(
                code: .init(.validation), errors: [BC.ErrorData.FieldError(field: "productId", message: "This product cannot be booked in the app.")],
                retryable: false, checkout: nil))
        }
        let context = FlowContext(checkoutId: identifiers.next("chk_"), bookingUuid: request.bookingUuid, product: product,
                                  request: request, store: store, identifiers: identifiers, now: now)
        guard let flow = makeFlow(context) else { throw Self.unavailable }
        let session = Session(flow: flow, context: context)
        try await run(session, checksHold: false) { try await flow.start() }
        sessions[context.checkoutId] = session
        return response(session)
    }

    public func get(id: String, lang: String) async throws -> BC.CheckoutResponse {
        let session = try session(id)
        session.flow.snapshot.httpStatus = 200
        session.flow.snapshot.retryAfter = nil
        if await expireIfNeeded(session) { return response(session) }
        await session.flow.refresh()
        return response(session)
    }

    public func submit(checkoutId: String, stepId: String, answers: BC.Answers, expectedAmount: BC.Money?,
                       lang: String, idempotencyKey: BC.IdempotencyKey) async throws -> BC.CheckoutResponse {
        let session = try session(checkoutId)
        try await run(session, allowed: .submit, matches: session.flow.snapshot.step?.id == stepId) {
            try await session.flow.submit(answers: answers, expectedAmount: expectedAmount)
        }
        return response(session)
    }

    public func back(checkoutId: String, fromStepId: String, lang: String,
                     idempotencyKey: BC.IdempotencyKey) async throws -> BC.CheckoutResponse {
        let session = try session(checkoutId)
        try await run(session, allowed: .back, matches: session.flow.snapshot.shownStepId == fromStepId) {
            try await session.flow.back()
        }
        return response(session)
    }

    public func action(checkoutId: String, actionId: String, result: BC.ActionResult, lang: String,
                       idempotencyKey: BC.IdempotencyKey) async throws -> BC.CheckoutResponse {
        let session = try session(checkoutId)
        try await run(session, matches: session.flow.snapshot.nextActionId == actionId) {
            try await session.flow.act(result: result)
        }
        return response(session)
    }

    public func extend(checkoutId: String, lang: String, idempotencyKey: BC.IdempotencyKey) async throws -> BC.CheckoutResponse {
        let session = try session(checkoutId)
        try await run(session, allowed: .extend) { try await session.flow.extend() }
        return response(session)
    }

    public func cancel(checkoutId: String, lang: String, idempotencyKey: BC.IdempotencyKey) async throws -> BC.CheckoutResponse {
        let session = try session(checkoutId)
        try await run(session, allowed: .cancel, checksHold: false) {
            await session.flow.cancel()
            guard session.flow.snapshot.status != .confirmed else { return }
            session.flow.snapshot.status = .cancelled
            session.flow.snapshot.clearHold()
            session.flow.snapshot.step = nil
            session.flow.snapshot.nextAction = nil
            session.flow.snapshot.allowed = []
            if session.flow.snapshot.bookingStatus != nil { session.flow.snapshot.bookingStatus = .cancelled }
        }
        return response(session)
    }

    public func settlement(checkoutId: String, actionId: String) async throws -> BC.ActionSettlement {
        let session = try session(checkoutId)
        do {
            return try await session.flow.settlement(of: actionId)
        } catch {
            throw contractError(FlowRejection.from(error), session)
        }
    }

    private static let unavailable = BC.ContractError(
        httpStatus: 503, data: BC.ErrorData(code: .init(.supplierUnavailable), errors: [], retryable: true, checkout: nil))

    private func checkVersion() throws {
        guard contractVersion != BC.version else { return }
        throw BC.ContractError(httpStatus: 400, data: BC.ErrorData(
            code: .init(.versionUnsupported), errors: [], retryable: false, checkout: nil, supported: [BC.version]))
    }

    private func session(_ id: String) throws -> Session {
        try checkVersion()
        guard let session = sessions[id] else {
            throw BC.ContractError(httpStatus: 404, data: BC.ErrorData(
                code: .init(rawValue: "NOT_FOUND"), errors: [], retryable: false, checkout: nil))
        }
        return session
    }

    private func run(_ session: Session, allowed action: BC.AllowedAction? = nil, matches: Bool = true, checksHold: Bool = true,
                     _ body: () async throws -> Void) async throws {
        session.flow.snapshot.httpStatus = 200
        session.flow.snapshot.retryAfter = nil
        if checksHold, await expireIfNeeded(session) { throw contractError(.holdExpired, session) }
        let isAllowed = action.map { session.flow.snapshot.allowed.contains($0) } ?? true
        guard isAllowed, matches else { throw contractError(.stepMismatch, session) }
        do {
            try await body()
        } catch {
            throw contractError(FlowRejection.from(error), session)
        }
    }

    private func expireIfNeeded(_ session: Session) async -> Bool {
        let snapshot = session.flow.snapshot
        guard !snapshot.isFinished, let deadline = snapshot.holdExpiresAt, deadline <= now() else { return false }
        await session.flow.expire()
        guard session.flow.snapshot.status != .confirmed else { return false }
        let minutes = Int(((deadline.timeIntervalSince(snapshot.holdPlacedAt ?? deadline)) / 60).rounded())
        session.flow.snapshot.status = .expired
        session.flow.snapshot.clearHold()
        session.flow.snapshot.step = nil
        session.flow.snapshot.nextAction = nil
        session.flow.snapshot.allowed = []
        session.flow.snapshot.bookingStatus = .expired
        session.flow.snapshot.result = BC.CheckoutResult(
            title: "Your reservation has expired",
            message: "The \(minutes) minutes to complete this booking have passed. Please start again.",
            bookingUuid: session.context.bookingUuid)
        return true
    }

    private func contractError(_ rejection: FlowRejection, _ session: Session) -> BC.ContractError {
        BC.ContractError(httpStatus: rejection.httpStatus, data: BC.ErrorData(
            code: .init(rejection.code), errors: rejection.errors, retryable: rejection.retryable,
            checkout: rejection.includesCheckout ? checkout(session) : nil))
    }

    private func response(_ session: Session) -> BC.CheckoutResponse {
        BC.CheckoutResponse(checkout: checkout(session), httpStatus: session.flow.snapshot.httpStatus,
                            retryAfter: session.flow.snapshot.retryAfter)
    }

    private func checkout(_ session: Session) -> BC.Checkout {
        let snapshot = session.flow.snapshot
        let context = session.context
        return BC.Checkout(
            id: context.checkoutId,
            status: .init(snapshot.status),
            provider: context.product.provider.rawValue,
            product: BC.Product(id: context.product.id, optionId: snapshot.optionId, title: context.product.title,
                                imageUrl: context.product.imageUrl),
            amount: snapshot.amount,
            holdExpiresAt: snapshot.holdExpiresAt.map(LocalFormat.iso),
            priceValidUntil: snapshot.priceValidUntil.map(LocalFormat.iso),
            currentStep: snapshot.step,
            nextAction: snapshot.nextAction,
            allowedActions: snapshot.allowed.map { .init($0) },
            booking: snapshot.bookingStatus.map { BC.BookingRef(uuid: context.bookingUuid, status: .init($0)) },
            result: snapshot.result,
            fallback: fallbackWebBase.map { BC.Fallback(webUrl: $0 + context.checkoutId, text: "Continue your booking on the web.") })
    }
}
