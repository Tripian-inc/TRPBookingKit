import Foundation

/// A Toristy cart held for the customer, waiting for payment.
public struct ToristyHold: Sendable, Hashable {
    public let reference: BookingReference
    /// Exactly what will be charged.
    public let total: Decimal
    public let currency: String
    public let deadline: BookingDeadline
    public let activityId: String
    public let title: String
}

/// A paid and confirmed Toristy booking.
public struct ToristyConfirmedBooking: Sendable, Hashable {
    public let reference: BookingReference
    public let receipt: PaymentReceipt
    public let total: Decimal
    public let currency: String
}

/// Runs a Toristy Option B booking end to end: validate, hold, charge, confirm, and recover.
///
/// The cart references are saved before the charge, and a charge that the provider does not
/// confirm is refunded through the same `PaymentProcessing`; when that refund fails too the
/// record stays `.needsRefund` for `resolveUnfinished()` or support.
/// Without a `PaymentProcessing` the customer pays on `hostedCart` instead, and `pay` is unavailable.
public actor ToristyCheckout {

    /// How long a cart lives when `bookingdata` does not say.
    public static let defaultCartLifetime: TimeInterval = 30 * 60

    /// How long past its deadline a hosted cart the checkout released is still asked about, since a payment already
    /// underway on Toristy's page can confirm it after the release.
    public static let releasedCartRecheckWindow: TimeInterval = 15 * 60

    /// The page the customer pays a reserved cart on, when the host pays through Toristy's hosted cart.
    public nonisolated let hostedCart: ToristyHostedCart?

    private let service: ToristyBookingService
    private let payment: PaymentProcessing?
    private let store: BookingRecordStore
    private let backgroundTasks: BackgroundTaskRunning
    private let validator: ToristySelectionValidator
    private let confirmationAttempts: Int
    private let retryDelay: TimeInterval
    private let now: @Sendable () -> Date
    private var paying: Set<BookingReference> = []
    private var resolving: Task<[BookingRecord], Never>?

    public init(service: ToristyBookingService,
                payment: PaymentProcessing,
                store: BookingRecordStore,
                backgroundTasks: BackgroundTaskRunning = BookingConfiguration.defaultBackgroundTaskRunner,
                validator: ToristySelectionValidator = ToristySelectionValidator(),
                confirmationAttempts: Int = 3,
                retryDelay: TimeInterval = 2,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(service: service, hostedCart: nil, payment: payment, store: store, backgroundTasks: backgroundTasks,
                  validator: validator, confirmationAttempts: confirmationAttempts, retryDelay: retryDelay, now: now)
    }

    /// - Parameters:
    ///   - hostedCart: the page the customer pays on when there is no `payment`.
    ///   - payment: charges the customer and refunds a charge Toristy does not confirm; `nil` leaves payment to `hostedCart`.
    public init(service: ToristyBookingService,
                hostedCart: ToristyHostedCart?,
                payment: PaymentProcessing? = nil,
                store: BookingRecordStore,
                backgroundTasks: BackgroundTaskRunning = BookingConfiguration.defaultBackgroundTaskRunner,
                validator: ToristySelectionValidator = ToristySelectionValidator(),
                confirmationAttempts: Int = 3,
                retryDelay: TimeInterval = 2,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.hostedCart = hostedCart
        self.service = service
        self.payment = payment
        self.store = store
        self.backgroundTasks = backgroundTasks
        self.validator = validator
        self.confirmationAttempts = max(1, confirmationAttempts)
        self.retryDelay = retryDelay
        self.now = now
    }

    public func bookingInformation(serviceId: Int, currency: String?) async throws -> ToristyBookingInformation {
        try await service.bookingInformation(serviceId: serviceId, currency: currency)
    }

    public func availability(serviceId: Int, from start: BookingDate, through end: BookingDate) async throws -> ToristyAvailability {
        try await service.availability(serviceId: serviceId, from: start, through: end)
    }

    /// Checks the selection, opens the cart and saves its references.
    public func reserve(_ selection: ToristySelection,
                        information: ToristyBookingInformation,
                        activityId: String,
                        title: String) async throws -> ToristyHold {
        try validator.validate(selection, information: information)
        let validation = try await service.validate(ToristyValidationRequest(selection: selection))
        let data = try? await service.bookingData(cartId: validation.cartId)
        let deadline = data?.deadline ?? BookingDeadline(expiresAt: now().addingTimeInterval(Self.defaultCartLifetime))
        let currency = validation.currency.isEmpty ? selection.currency.uppercased() : validation.currency

        await store.save(BookingRecord(
            reference: validation.reference,
            activityId: activityId,
            title: title,
            travelDate: selection.date,
            status: .held,
            total: validation.totalPrice,
            currency: currency,
            deadline: deadline,
            providerStatus: "Reserved",
            createdAt: now()
        ))
        return ToristyHold(reference: validation.reference, total: validation.totalPrice, currency: currency,
                           deadline: deadline, activityId: activityId, title: title)
    }

    /// Charges the customer and confirms the cart.
    ///
    /// Throws `.holdExpired` before charging a cart past its deadline,
    /// `.confirmationFailedAfterCharge` when the money was taken but the booking not confirmed, and
    /// `.providerNotConfigured` when there is no `PaymentProcessing` to charge with.
    public func pay(_ hold: ToristyHold, customerEmail: String?) async throws -> ToristyConfirmedBooking {
        guard let payment else { throw BookingError.providerNotConfigured(.toristy) }
        paying.insert(hold.reference)
        defer { paying.remove(hold.reference) }
        guard !hold.deadline.isExpired(at: now()) else {
            await store.update(hold.reference) { $0.status = .expired }
            throw BookingError.holdExpired
        }

        let request = PaymentRequest(amount: hold.total, currency: hold.currency, description: hold.title,
                                     reference: hold.reference, customerEmail: customerEmail)
        let receipt = try await payment.charge(request)

        return try await backgroundTasks.run(named: "trp.booking.toristy.confirm") {
            await self.store.update(hold.reference) {
                $0.status = .charged
                $0.receipt = receipt
            }
            return try await self.confirm(hold, receipt: receipt)
        }
    }

    /// Asks Toristy where the cart stands and mirrors it into the record.
    public func status(of reference: BookingReference) async throws -> ToristyBookingData {
        let data = try await service.bookingData(cartId: reference.primary)
        await store.update(reference) { record in
            record.providerStatus = self.describe(data.status)
            if let status = data.status.recordStatus, record.status != .needsRefund, record.status != .refunded {
                record.status = status
            }
            if let deadline = data.deadline { record.deadline = deadline }
        }
        return data
    }

    /// Cancels a confirmed booking. Toristy computes no refund; apply `cancellation_policy`
    /// and refund on the host's side.
    public func cancel(_ reference: BookingReference, note: String?, notify: Bool = true) async throws -> ToristyCancellation {
        let result = try await service.cancel(reference, note: note, notify: notify)
        await store.update(reference) {
            $0.status = .cancelled
            $0.providerStatus = "Cancelled"
        }
        return result
    }

    /// Retries confirmation or the refund of records a previous run left charged but unconfirmed, and settles carts
    /// held without a charge by their status alone: a confirmed cart finishes its booking, while a cancelled, timed out
    /// or lapsed one is cleared. A hosted cart the checkout released is asked about until `releasedCartRecheckWindow`
    /// past its deadline and finishes its booking if Toristy confirmed it after all; otherwise it stays cleared.
    ///
    /// A cart whose `pay` is still running is left to it, and a call made while another runs waits for that one.
    public func resolveUnfinished() async -> [BookingRecord] {
        if let resolving { return await resolving.value }
        let run = Task { await self.settleUnfinished() }
        resolving = run
        let records = await run.value
        resolving = nil
        return records
    }

    private func settleUnfinished() async -> [BookingRecord] {
        for record in await store.unresolved() where record.reference.provider == .toristy {
            guard let receipt = record.receipt, !paying.contains(record.reference) else { continue }
            let data = try? await service.bookingData(cartId: record.reference.primary)
            guard !paying.contains(record.reference) else { continue }
            if let data, data.status == .confirmed {
                await store.update(record.reference) {
                    $0.status = .confirmed
                    $0.providerStatus = "Confirmed"
                }
                continue
            }
            if record.status == .charged, !(record.deadline?.isExpired(at: now()) ?? true),
               (try? await service.confirm(record.reference, receipt: receipt, amount: record.total ?? receipt.amount,
                                           currency: record.currency ?? receipt.currency)) != nil {
                await store.update(record.reference) {
                    $0.status = .confirmed
                    $0.providerStatus = "Confirmed"
                }
                continue
            }
            guard !paying.contains(record.reference) else { continue }
            await refund(record.reference, receipt: receipt, reason: "Toristy did not confirm the booking.")
        }
        for record in await store.all()
        where record.reference.provider == .toristy && record.receipt == nil && !paying.contains(record.reference)
            && (record.status == .held || (record.status == .confirmed && record.contractBooking == nil && record.pendingContractBooking != nil)) {
            await settleUncharged(record)
        }
        for record in await store.all() where isRecheckableRelease(record) && !paying.contains(record.reference) {
            await finishIfConfirmed(record)
        }
        return await store.all().filter { $0.reference.provider == .toristy }
    }

    private func isRecheckableRelease(_ record: BookingRecord) -> Bool {
        guard record.reference.provider == .toristy, record.receipt == nil, record.status == .cancelled,
              record.contractBooking == nil, record.pendingContractBooking != nil, let deadline = record.deadline else { return false }
        return now() < deadline.expiresAt.addingTimeInterval(Self.releasedCartRecheckWindow)
    }

    private func finishIfConfirmed(_ record: BookingRecord) async {
        guard let data = try? await service.bookingData(cartId: record.reference.primary), data.status == .confirmed else { return }
        await finishConfirmed(record.reference, confirmationCode: data.confirmationCode)
    }

    private func finishConfirmed(_ reference: BookingReference, confirmationCode: String?) async {
        await store.update(reference) {
            $0.status = .confirmed
            $0.providerStatus = "Confirmed"
            if let pending = $0.pendingContractBooking {
                $0.contractBooking = pending.with(providerReference: confirmationCode ?? pending.providerReference)
                $0.pendingContractBooking = nil
            }
        }
    }

    private func settleUncharged(_ record: BookingRecord) async {
        guard let data = try? await service.bookingData(cartId: record.reference.primary),
              !paying.contains(record.reference) else { return }
        let lapsed = (data.deadline ?? record.deadline)?.isExpired(at: now()) ?? false
        switch data.status {
        case .confirmed:
            await finishConfirmed(record.reference, confirmationCode: data.confirmationCode)
        case .cancelled:
            await store.update(record.reference) {
                $0.status = .cancelled
                $0.providerStatus = "Cancelled"
            }
        case .timedOut:
            await store.update(record.reference) {
                $0.status = .expired
                $0.providerStatus = "Timed Out"
            }
        case .reserved where lapsed:
            await store.update(record.reference) { $0.status = .expired }
        default:
            return
        }
    }

    private func confirm(_ hold: ToristyHold, receipt: PaymentReceipt) async throws -> ToristyConfirmedBooking {
        var lastError: Error?
        for attempt in 0..<confirmationAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * Double(attempt) * 1_000_000_000))
            }
            do {
                try await service.confirm(hold.reference, receipt: receipt, amount: hold.total, currency: hold.currency)
                return await markConfirmed(hold, receipt: receipt)
            } catch {
                lastError = error
                if let data = try? await service.bookingData(cartId: hold.reference.primary) {
                    if data.status == .confirmed { return await markConfirmed(hold, receipt: receipt) }
                    if data.status == .timedOut || data.status == .cancelled { break }
                }
                if isPermanent(error) { break }
            }
        }

        let reason = (lastError as? LocalizedError)?.errorDescription ?? lastError.map { String(describing: $0) } ?? "Toristy did not confirm the booking."
        await refund(hold.reference, receipt: receipt, reason: reason)
        throw BookingError.confirmationFailedAfterCharge(receipt: receipt, reference: hold.reference, reason: reason)
    }

    private nonisolated func isPermanent(_ error: Error) -> Bool {
        guard case BookingError.server(let status, _, _) = error else { return false }
        return (400..<500).contains(status) && status != 408 && status != 429
    }

    private func markConfirmed(_ hold: ToristyHold, receipt: PaymentReceipt) async -> ToristyConfirmedBooking {
        await store.update(hold.reference) {
            $0.status = .confirmed
            $0.providerStatus = "Confirmed"
        }
        return ToristyConfirmedBooking(reference: hold.reference, receipt: receipt, total: hold.total, currency: hold.currency)
    }

    private func refund(_ reference: BookingReference, receipt: PaymentReceipt, reason: String) async {
        guard let payment else {
            await store.update(reference) { $0.status = .needsRefund }
            return
        }
        do {
            try await payment.refund(receipt, reason: reason)
            await store.update(reference) { $0.status = .refunded }
        } catch {
            await store.update(reference) { $0.status = .needsRefund }
        }
    }

    private nonisolated func describe(_ status: ToristyPaymentStatus) -> String {
        switch status {
        case .confirmed: return "Confirmed"
        case .reserved: return "Reserved"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Timed Out"
        case .other(let raw): return raw
        }
    }
}
