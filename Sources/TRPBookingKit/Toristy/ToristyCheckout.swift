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
public actor ToristyCheckout {

    /// How long a cart lives when `bookingdata` does not say.
    public static let defaultCartLifetime: TimeInterval = 30 * 60

    private let service: ToristyBookingService
    private let payment: PaymentProcessing
    private let store: BookingRecordStore
    private let backgroundTasks: BackgroundTaskRunning
    private let validator: ToristySelectionValidator
    private let confirmationAttempts: Int
    private let retryDelay: TimeInterval
    private let now: @Sendable () -> Date

    public init(service: ToristyBookingService,
                payment: PaymentProcessing,
                store: BookingRecordStore,
                backgroundTasks: BackgroundTaskRunning = BookingConfiguration.defaultBackgroundTaskRunner,
                validator: ToristySelectionValidator = ToristySelectionValidator(),
                confirmationAttempts: Int = 3,
                retryDelay: TimeInterval = 2,
                now: @escaping @Sendable () -> Date = { Date() }) {
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
    /// Throws `.holdExpired` before charging a cart past its deadline, and
    /// `.confirmationFailedAfterCharge` when the money was taken but the booking not confirmed.
    public func pay(_ hold: ToristyHold, customerEmail: String?) async throws -> ToristyConfirmedBooking {
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

    /// Retries confirmation or the refund of records a previous run left charged but unconfirmed.
    public func resolveUnfinished() async -> [BookingRecord] {
        for record in await store.unresolved() where record.reference.provider == .toristy {
            guard let receipt = record.receipt else { continue }
            if let data = try? await service.bookingData(cartId: record.reference.primary), data.status == .confirmed {
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
            await refund(record.reference, receipt: receipt, reason: "Toristy did not confirm the booking.")
        }
        return await store.all().filter { $0.reference.provider == .toristy }
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
