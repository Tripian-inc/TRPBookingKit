import Foundation

/// Ticket Evolution behind the contract: seats, quantity, summary and buyer, then a Braintree Drop-in.
///
/// TE holds nothing before the order, so a group that sold out meanwhile is found when the quantity is
/// submitted and the customer is sent back to the seats. The order ends `pending` until TE accepts it,
/// and TE orders cannot be cancelled in the app.
final class VictoryCheckoutFlow: ProviderCheckoutFlow {
    typealias BC = BookingContract

    var snapshot = FlowSnapshot()
    private let context: FlowContext
    private let victory: VictoryCheckout
    private let braintree: BraintreeClientTokenProviding
    private var answers = StepAnswers()
    private var eventId = 0
    private var offers: VictoryEventOffers?
    private var group: VictoryTicketGroup?
    private var quote: VictoryQuote?
    private var buyer: VictoryBuyer?
    private var soldOutNotice = false

    private static let steps = ["group", "quantity", "summary", "buyer"]
    private static let unitId = "TICKET"
    private static let states = [("NY", "New York"), ("NJ", "New Jersey"), ("CA", "California")]

    init(context: FlowContext, victory: VictoryCheckout, braintree: BraintreeClientTokenProviding) {
        self.context = context
        self.victory = victory
        self.braintree = braintree
    }

    func start() async throws {
        guard let eventId = Int(context.product.providerProductId) else { throw FlowRejection.supplierUnavailable(retryable: false) }
        self.eventId = eventId
        offers = try await victory.offers(eventId: eventId)
        show("group")
    }

    func submit(answers submitted: BC.Answers, expectedAmount: BC.Money?) async throws {
        guard let stepId = snapshot.step?.id else { throw FlowRejection.stepMismatch }
        switch stepId {
        case "group": try submitGroup(submitted)
        case "quantity": try await submitQuantity(submitted)
        case "summary": break
        default: try submitBuyer(submitted, expectedAmount: expectedAmount)
        }
        answers.record(submitted, for: stepId)
        if stepId == "buyer" {
            try await offerPayment()
        } else {
            show(Self.steps[(Self.steps.firstIndex(of: stepId) ?? 0) + 1])
        }
    }

    func back() async throws {
        guard let stepId = snapshot.backStepId(in: Self.steps) else { throw FlowRejection.stepMismatch }
        show(stepId)
    }

    func act(result: BC.ActionResult) async throws {
        if result.status?.value == .canceled { return }
        guard let quote, let buyer else { throw FlowRejection.stepMismatch }
        guard let nonce = result.nonce, !nonce.isEmpty else {
            try await offerPayment()
            throw FlowRejection.paymentDeclined
        }
        snapshot.status = .processing
        snapshot.nextAction = nil
        snapshot.allowed = []
        do {
            let outcome = try await victory.order(quote, buyer: buyer, eventDate: offers?.eventDate, activityId: context.product.id,
                                                  title: context.product.title, payment: FixedNonce(nonce: nonce))
            await finish(outcome)
        } catch BookingError.paymentFailed, BookingError.paymentCancelled {
            try await offerPayment()
            throw FlowRejection.paymentDeclined
        } catch BookingError.rejected(let message) where message.hasPrefix("The price changed") {
            self.quote = try? await victory.quote(eventId: eventId, group: quote.group, quantity: quote.quantity)
            if let fresh = self.quote { snapshot.amount = LocalFormat.money(fresh.total, fresh.currency) }
            show("summary")
            throw FlowRejection.priceChanged
        } catch BookingError.rejected {
            fail()
        } catch {
            try await offerPayment()
            throw FlowRejection.from(error)
        }
    }

    func cancel() async {}

    func expire() async {}

    private func finish(_ outcome: VictoryOrderOutcome) async {
        let confirmed = outcome.order.state == .accepted || outcome.order.state == .completed
        snapshot.status = confirmed ? .confirmed : .pending
        snapshot.clearHold()
        snapshot.priceValidUntil = nil
        snapshot.bookingStatus = confirmed ? .confirmed : .pending
        snapshot.result = confirmed
            ? BC.CheckoutResult(title: LocalBlocks.confirmedResult.title, message: LocalBlocks.confirmedResult.message,
                                bookingUuid: context.bookingUuid)
            : BC.CheckoutResult(title: "Awaiting confirmation",
                                message: "Ticket Evolution is confirming your order. We will let you know by push notification and email.",
                                bookingUuid: context.bookingUuid)
        let contract = contractBooking(outcome, confirmed: confirmed)
        await context.store.update(outcome.reference) { $0.contractBooking = contract }
    }

    private func fail() {
        snapshot.status = .failed
        snapshot.clearHold()
        snapshot.priceValidUntil = nil
        snapshot.bookingStatus = .rejected
        snapshot.result = BC.CheckoutResult(title: "Your order could not be completed",
                                            message: "Ticket Evolution did not accept this order. Your card was not charged.",
                                            bookingUuid: context.bookingUuid)
    }

    private func submitGroup(_ submitted: BC.Answers) throws {
        guard let value = submitted.string("group"), let chosen = offers?.ticketGroups.first(where: { Self.optionId($0) == value }) else {
            throw FlowRejection.validation([BC.ErrorData.FieldError(field: "group", message: "Choose available seats.")])
        }
        if chosen != group { quote = nil }
        group = chosen
        soldOutNotice = false
        snapshot.optionId = value
    }

    private func submitQuantity(_ submitted: BC.Answers) async throws {
        guard let group else { throw FlowRejection.stepMismatch }
        let quantity = submitted.units("units")[Self.unitId] ?? 0
        guard group.sellableQuantities.contains(quantity) else {
            let allowed = group.sellableQuantities.map(String.init).joined(separator: ", ")
            throw FlowRejection.validation([BC.ErrorData.FieldError(field: "units", message: "These tickets are sold in quantities of \(allowed).")])
        }
        let current = try await victory.offers(eventId: eventId)
        offers = current
        guard let available = current.ticketGroups.first(where: { $0.id == group.id }), available.sellableQuantities.contains(quantity) else {
            self.group = nil
            quote = nil
            snapshot.optionId = nil
            snapshot.amount = nil
            snapshot.priceValidUntil = nil
            soldOutNotice = true
            show("group")
            throw FlowRejection.soldOut
        }
        self.group = available
        let priced: VictoryQuote
        do {
            priced = try await victory.quote(eventId: eventId, group: available, quantity: quantity)
        } catch {
            throw FlowRejection.from(error)
        }
        quote = priced
        snapshot.amount = LocalFormat.money(priced.total, priced.currency)
        snapshot.priceValidUntil = priced.taxQuote?.expiresAt
    }

    private func submitBuyer(_ submitted: BC.Answers, expectedAmount: BC.Money?) throws {
        if let expectedAmount, let current = snapshot.amount,
           LocalFormat.decimal(expectedAmount) != LocalFormat.decimal(current) || expectedAmount.currency != current.currency {
            throw FlowRejection.priceChanged
        }
        var errors = LocalBlocks.contactErrors("buyer", in: submitted)
        errors += LocalValidation.required([("billing.address1", "Enter the billing address."), ("billing.city", "Enter the city."),
                                            ("billing.postalCode", "Enter the postal code."), ("billing.country", "Choose the country.")],
                                           in: submitted)
        let country = submitted.string("billing.country") ?? "US"
        if country == "US" {
            errors += LocalValidation.required([("billing.state", "Choose the state.")], in: submitted)
        }
        if let consent = LocalValidation.consent("terms", in: submitted) { errors.append(consent) }
        guard errors.isEmpty else { throw FlowRejection.validation(errors) }
        let name = [submitted.string("buyer.firstName"), submitted.string("buyer.lastName")].compactMap { $0 }.joined(separator: " ")
        let phone = submitted.string("buyer.phone")
        buyer = VictoryBuyer(name: name, email: submitted.string("buyer.email") ?? "",
                             phoneNumber: phone.map { Self.nationalNumber($0) }, phoneCountryCode: phone.flatMap(Self.countryCode),
                             billingAddress: VictoryBuyer.Address(streetAddress: submitted.string("billing.address1") ?? "",
                                                                  locality: submitted.string("billing.city") ?? "",
                                                                  region: country == "US" ? submitted.string("billing.state") : nil,
                                                                  postalCode: submitted.string("billing.postalCode") ?? "",
                                                                  countryCode: country))
    }

    private func offerPayment() async throws {
        guard let quote else { throw FlowRejection.stepMismatch }
        let clientToken: String
        do {
            clientToken = try await braintree.clientToken()
        } catch {
            throw FlowRejection.supplierUnavailable(retryable: true)
        }
        snapshot.status = .awaitingPayment
        snapshot.step = nil
        snapshot.paymentStepId = Self.steps.last
        snapshot.allowed = [.back, .cancel]
        snapshot.nextAction = .braintreeDropin(BC.NextAction.Payload(
            id: context.identifiers.next("act_"),
            params: BC.BraintreeDropinParams(clientToken: clientToken, amount: LocalFormat.money(quote.total, quote.currency)),
            expiresAt: snapshot.priceValidUntil.map(LocalFormat.iso)))
    }

    private func show(_ stepId: String) {
        snapshot.status = .collectingDetails
        snapshot.nextAction = nil
        snapshot.allowed = stepId == "group" ? [.submit, .cancel] : [.submit, .back, .cancel]
        let count: Int? = quote == nil ? nil : Self.steps.count
        let index = (Self.steps.firstIndex(of: stepId) ?? 0) + 1
        switch stepId {
        case "group":
            var blocks = [groupBlock]
            if soldOutNotice {
                blocks.append(LocalBlocks.notice("sold-out", .warning, "The seats you chose are no longer available. Please choose other seats.",
                                                 skippable: false))
            }
            snapshot.step = LocalBlocks.step("group", "Choose your seats", subtitle: eventLine, index: index, count: count, blocks: blocks)
        case "quantity":
            snapshot.step = LocalBlocks.step("quantity", "How many tickets?", index: index, count: count, blocks: [quantityBlock])
        case "summary":
            snapshot.step = LocalBlocks.step("summary", "Summary", index: index, count: count, blocks: [
                summaryBlock,
                LocalBlocks.notice("final-sale", .warning, "All sales are final. Tickets cannot be cancelled in the app.")
            ])
        default:
            snapshot.step = LocalBlocks.step("buyer", "Buyer and billing", index: index, count: count, blocks: buyerBlocks,
                                             primary: LocalBlocks.paymentAction)
        }
    }

    /// Every listed group, most expensive first, with the ones that cannot be sold disabled.
    private var groupBlock: BC.Block {
        let available = offers?.ticketGroups ?? []
        let groups = (available + (offers?.soldOutGroups ?? [])).sorted { ($0.retailPrice ?? 0) > ($1.retailPrice ?? 0) }
        let bestValue = available.count > 1 ? available.min { ($0.retailPrice ?? 0) < ($1.retailPrice ?? 0) } : nil
        let options = groups.map { candidate -> BC.ChoiceBlock.Option in
            let sellable = available.contains { $0.id == candidate.id }
            return BC.ChoiceBlock.Option(value: Self.optionId(candidate), title: Self.title(candidate),
                                         subtitle: sellable ? "Seats together" : "Sold out",
                                         price: candidate.retailPrice.map { LocalFormat.money($0, VictoryCheckout.currency) },
                                         badge: candidate.id == bestValue?.id ? "Best value" : nil,
                                         disabled: sellable ? nil : true)
        }
        return .choice(BC.ChoiceBlock(id: "group", options: options, multiple: false,
                                      defaultValue: group.map { .single(Self.optionId($0)) }))
    }

    private var quantityBlock: BC.Block {
        let quantities = group?.sellableQuantities ?? []
        let minimum = quantities.first ?? 1
        let maximum = quantities.last ?? minimum
        let item = BC.QuantityBlock.Item(unitId: Self.unitId, title: "Tickets", subtitle: group.map(Self.title),
                                         price: group?.retailPrice.map { LocalFormat.money($0, VictoryCheckout.currency) },
                                         min: minimum, max: maximum, allowed: quantities)
        let defaults = answers.byStep["quantity"]?.units("units")
        return .quantity(BC.QuantityBlock(id: "units", items: [item], total: BC.QuantityBlock.Total(min: minimum, max: maximum),
                                          defaultValue: defaults))
    }

    private var summaryBlock: BC.Block {
        guard let quote else {
            return .summary(BC.SummaryBlock(id: "summary", lines: [], total: LocalFormat.money(0, VictoryCheckout.currency), note: eventLine))
        }
        var lines = [BC.SummaryBlock.Line(title: "\(quote.quantity) × \(Self.title(quote.group))",
                                          amount: LocalFormat.money(quote.subtotal, quote.currency))]
        if quote.serviceFee > 0 {
            lines.append(BC.SummaryBlock.Line(title: "Service fees", amount: LocalFormat.money(quote.serviceFee, quote.currency)))
        }
        if quote.tax > 0 {
            lines.append(BC.SummaryBlock.Line(title: "Taxes", amount: LocalFormat.money(quote.tax, quote.currency)))
        }
        return .summary(BC.SummaryBlock(id: "summary", lines: lines, total: LocalFormat.money(quote.total, quote.currency), note: eventLine))
    }

    private var buyerBlocks: [BC.Block] {
        var blocks = LocalBlocks.contact("buyer", defaults: answers)
        blocks.append(LocalBlocks.text("billing.address1", "Billing address", autofill: "streetAddressLine1", defaults: answers))
        blocks.append(LocalBlocks.text("billing.city", "City", autofill: "addressCity", defaults: answers))
        blocks.append(LocalBlocks.text("billing.postalCode", "Postal code", autofill: "postalCode", defaults: answers))
        blocks.append(.field(.country(BC.FieldSpec(id: "billing.country", label: "Country", required: true, scope: .init(.booking),
                                                   defaultValue: answers.string("billing.country") ?? "US"))))
        blocks.append(.field(.select(BC.FieldSpec(
            id: "billing.state", control: "dropdown", label: "State", required: true, scope: .init(.booking),
            options: Self.states.map { BC.FieldOption(value: $0.0, title: $0.1) }, defaultValue: answers.string("billing.state"),
            visibleWhen: .all([BC.Condition.Clause(field: "billing.country", op: .in, values: [.string("US")])])))))
        blocks.append(LocalBlocks.terms("I accept Ticket Evolution's terms of sale.",
                                        link: BC.ConsentBlock.Link(title: "Terms of sale", url: "https://www.ticketevolution.com/terms")))
        return blocks
    }

    /// The event's day, start time and venue as one line, e.g. "15 October 2026, 19:00 · Richard Rodgers Theatre".
    private var eventLine: String? {
        guard let event = offers?.event else { return nil }
        let day = offers?.eventDate.map(LocalFormat.longDate)
        let time = event.isTimeToBeAnnounced ? "time TBA" : event.occursAtLocal.map { String($0.dropFirst(11).prefix(5)) }
        let when = [day, time].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        let line = [when, event.venue?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    private func contractBooking(_ outcome: VictoryOrderOutcome, confirmed: Bool) -> BC.Booking {
        let event = offers?.event
        let time = event?.isTimeToBeAnnounced == false ? event?.occursAtLocal.map { String($0.dropFirst(11).prefix(5)) } : nil
        return BC.Booking(
            uuid: context.bookingUuid, status: .init(confirmed ? .confirmed : .pending), provider: "victory",
            providerReference: outcome.reference.secondary ?? outcome.order.id,
            product: BC.Product(id: context.product.id, optionId: snapshot.optionId, title: context.product.title,
                                imageUrl: context.product.imageUrl),
            units: [Self.unitId: quote?.quantity ?? 0],
            start: BC.Booking.Start(date: offers?.eventDate?.description ?? "", time: time,
                                    timezone: (event?.venue?.timeZone ?? context.product.timeZone).identifier),
            durationMinutes: context.product.duration(option: snapshot.optionId), meetingPoint: context.product.meetingPoint,
            amount: LocalFormat.money(outcome.order.total ?? quote?.total ?? 0, outcome.currency), utcExpiresAt: nil, vouchers: [],
            cancellation: BC.Booking.Cancellation(allowed: false, deadline: nil, refund: .init(.none), refundAmount: nil),
            refund: nil,
            contact: BC.Booking.Contact(name: buyer?.name ?? "", email: buyer?.email ?? ""))
    }

    private static func optionId(_ group: VictoryTicketGroup) -> String {
        "TG_\(group.id)"
    }

    private static func title(_ group: VictoryTicketGroup) -> String {
        [group.section, group.row.map { "Row \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    private static func countryCode(_ phone: String) -> String? {
        phone.hasPrefix("+1") ? "1" : nil
    }

    private static func nationalNumber(_ phone: String) -> String {
        phone.hasPrefix("+1") ? String(phone.dropFirst(2)) : phone
    }
}

/// Hands TE the nonce the Drop-in produced on the client.
private struct FixedNonce: PaymentNonceProviding {
    let nonce: String

    func nonce(amount: Decimal, currency: String) async throws -> String {
        nonce
    }
}
