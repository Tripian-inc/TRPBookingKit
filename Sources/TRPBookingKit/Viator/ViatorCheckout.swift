import Foundation

/// Everything the Viator booking form needs about one product, fetched together.
public struct ViatorProductContext: Sendable {
    public let product: ViatorProduct
    public let calendar: ViatorAvailabilityCalendar
    /// Only the questions this product asks, resolved from the cached dictionary.
    public let questions: [ViatorBookingQuestion]
    /// Pickup, start and end locations, keyed by `reference`.
    public let locations: [String: ViatorLocation]

    public var pickupLocations: [ViatorLocation] {
        product.pickupLocationRefs.compactMap { locations[$0] }
    }
}

/// A Viator cart held for the customer, waiting for payment on Viator's form.
public struct ViatorCheckoutHold: Sendable, Hashable {
    public let reference: BookingReference
    public let cartRef: String
    public let bookingRef: String
    public let item: ViatorHoldItem
    /// The retail price to show; Viator charges exactly this.
    public let total: Decimal?
    public let currency: String
    public let deadline: BookingDeadline
    /// Initialises the hosted payment form; kept in memory only.
    public let paymentSessionToken: String
    public let activityId: String
    public let title: String
}

/// Where a Viator booking ended up after `cart/book`.
public struct ViatorBookingOutcome: Sendable, Hashable {
    public let reference: BookingReference
    public let status: ViatorBookingStatus
    public let total: Decimal?
    public let currency: String
    public let voucher: ViatorVoucher?
    public let cancellationPolicy: ViatorCancellationPolicy?
}

/// Supplies the one-time payment token Viator's hosted form produces for a hold.
public protocol ViatorPaymentTokenProviding: Sendable {
    /// Throws `BookingError.paymentCancelled` when the customer closes the form.
    func paymentToken(for hold: ViatorCheckoutHold) async throws -> String
}

/// Runs a Viator booking: context, availability, hold, payment on Viator's form, book, and recovery.
///
/// Viator charges the card itself, so there is nothing to refund on our side; after a lost answer
/// the booking is probed through `bookings/status` before anyone assumes it failed.
public actor ViatorCheckout {

    /// How long a hold lives when Viator does not say.
    public static let defaultHoldLifetime: TimeInterval = 10 * 60

    /// The app language, used to choose a guide language where the product offers several.
    public let languageCode: String
    private let service: ViatorBookingService
    private let store: BookingRecordStore
    private let backgroundTasks: BackgroundTaskRunning
    private let validator: ViatorSelectionValidator
    private let maximumHolds: Int
    private let statusAttempts: Int
    private let retryDelay: TimeInterval
    private let now: @Sendable () -> Date
    private var questionDictionary: [String: ViatorBookingQuestion]?
    private var holdCounts: [String: Int] = [:]

    public init(service: ViatorBookingService,
                store: BookingRecordStore,
                languageCode: String = "en",
                backgroundTasks: BackgroundTaskRunning = BookingConfiguration.defaultBackgroundTaskRunner,
                validator: ViatorSelectionValidator = ViatorSelectionValidator(),
                maximumHolds: Int = 3,
                statusAttempts: Int = 3,
                retryDelay: TimeInterval = 2,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.store = store
        self.languageCode = languageCode
        self.backgroundTasks = backgroundTasks
        self.validator = validator
        self.maximumHolds = max(1, maximumHolds)
        self.statusAttempts = max(1, statusAttempts)
        self.retryDelay = retryDelay
        self.now = now
    }

    /// Fetches the product, its schedule, its questions and its locations.
    public func context(productCode: String) async throws -> ViatorProductContext {
        async let product = service.product(code: productCode)
        async let schedule = service.schedule(productCode: productCode)
        let loadedProduct = try await product
        let loadedSchedule = try await schedule
        let dictionary = try await questions()
        let locations = (try? await service.locations(refs: loadedProduct.locationRefs)) ?? []
        return ViatorProductContext(
            product: loadedProduct,
            calendar: ViatorAvailabilityCalendar(schedule: loadedSchedule, timeZone: loadedProduct.timeZone),
            questions: loadedProduct.bookingQuestionIds.compactMap { dictionary[$0] },
            locations: Dictionary(locations.map { ($0.reference, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }

    /// Every option and start time for the party on a date, after checking the party locally.
    public func availability(for context: ViatorProductContext, on date: BookingDate, paxMix: [ViatorPax], currency: String) async throws -> ViatorAvailability {
        try validator.validate(paxMix, product: context.product)
        return try await service.availability(productCode: context.product.productCode, travelDate: date, currency: currency, paxMix: paxMix)
    }

    /// Holds one option and start time, with fresh partner refs on every attempt.
    ///
    /// Throws `.tooManyHolds` after `maximumHolds` for the same selection and `.holdRejected`
    /// when Viator will not hold it.
    public func hold(_ item: ViatorHoldItem, currency: String, activityId: String, title: String) async throws -> ViatorCheckoutHold {
        let key = "\(item.productCode)|\(item.productOptionCode)|\(item.startTime ?? "")|\(item.travelDate)"
        guard holdCounts[key, default: 0] < maximumHolds else { throw BookingError.tooManyHolds }
        holdCounts[key, default: 0] += 1

        let cart = try await service.hold(item, currency: currency, partnerCartRef: UUID().uuidString, partnerBookingRef: UUID().uuidString)
        guard let held = cart.items.first else { throw BookingError.holdRejected(code: nil) }
        guard held.isBookable else { throw BookingError.holdRejected(code: held.rejectionReasonCode) }
        guard let sessionToken = cart.paymentSessionToken, !sessionToken.isEmpty else {
            throw BookingError.rejected("Viator returned no payment session.")
        }

        let reference = BookingReference(provider: .viator, primary: held.bookingRef, secondary: cart.cartRef)
        let deadline = held.deadline ?? BookingDeadline(expiresAt: now().addingTimeInterval(Self.defaultHoldLifetime))
        let total = held.itemTotalPrice?.recommendedRetailPrice ?? cart.totalHeldPrice?.recommendedRetailPrice
        let resolvedCurrency = cart.currency.isEmpty ? currency.uppercased() : cart.currency

        await store.save(BookingRecord(
            reference: reference,
            activityId: activityId,
            title: title,
            travelDate: item.travelDate,
            status: .held,
            total: total,
            currency: resolvedCurrency,
            deadline: deadline,
            providerStatus: held.status,
            createdAt: now()
        ))
        return ViatorCheckoutHold(reference: reference, cartRef: cart.cartRef, bookingRef: held.bookingRef, item: item,
                                  total: total, currency: resolvedCurrency, deadline: deadline,
                                  paymentSessionToken: sessionToken, activityId: activityId, title: title)
    }

    /// Checks the answers, collects the payment token and books the hold.
    ///
    /// Throws `.holdExpired` for a hold past its deadline and `.outcomeUnknown` when neither the
    /// booking call nor the status probe answered; the record then stays `.charged` for `resolveUnfinished()`.
    public func book(_ hold: ViatorCheckoutHold,
                     details: ViatorBookerDetails,
                     context: ViatorProductContext,
                     payment: ViatorPaymentTokenProviding) async throws -> ViatorBookingOutcome {
        let travelerCount = hold.item.paxMix.reduce(0) { $0 + $1.numberOfTravelers }
        try validator.validate(details, product: context.product, questions: context.questions, travelerCount: travelerCount)
        try await ensureAlive(hold)
        let token = try await payment.paymentToken(for: hold)
        try await ensureAlive(hold)

        return try await backgroundTasks.run(named: "trp.booking.viator.book") {
            try await self.submit(hold, details: details, paymentToken: token)
        }
    }

    /// Asks Viator where the booking stands and mirrors it into the record.
    public func status(of reference: BookingReference) async throws -> ViatorBookingStatus {
        let result = try await service.status(bookingRef: reference.primary)
        await mirror(result.status, raw: result.rawStatus, into: reference)
        return result.status
    }

    /// What the customer gets back if they cancel now.
    public func cancelQuote(_ reference: BookingReference) async throws -> ViatorCancelQuote {
        try await ensureCancellable(reference)
        return try await service.cancelQuote(bookingRef: reference.primary)
    }

    /// Cancels a booking; show `cancelQuote` first. Throws `.notCancellable` when Viator declines.
    public func cancel(_ reference: BookingReference) async throws -> ViatorCancellation {
        try await ensureCancellable(reference)
        let result = try await service.cancel(bookingRef: reference.primary)
        guard result.isAccepted else {
            throw BookingError.notCancellable(result.reason ?? "Viator declined the cancellation.")
        }
        await store.update(reference) {
            $0.status = .cancelled
            $0.providerStatus = result.status
        }
        return result
    }

    /// Probes bookings a previous run left pending or unanswered, and expires stale holds.
    public func resolveUnfinished() async -> [BookingRecord] {
        for record in await store.all() where record.reference.provider == .viator {
            switch record.status {
            case .charged, .pending:
                _ = try? await status(of: record.reference)
            case .held where record.deadline?.isExpired(at: now()) ?? true:
                await store.update(record.reference) { $0.status = .expired }
            default:
                break
            }
        }
        return await store.all().filter { $0.reference.provider == .viator }
    }

    private func submit(_ hold: ViatorCheckoutHold, details: ViatorBookerDetails, paymentToken: String) async throws -> ViatorBookingOutcome {
        await store.update(hold.reference) {
            $0.status = .charged
            $0.providerStatus = "BOOKING"
        }
        let result: ViatorBookResult
        do {
            result = try await service.book(cartRef: hold.cartRef, bookingRef: hold.bookingRef, details: details, paymentToken: paymentToken)
        } catch let error as BookingError where isPermanent(error) {
            await store.update(hold.reference) { $0.status = .failed }
            throw error
        } catch {
            guard let status = await probe(hold.reference) else {
                throw BookingError.outcomeUnknown(reference: hold.reference)
            }
            return try outcome(hold, status: status, item: nil, result: nil)
        }

        let item = result.items.first { $0.bookingRef == hold.bookingRef } ?? result.items.first
        let status = item?.status ?? .other("")
        await mirror(status, raw: item?.rawStatus, into: hold.reference)
        holdCounts = [:]
        return try outcome(hold, status: status, item: item, result: result)
    }

    private func outcome(_ hold: ViatorCheckoutHold, status: ViatorBookingStatus,
                         item: ViatorBookedItem?, result: ViatorBookResult?) throws -> ViatorBookingOutcome {
        switch status {
        case .confirmed, .pending:
            return ViatorBookingOutcome(reference: hold.reference, status: status,
                                        total: item?.itemTotalPrice?.recommendedRetailPrice ?? hold.total,
                                        currency: result?.currency ?? hold.currency,
                                        voucher: item?.voucher ?? result?.voucher,
                                        cancellationPolicy: item?.cancellationPolicy)
        case .rejected, .failed, .cancelled:
            throw BookingError.rejected("Viator could not complete the booking.")
        case .other:
            throw BookingError.outcomeUnknown(reference: hold.reference)
        }
    }

    private func probe(_ reference: BookingReference) async -> ViatorBookingStatus? {
        for attempt in 0..<statusAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * Double(attempt) * 1_000_000_000))
            }
            if let status = try? await status(of: reference) { return status }
        }
        return nil
    }

    private func mirror(_ status: ViatorBookingStatus, raw: String?, into reference: BookingReference) async {
        await store.update(reference) { record in
            if let raw { record.providerStatus = raw }
            if let mapped = status.recordStatus { record.status = mapped }
        }
    }

    private func ensureAlive(_ hold: ViatorCheckoutHold) async throws {
        guard hold.deadline.isExpired(at: now()) else { return }
        await store.update(hold.reference) { $0.status = .expired }
        throw BookingError.holdExpired
    }

    private func ensureCancellable(_ reference: BookingReference) async throws {
        guard let record = await store.record(for: reference) else { return }
        if let travelDate = record.travelDate, travelDate <= BookingDate(date: now()) {
            throw BookingError.notCancellable("Only future bookings can be cancelled.")
        }
        guard record.status == .confirmed || record.status == .pending else {
            throw BookingError.notCancellable("This booking is not active.")
        }
    }

    private func questions() async throws -> [String: ViatorBookingQuestion] {
        if let questionDictionary { return questionDictionary }
        let loaded = try await service.bookingQuestions()
        let dictionary = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        questionDictionary = dictionary
        return dictionary
    }

    private nonisolated func isPermanent(_ error: BookingError) -> Bool {
        guard case .server(let status, _, _) = error else { return false }
        return (400..<500).contains(status) && status != 408 && status != 429
    }
}
