import Foundation

/// Ticket Evolution behind the contract with the purchase made on TE's hosted checkout page.
///
/// The customer picks a ticket group and a quantity; the quantity step offers TE's page as a `provider_hosted_cart`
/// action with `settlement: .handOff`. TE reports nothing back and the kit places no order, so the checkout ends
/// `handed_off` when the host reports that the customer left the page, and no booking record is kept.
final class VictoryHostedCheckoutFlow: ProviderCheckoutFlow {
    typealias BC = BookingContract

    var snapshot = FlowSnapshot()
    private let context: FlowContext
    private let victory: VictoryCheckout
    private let hosted: VictoryHostedCheckout
    private var answers = StepAnswers()
    private var eventId = 0
    private var event: VictoryEvent?
    private var groups: [VictoryTicketGroup] = []
    private var group: VictoryTicketGroup?

    private static let steps = ["tickets", "quantity"]
    private static let unitId = "TICKET"
    static let timeToBeAnnounced = "Time to be announced"
    static let handedOffResult = (title: "Continued on Ticket Evolution",
                                  message: "If you completed the purchase on Ticket Evolution's page, it is confirmed there.")

    init(context: FlowContext, victory: VictoryCheckout, hosted: VictoryHostedCheckout) {
        self.context = context
        self.victory = victory
        self.hosted = hosted
    }

    func start() async throws {
        guard let eventId = Int(context.product.providerProductId) else { throw FlowRejection.supplierUnavailable(retryable: false) }
        self.eventId = eventId
        let listed = try await victory.listedGroups(eventId: eventId)
        event = listed.event
        groups = listed.groups
        show("tickets")
    }

    func submit(answers submitted: BC.Answers, expectedAmount: BC.Money?) async throws {
        guard let stepId = snapshot.step?.id else { throw FlowRejection.stepMismatch }
        switch stepId {
        case "tickets":
            try submitGroup(submitted)
            answers.record(submitted, for: stepId)
            show("quantity")
        default:
            let quantity = try submitQuantity(submitted)
            answers.record(submitted, for: stepId)
            offerPage(quantity: quantity)
        }
    }

    func back() async throws {
        guard let stepId = snapshot.backStepId(in: Self.steps) else { throw FlowRejection.stepMismatch }
        show(stepId)
    }

    /// Ends the checkout `handed_off` when the customer left TE's page, or `cancelled` when they backed out of it.
    func act(result: BC.ActionResult) async throws {
        switch result.status?.value {
        case .handedOff?:
            finish(.handedOff)
            snapshot.result = BC.CheckoutResult(title: Self.handedOffResult.title, message: Self.handedOffResult.message,
                                                bookingUuid: nil)
        case .canceled?:
            finish(.cancelled)
        default:
            throw FlowRejection.stepMismatch
        }
    }

    func cancel() async {}

    func expire() async {}

    private func finish(_ status: BC.CheckoutStatus) {
        snapshot.status = status
        snapshot.clearHold()
        snapshot.step = nil
        snapshot.nextAction = nil
        snapshot.allowed = []
    }

    private func submitGroup(_ submitted: BC.Answers) throws {
        guard let value = submitted.string("tickets"),
              let chosen = groups.first(where: { Self.optionId($0) == value }), !chosen.sellableQuantities.isEmpty else {
            throw FlowRejection.validation([BC.ErrorData.FieldError(field: "tickets", message: "Choose available tickets.")])
        }
        if chosen.id != group?.id { answers.forget("quantity") }
        group = chosen
        snapshot.optionId = value
    }

    private func submitQuantity(_ submitted: BC.Answers) throws -> Int {
        guard let group else { throw FlowRejection.stepMismatch }
        let quantity = submitted.units("units")[Self.unitId] ?? 0
        guard group.sellableQuantities.contains(quantity) else {
            let allowed = group.sellableQuantities.map(String.init).joined(separator: ", ")
            throw FlowRejection.validation([BC.ErrorData.FieldError(field: "units", message: "These tickets are sold in quantities of \(allowed).")])
        }
        return quantity
    }

    private func offerPage(quantity: Int) {
        guard let group else { return }
        let url = hosted.url(eventId: eventId, ticketGroupId: group.id, quantity: quantity)
        snapshot.status = .awaitingPayment
        snapshot.step = nil
        snapshot.paymentStepId = "quantity"
        snapshot.allowed = [.back, .cancel]
        snapshot.nextAction = .providerHostedCart(BC.NextAction.Payload(
            id: context.identifiers.next("act_"),
            params: BC.ProviderHostedCartParams(url: url.absoluteString, pollIntervalSeconds: 0, settlement: .handOff),
            expiresAt: nil))
    }

    private func show(_ stepId: String) {
        snapshot.status = .collectingDetails
        snapshot.nextAction = nil
        snapshot.allowed = stepId == "tickets" ? [.submit, .cancel] : [.submit, .back, .cancel]
        let index = (Self.steps.firstIndex(of: stepId) ?? 0) + 1
        switch stepId {
        case "tickets":
            snapshot.step = LocalBlocks.step("tickets", "Choose your tickets", subtitle: event?.name, index: index,
                                             count: Self.steps.count, blocks: ticketBlocks)
        default:
            snapshot.step = LocalBlocks.step("quantity", "How many tickets?", index: index, count: Self.steps.count,
                                             blocks: [quantityBlock], primary: LocalBlocks.paymentAction)
        }
    }

    /// The seat map when TE has one, the event's details, then the ticket groups.
    private var ticketBlocks: [BC.Block] {
        var blocks: [BC.Block] = []
        if let chart = event?.seatingChartLarge ?? event?.seatingChartMedium {
            blocks.append(.image(BC.ImageBlock(id: "seating-chart", onUnsupported: .init(.skip), url: chart.absoluteString,
                                               alt: "Seating chart")))
        }
        let details = eventDetails
        if !details.isEmpty {
            blocks.append(.section(BC.SectionBlock(id: "event", onUnsupported: .init(.skip), title: "Event", blocks: details)))
        }
        blocks.append(groupBlock)
        return blocks
    }

    /// Read-only rows for the date and time, venue, address and performers, each left out when TE has nothing.
    private var eventDetails: [BC.Block] {
        guard let event else { return [] }
        let performers = (event.performers.filter(\.isPrimary) + event.performers.filter { !$0.isPrimary })
            .compactMap(\.name)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let rows: [(String, String?)] = [("event-date", Self.dateAndTime(event)), ("event-venue", event.venue?.name),
                                         ("event-address", event.venue?.address?.formatted), ("event-performers", performers)]
        return rows.compactMap { id, text in
            guard let text, !text.isEmpty else { return nil }
            return LocalBlocks.notice(id, .info, text)
        }
    }

    /// Every group TE lists with tickets left, cheapest first, with the ones that cannot be sold in any quantity disabled.
    private var groupBlock: BC.Block {
        let options = groups.map { candidate -> BC.ChoiceBlock.Option in
            BC.ChoiceBlock.Option(value: Self.optionId(candidate), title: Self.title(candidate), subtitle: Self.subtitle(candidate),
                                  price: candidate.retailPrice.map { LocalFormat.money($0, VictoryCheckout.currency) },
                                  badge: Self.badge(candidate), disabled: candidate.sellableQuantities.isEmpty ? true : nil)
        }
        return .choice(BC.ChoiceBlock(id: "tickets", options: options, multiple: false,
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

    /// "15 October 2026, 19:00", with "Time to be announced" in place of a time TE has not set.
    static func dateAndTime(_ event: VictoryEvent) -> String {
        let day = event.occursAtLocal.flatMap { BookingDate(String($0.prefix(10))) }.map(LocalFormat.longDate)
        let clock = event.occursAtLocal.map { String($0.dropFirst(11).prefix(5)) }.flatMap { $0.count == 5 ? $0 : nil }
        let time = event.isTimeToBeAnnounced ? timeToBeAnnounced : (clock ?? timeToBeAnnounced)
        return [day, time].compactMap { $0 }.joined(separator: ", ")
    }

    static func optionId(_ group: VictoryTicketGroup) -> String {
        "TG_\(group.id)"
    }

    /// "Section 101 · Row C", leaving out what TE does not list.
    static func title(_ group: VictoryTicketGroup) -> String {
        let parts = [group.section.map { "Section \($0)" }, group.row.map { "Row \($0)" }].compactMap { $0 }
        return parts.isEmpty ? "Tickets" : parts.joined(separator: " · ")
    }

    /// The seller's notes and the service fee per ticket, when there are any.
    static func subtitle(_ group: VictoryTicketGroup) -> String? {
        let notes = group.publicNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fee = group.serviceFee.flatMap { $0 > 0 ? "+ fee \(LocalFormat.amount($0)) \(VictoryCheckout.currency)" : nil }
        let parts = [notes, fee].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "E-ticket", "Instant delivery" or "In hand on 15 October 2026", the first that applies.
    static func badge(_ group: VictoryTicketGroup) -> String? {
        if group.isEticket { return "E-ticket" }
        if group.isInstantDelivery { return "Instant delivery" }
        if !group.isInHand, let inHandOn = group.inHandOn { return "In hand on \(LocalFormat.longDate(inHandOn))" }
        return nil
    }
}
