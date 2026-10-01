import Foundation

/// An event with the ticket groups that can be sold in the app.
public struct VictoryEventOffers: Sendable, Hashable {
    public let event: VictoryEvent
    /// Groups with at least one sellable quantity, cheapest first.
    public let ticketGroups: [VictoryTicketGroup]
    /// Groups listed for the event that cannot be sold right now: no sellable quantity or no price, cheapest first.
    public var soldOutGroups: [VictoryTicketGroup] = []
    /// The fixed day of the event in the venue's time, `nil` while TE has none.
    public var eventDate: BookingDate? {
        event.occursAtLocal.flatMap { BookingDate(String($0.prefix(10))) }
    }
}

/// A ticket group and quantity priced with tax, ready to order.
public struct VictoryQuote: Sendable, Hashable {
    public let eventId: Int
    public let group: VictoryTicketGroup
    public let quantity: Int
    public let taxQuote: VictoryTaxQuote?
    public let subtotal: Decimal
    public let serviceFee: Decimal
    public let tax: Decimal
    /// What the card is charged, always in `currency`.
    public let total: Decimal
    public let currency: String
}

/// Where a Victory order ended up.
public struct VictoryOrderOutcome: Sendable, Hashable {
    public let reference: BookingReference
    public let order: VictoryOrder
    public let currency: String
}

/// Runs a Victory (Ticket Evolution) order: offers, quote, buyer, Braintree nonce, order, recovery.
///
/// Prices and the charge are USD. TE charges the card itself, so nothing is refunded on our side;
/// after a lost answer the order is looked up by our own `reference`. TE has no in-app
/// cancellation; refunds go through TE with the seller's approval.
public actor VictoryCheckout {

    public static let currency = "USD"

    private let service: VictoryBookingService
    private let store: BookingRecordStore
    private let backgroundTasks: BackgroundTaskRunning
    private let digitalOnly: Bool
    private let statusAttempts: Int
    private let retryDelay: TimeInterval
    private let now: @Sendable () -> Date

    /// - Parameter digitalOnly: offer only groups delivered by email, which keeps shipping out of the flow.
    public init(service: VictoryBookingService,
                store: BookingRecordStore,
                backgroundTasks: BackgroundTaskRunning = BookingConfiguration.defaultBackgroundTaskRunner,
                digitalOnly: Bool = true,
                statusAttempts: Int = 3,
                retryDelay: TimeInterval = 2,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.store = store
        self.backgroundTasks = backgroundTasks
        self.digitalOnly = digitalOnly
        self.statusAttempts = max(1, statusAttempts)
        self.retryDelay = retryDelay
        self.now = now
    }

    public func offers(eventId: Int) async throws -> VictoryEventOffers {
        async let event = service.event(id: eventId)
        async let groups = service.listings(eventId: eventId)
        let offered = try await groups
            .filter { !digitalOnly || $0.isDigital }
            .sorted { ($0.retailPrice ?? 0) < ($1.retailPrice ?? 0) }
        let isSellable: (VictoryTicketGroup) -> Bool = { !$0.sellableQuantities.isEmpty && $0.retailPrice != nil && $0.wholesalePrice != nil }
        var offers = VictoryEventOffers(event: try await event, ticketGroups: offered.filter(isSellable))
        offers.soldOutGroups = offered.filter { !isSellable($0) }
        return offers
    }

    /// Prices a group and quantity with TE's tax quote; the quantity must be one of `sellableQuantities`.
    public func quote(eventId: Int, group: VictoryTicketGroup, quantity: Int) async throws -> VictoryQuote {
        guard group.sellableQuantities.contains(quantity) else {
            let allowed = group.sellableQuantities.map(String.init).joined(separator: ", ")
            throw BookingError.invalidSelection(["These tickets are sold in quantities of \(allowed)."])
        }
        guard let unitPrice = group.retailPrice else { throw BookingError.rejected("These tickets have no price.") }
        let taxQuote = try await service.taxQuote(group: group, quantity: quantity)
        let subtotal = unitPrice * Decimal(quantity)
        let serviceFee = group.serviceFee ?? 0
        let tax = taxQuote.isUsable ? (taxQuote.retailTaxAmount ?? 0) : 0
        return VictoryQuote(eventId: eventId, group: group, quantity: quantity, taxQuote: taxQuote.isUsable ? taxQuote : nil,
                            subtotal: subtotal, serviceFee: serviceFee, tax: tax,
                            total: subtotal + serviceFee + tax, currency: Self.currency)
    }

    /// Creates the buyer, takes a nonce for the quoted total and places the order.
    ///
    /// A quote whose tax has expired is priced again first; when the new total differs the call
    /// throws `.rejected` so the customer sees the new price before paying.
    /// - Parameter sessionId: TE's fraud-screening session, when the account requires one.
    public func order(_ quote: VictoryQuote,
                      buyer: VictoryBuyer,
                      eventDate: BookingDate?,
                      activityId: String,
                      title: String,
                      payment: PaymentNonceProviding,
                      sessionId: String? = nil) async throws -> VictoryOrderOutcome {
        let current = try await refreshed(quote)
        let client = try await service.createClient(buyer)
        let nonce = try await payment.nonce(amount: current.total, currency: current.currency)
        let request = try VictoryOrderRequest(client: client, group: current.group, quantity: current.quantity, paymentToken: nonce,
                                              taxQuote: current.taxQuote, reference: UUID().uuidString, sessionId: sessionId)
        let reference = BookingReference(provider: .victory, primary: request.order.reference)
        await store.save(BookingRecord(reference: reference, activityId: activityId, title: title, travelDate: eventDate,
                                       status: .charged, total: current.total, currency: current.currency, providerStatus: "ORDERING"))
        return try await backgroundTasks.run(named: "trp.booking.victory.order") {
            try await self.submit(request, reference: reference)
        }
    }

    public func status(of reference: BookingReference) async throws -> VictoryOrder? {
        let order: VictoryOrder?
        if let orderId = reference.secondary {
            order = try await service.order(id: orderId)
        } else {
            order = try await service.orders(reference: reference.primary).first
        }
        if let order { await mirror(order, into: reference) }
        return order
    }

    /// Looks up orders whose answer was lost or that are still pending.
    public func resolveUnfinished() async -> [BookingRecord] {
        let open = await store.all().filter { $0.reference.provider == .victory && ($0.status == .charged || $0.status == .pending) }
        for record in open {
            _ = try? await status(of: record.reference)
        }
        return await store.all().filter { $0.reference.provider == .victory }
    }

    private func submit(_ request: VictoryOrderRequest, reference: BookingReference) async throws -> VictoryOrderOutcome {
        let order: VictoryOrder
        do {
            order = try await service.placeOrder(request)
        } catch let error as BookingError where isPermanent(error) {
            await store.update(reference) { $0.status = .failed }
            throw error
        } catch {
            guard let found = await probe(reference) else { throw BookingError.outcomeUnknown(reference: reference) }
            order = found
        }
        let placed = await mirror(order, into: reference)
        switch order.state {
        case .rejected, .cancelled:
            throw BookingError.rejected("The order was \(order.rawState ?? "rejected").")
        case .pending, .accepted, .completed, .other:
            return VictoryOrderOutcome(reference: placed, order: order, currency: Self.currency)
        }
    }

    private func refreshed(_ quote: VictoryQuote) async throws -> VictoryQuote {
        guard let taxQuote = quote.taxQuote, taxQuote.isExpired(at: now()) else { return quote }
        let fresh = try await self.quote(eventId: quote.eventId, group: quote.group, quantity: quote.quantity)
        guard fresh.total == quote.total else {
            throw BookingError.rejected("The price changed to \(fresh.total) \(fresh.currency). Please review it before paying.")
        }
        return fresh
    }

    private func probe(_ reference: BookingReference) async -> VictoryOrder? {
        for attempt in 0..<statusAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * Double(attempt) * 1_000_000_000))
            }
            if let orders = try? await service.orders(reference: reference.primary) {
                return orders.first
            }
        }
        return nil
    }

    @discardableResult
    private func mirror(_ order: VictoryOrder, into reference: BookingReference) async -> BookingReference {
        let placed = BookingReference(provider: .victory, primary: reference.primary, secondary: order.id)
        guard var record = await store.record(for: reference) else { return placed }
        record = BookingRecord(reference: placed, activityId: record.activityId, title: record.title, travelDate: record.travelDate,
                               status: order.state.recordStatus ?? record.status, total: order.total ?? record.total,
                               currency: record.currency, deadline: record.deadline, receipt: record.receipt,
                               providerStatus: order.rawState ?? record.providerStatus, createdAt: record.createdAt,
                               contractBooking: record.contractBooking)
        await store.save(record)
        return placed
    }

    private nonisolated func isPermanent(_ error: BookingError) -> Bool {
        guard case .server(let status, _, _) = error else { return false }
        return (400..<500).contains(status) && status != 408 && status != 429
    }
}
