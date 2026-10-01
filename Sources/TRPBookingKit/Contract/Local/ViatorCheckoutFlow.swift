import Foundation

/// Viator behind the contract: date, travelers, tour and time, contact details and summary, then
/// Viator's hosted card form.
///
/// The hold is placed when the details are submitted and reused while the selection is unchanged.
/// The booking call races `processingWait`; when it is still running the checkout answers `202`
/// with `Retry-After: 2`, and `get` picks the outcome up later.
final class ViatorCheckoutFlow: ProviderCheckoutFlow {
    typealias BC = BookingContract

    var snapshot = FlowSnapshot()
    private let context: FlowContext
    private let viator: ViatorCheckout
    private let processingWait: TimeInterval
    private var answers = StepAnswers()
    private var productContext: ViatorProductContext?
    private var date: BookingDate?
    private var units: [(band: ViatorAgeBandRule, count: Int)] = []
    private var availability: ViatorAvailability?
    private var item: ViatorAvailability.Item?
    private var hold: ViatorCheckoutHold?
    private var heldItem: ViatorHoldItem?
    private var details: ViatorBookerDetails?
    private var booking: Task<ViatorBookingOutcome, Error>?

    private static let steps = ["date", "travelers", "option", "details", "summary"]

    init(context: FlowContext, viator: ViatorCheckout, processingWait: TimeInterval) {
        self.context = context
        self.viator = viator
        self.processingWait = processingWait
    }

    private var product: ViatorProduct? { productContext?.product }

    func start() async throws {
        productContext = try await viator.context(productCode: context.product.providerProductId)
        show("date")
    }

    func submit(answers submitted: BC.Answers, expectedAmount: BC.Money?) async throws {
        guard let stepId = snapshot.step?.id else { throw FlowRejection.stepMismatch }
        switch stepId {
        case "date": try await submitDate(submitted)
        case "travelers": try await submitTravelers(submitted)
        case "option": try submitOption(submitted)
        case "details": try await submitDetails(submitted)
        default: try submitSummary(submitted, expectedAmount: expectedAmount)
        }
        answers.record(submitted, for: stepId)
        show(Self.steps[(Self.steps.firstIndex(of: stepId) ?? 0) + 1])
        if stepId == "summary" { offerPayment(actionId: context.identifiers.next("act_")) }
    }

    func back() async throws {
        guard let stepId = snapshot.step?.id, let index = Self.steps.firstIndex(of: stepId), index > 0 else {
            throw FlowRejection.stepMismatch
        }
        show(Self.steps[index - 1])
    }

    func act(result: BC.ActionResult) async throws {
        guard let token = result.paymentToken, let hold, let details, let productContext else {
            throw FlowRejection.validation([BC.ErrorData.FieldError(field: "paymentToken", message: "The payment form returned no token.")])
        }
        snapshot.status = .processing
        snapshot.nextAction = nil
        snapshot.allowed = []
        let viator = self.viator
        booking = Task {
            try await viator.book(hold, details: details, context: productContext, payment: ViatorTokenPayment(token: token))
        }
        try await settle(retryAfter: 2)
    }

    func refresh() async {
        guard snapshot.status == .processing else { return }
        try? await settle(retryAfter: nil)
    }

    func cancel() async {
        booking?.cancel()
        if let hold { await context.store.update(hold.reference) { $0.status = .cancelled } }
    }

    func expire() async {
        if let hold { await context.store.update(hold.reference) { $0.status = .expired } }
    }

    private func settle(retryAfter: TimeInterval?) async throws {
        guard let booking else { return }
        switch await LocalRace.result(of: booking, within: processingWait) {
        case nil:
            if let retryAfter {
                snapshot.httpStatus = 202
                snapshot.retryAfter = retryAfter
            }
        case .success(let outcome)?:
            await finish(outcome)
        case .failure(let error)?:
            self.booking = nil
            try await fail(error)
        }
    }

    private func fail(_ error: Error) async throws {
        switch error {
        case BookingError.paymentFailed, BookingError.paymentCancelled, BookingError.server(status: 402, _, _):
            try await placeHold(force: true)
            offerPayment(actionId: context.identifiers.next("act_"))
            throw FlowRejection.paymentDeclined
        case BookingError.outcomeUnknown:
            snapshot.httpStatus = 202
            snapshot.retryAfter = 2
        default:
            snapshot.status = .failed
            snapshot.clearHold()
            snapshot.bookingStatus = .rejected
            snapshot.result = BC.CheckoutResult(title: "Your booking could not be completed",
                                                message: "Viator did not accept this booking. You have not been charged.",
                                                bookingUuid: context.bookingUuid)
        }
    }

    private func finish(_ outcome: ViatorBookingOutcome) async {
        let confirmed = outcome.status == .confirmed
        snapshot.status = confirmed ? .confirmed : .pending
        snapshot.clearHold()
        snapshot.bookingStatus = confirmed ? .confirmed : .pending
        snapshot.result = confirmed
            ? BC.CheckoutResult(title: LocalBlocks.confirmedResult.title, message: LocalBlocks.confirmedResult.message,
                                bookingUuid: context.bookingUuid)
            : BC.CheckoutResult(title: "Awaiting confirmation",
                                message: "Viator is confirming your booking. We will let you know by push notification and email.",
                                bookingUuid: context.bookingUuid)
        let contract = contractBooking(outcome)
        await context.store.update(outcome.reference) { $0.contractBooking = contract }
    }

    private func submitDate(_ submitted: BC.Answers) async throws {
        guard let value = submitted.string("date"), let chosen = BookingDate(value), availableDates.contains(chosen) else {
            throw FlowRejection.validation([BC.ErrorData.FieldError(field: "date", message: "Choose one of the available dates.")])
        }
        date = chosen
        guard let product, let date else { return }
        let probe = product.ageBands.map { ViatorPax(ageBand: $0.ageBand, numberOfTravelers: 1) }
        availability = try await viator.availability(for: productContext!, on: date, paxMix: probe, currency: context.currency)
        units = product.ageBands.map { ($0, 0) }
    }

    private func submitTravelers(_ submitted: BC.Answers) async throws {
        let counts = submitted.units("units")
        let chosen = units.map { (band: $0.band, count: counts[$0.band.ageBand.rawValue] ?? 0) }
        let total = chosen.reduce(0) { $0 + $1.count }
        guard let product, let date, total >= totalBounds.min, total <= totalBounds.max,
              chosen.allSatisfy({ $0.count >= ($0.band.minTravelersPerBooking ?? 0) && $0.count <= ($0.band.maxTravelersPerBooking ?? total) }) else {
            throw FlowRejection.validation([BC.ErrorData.FieldError(field: "units", message: "Choose a valid number of travelers.")])
        }
        units = chosen
        let pax = chosen.filter { $0.count > 0 }.map { ViatorPax(ageBand: $0.band.ageBand, numberOfTravelers: $0.count) }
        let priced = try await viator.availability(for: productContext!, on: date, paxMix: pax, currency: context.currency)
        availability = priced
        item = nil
        let first = orderedItems(product).first { $0.available } ?? priced.bookableItems.first
        snapshot.amount = first.flatMap(price).map { LocalFormat.money($0, context.currency) }
    }

    private func submitOption(_ submitted: BC.Answers) throws {
        guard let value = submitted.string("option"), let product,
              let chosen = orderedItems(product).first(where: { optionValue($0) == value }) else {
            throw FlowRejection.validation([BC.ErrorData.FieldError(field: "option", message: "Choose a tour and time.")])
        }
        guard chosen.available else { throw FlowRejection.soldOut }
        item = chosen
        snapshot.optionId = chosen.productOptionCode
        snapshot.amount = price(chosen).map { LocalFormat.money($0, context.currency) }
    }

    private func submitDetails(_ submitted: BC.Answers) async throws {
        let errors = LocalBlocks.contactErrors("lead", in: submitted)
        guard errors.isEmpty else { throw FlowRejection.validation(errors) }
        var pickup: [ViatorAnswer] = []
        switch submitted["pickup"].flatMap({ try? $0.decode(as: BC.LocationOrTextAnswer.self) }) {
        case .ref(let reference)?: pickup = [.pickup(at: reference)]
        case .text(let text)?: pickup = [ViatorAnswer(question: ViatorBookingQuestion.pickupPointId, answer: text, unit: "FREETEXT")]
        case nil: break
        }
        details = ViatorBookerDetails(firstName: submitted.string("lead.firstName") ?? "", lastName: submitted.string("lead.lastName") ?? "",
                                      email: submitted.string("lead.email") ?? "", phone: submitted.string("lead.phone") ?? "",
                                      answers: pickup)
        try await placeHold(force: false)
    }

    private func submitSummary(_ submitted: BC.Answers, expectedAmount: BC.Money?) throws {
        if let error = LocalValidation.consent("terms", in: submitted) { throw FlowRejection.validation([error]) }
        if let expectedAmount, let current = snapshot.amount,
           LocalFormat.decimal(expectedAmount) != LocalFormat.decimal(current) || expectedAmount.currency != current.currency {
            throw FlowRejection.priceChanged
        }
    }

    private func placeHold(force: Bool) async throws {
        guard let item, let date else { throw FlowRejection.stepMismatch }
        let pax = units.filter { $0.count > 0 }.map { ViatorPax(ageBand: $0.band.ageBand, numberOfTravelers: $0.count) }
        let request = ViatorHoldItem(productCode: context.product.providerProductId, productOptionCode: item.productOptionCode,
                                     startTime: item.startTime, travelDate: date, paxMix: pax)
        if !force, let hold, heldItem == request, !hold.deadline.isExpired(at: context.now()) { return }
        let placed = try await viator.hold(request, currency: context.currency, activityId: context.product.id,
                                           title: context.product.title)
        hold = placed
        heldItem = request
        snapshot.holdPlacedAt = context.now()
        snapshot.holdExpiresAt = placed.deadline.expiresAt
        snapshot.priceValidUntil = placed.deadline.expiresAt
        snapshot.bookingStatus = .onHold
        if let total = placed.total { snapshot.amount = LocalFormat.money(total, placed.currency) }
    }

    private func offerPayment(actionId: String) {
        guard let hold else { return }
        snapshot.status = .awaitingPayment
        snapshot.step = nil
        snapshot.allowed = [.cancel]
        snapshot.nextAction = .providerHostedForm(BC.NextAction.Payload(
            id: actionId, params: BC.ProviderHostedFormParams(paymentSessionToken: hold.paymentSessionToken),
            expiresAt: LocalFormat.iso(hold.deadline.expiresAt)))
    }

    private func show(_ stepId: String) {
        snapshot.status = .collectingDetails
        snapshot.nextAction = nil
        snapshot.allowed = stepId == "date" ? [.submit, .cancel] : [.submit, .back, .cancel]
        let count: Int? = item == nil ? nil : Self.steps.count
        let index = (Self.steps.firstIndex(of: stepId) ?? 0) + 1
        switch stepId {
        case "date":
            let dates = availableDates
            let from = dates.first ?? productContext?.calendar.earliestBookableDate(now: context.now())
            snapshot.step = LocalBlocks.step("date", "Choose a date", index: index, count: count, blocks: [
                .date(BC.DateBlock(id: "date", onUnsupported: .init(.fallback), mode: .init(.available),
                                   range: from.map { BC.DateBlock.DateRange(from: $0.description, to: $0.adding(days: 89).description) },
                                   dates: dates.map(\.description), defaultValue: answers.string("date")))
            ])
        case "travelers":
            snapshot.step = LocalBlocks.step("travelers", "Number of travelers", subtitle: date.map(LocalFormat.longDate),
                                             index: index, count: count, blocks: [travelersBlock])
        case "option":
            snapshot.step = LocalBlocks.step("option", "Choose a tour and time", subtitle: partySubtitle, index: index, count: count,
                                             blocks: [optionBlock])
        case "details":
            var blocks = LocalBlocks.contact("lead", defaults: answers)
            if let pickups = productContext?.pickupLocations, !pickups.isEmpty {
                blocks.append(.field(.locationOrText(BC.FieldSpec(
                    id: "pickup", label: "Pickup location", required: false, scope: .init(.booking),
                    options: pickups.map { BC.FieldOption(value: $0.reference, title: $0.name ?? $0.reference) },
                    defaultValue: answers.value("pickup").flatMap { try? $0.decode(as: BC.LocationOrTextAnswer.self) },
                    degradesTo: .init(.text)))))
            }
            snapshot.step = LocalBlocks.step("details", "Contact details", index: index, count: count, blocks: blocks)
        default:
            snapshot.step = LocalBlocks.step("summary", "Summary", index: index, count: count, blocks: summaryBlocks,
                                             primary: LocalBlocks.paymentAction)
        }
    }

    private var availableDates: [BookingDate] {
        guard let calendar = productContext?.calendar else { return [] }
        let from = calendar.earliestBookableDate(now: context.now())
        return calendar.availableDates(from: from, through: from.adding(days: 89), now: context.now())
    }

    private var totalBounds: (min: Int, max: Int) {
        (product?.minTravelersPerBooking ?? 1, product?.maxTravelersPerBooking ?? 9)
    }

    private var travelersBlock: BC.Block {
        let probe = availability?.bookableItems.first { $0.available } ?? availability?.bookableItems.first
        let items = units.map { unit -> BC.QuantityBlock.Item in
            let line = probe?.lineItems.first { $0.ageBand == unit.band.ageBand }
            let price = line?.subtotalPrice?.recommendedRetailPrice.map { $0 / Decimal(max(line?.numberOfTravelers ?? 1, 1)) }
            return BC.QuantityBlock.Item(unitId: unit.band.ageBand.rawValue, title: unit.band.ageBand.rawValue.capitalized,
                                         subtitle: LocalFormat.ageRange(min: unit.band.startAge, max: unit.band.endAge),
                                         price: price.map { LocalFormat.money($0, context.currency) },
                                         min: unit.band.minTravelersPerBooking ?? 0, max: unit.band.maxTravelersPerBooking ?? totalBounds.max)
        }
        let defaults = answers.value("units").map { _ in answers.byStep["travelers"]?.units("units") ?? [:] }
        return .quantity(BC.QuantityBlock(id: "units", items: items, total: BC.QuantityBlock.Total(min: totalBounds.min, max: totalBounds.max),
                                          defaultValue: defaults))
    }

    private var partySubtitle: String? {
        guard let date else { return nil }
        let party = LocalFormat.party(units.map { ($0.band.ageBand.rawValue, $0.count) })
        return [LocalFormat.longDate(date), party].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var optionBlock: BC.Block {
        let options = product.map(orderedItems)?.map { candidate -> BC.ChoiceBlock.Option in
            let title = product?.options.first { $0.productOptionCode == candidate.productOptionCode }?.title ?? candidate.productOptionCode
            let time = candidate.startTime ?? ""
            let detail = candidate.available
                ? context.product.duration(option: candidate.productOptionCode).map { "\(time) · \($0) min" } ?? time
                : "\(time) · sold out"
            return BC.ChoiceBlock.Option(value: optionValue(candidate), title: title, subtitle: detail,
                                         price: price(candidate).map { LocalFormat.money($0, context.currency) },
                                         disabled: candidate.available ? nil : true)
        } ?? []
        return .choice(BC.ChoiceBlock(id: "option", options: options, multiple: false,
                                      defaultValue: answers.string("option").map { .single($0) }))
    }

    private var summaryBlocks: [BC.Block] {
        let lines = (item?.lineItems ?? []).compactMap { line -> BC.SummaryBlock.Line? in
            guard let band = line.ageBand else { return nil }
            return BC.SummaryBlock.Line(title: "\(line.numberOfTravelers) × \(band.rawValue.capitalized)",
                                        amount: line.subtotalPrice?.recommendedRetailPrice.map { LocalFormat.money($0, context.currency) })
        }
        let note = [date.map(LocalFormat.longDate), item?.startTime].compactMap { $0 }.joined(separator: ", ")
        var blocks: [BC.Block] = [.summary(BC.SummaryBlock(id: "summary", lines: lines,
                                                          total: snapshot.amount ?? LocalFormat.money(0, context.currency), note: note))]
        if let deadline = freeCancellation?.deadline {
            blocks.append(LocalBlocks.notice("cancellation", .info,
                                             "Free cancellation until \(LocalFormat.dayAndTime(deadline, in: context.product.timeZone))."))
        }
        blocks.append(LocalBlocks.terms("I accept the terms of sale.",
                                        link: BC.ConsentBlock.Link(title: "Terms", url: "https://www.tripian.com/terms")))
        return blocks
    }

    private func orderedItems(_ product: ViatorProduct) -> [ViatorAvailability.Item] {
        let order = product.options.map(\.productOptionCode)
        return (availability?.bookableItems ?? []).sorted {
            let lhs = order.firstIndex(of: $0.productOptionCode) ?? .max
            let rhs = order.firstIndex(of: $1.productOptionCode) ?? .max
            return lhs != rhs ? lhs < rhs : ($0.startTime ?? "") < ($1.startTime ?? "")
        }
    }

    private func optionValue(_ item: ViatorAvailability.Item) -> String {
        "\(item.productOptionCode)~\(item.startTime ?? "")"
    }

    private func price(_ item: ViatorAvailability.Item) -> Decimal? {
        item.totalPrice?.recommendedRetailPrice
    }

    private var start: Date? {
        guard let date else { return nil }
        let time = (item?.startTime ?? "00:00").split(separator: ":").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.product.timeZone
        return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day,
                                                  hour: time.first ?? 0, minute: time.dropFirst().first ?? 0))
    }

    /// The last moment a full or partial refund applies, from the smallest refundable day range.
    private var freeCancellation: (deadline: Date, percentage: Decimal)? {
        guard let start, let windows = product?.cancellationPolicy?.refundEligibility else { return nil }
        guard let window = windows.filter({ $0.percentageRefundable > 0 }).min(by: { ($0.dayRangeMin ?? 0) < ($1.dayRangeMin ?? 0) }),
              let deadline = Calendar.utcGregorian.date(byAdding: .day, value: -(window.dayRangeMin ?? 0), to: start) else { return nil }
        return (deadline, window.percentageRefundable)
    }

    private func contractBooking(_ outcome: ViatorBookingOutcome) -> BC.Booking {
        let amount = outcome.total.map { LocalFormat.money($0, outcome.currency) } ?? snapshot.amount ?? LocalFormat.money(0, outcome.currency)
        let refund = freeCancellation
        let vouchers = [outcome.voucher].compactMap { voucher -> BC.Booking.Voucher? in
            guard let url = voucher?.url else { return nil }
            return BC.Booking.Voucher(format: .init(rawValue: (voucher?.format ?? "url").lowercased()), url: url.absoluteString)
        }
        return BC.Booking(
            uuid: context.bookingUuid, status: .init(outcome.status == .confirmed ? .confirmed : .pending), provider: "viator",
            providerReference: outcome.reference.primary,
            product: BC.Product(id: context.product.id, optionId: snapshot.optionId, title: context.product.title,
                                imageUrl: context.product.imageUrl),
            units: Dictionary(units.filter { $0.count > 0 }.map { ($0.band.ageBand.rawValue, $0.count) }, uniquingKeysWith: +),
            start: BC.Booking.Start(date: date?.description ?? "", time: item?.startTime, timezone: context.product.timeZone.identifier),
            durationMinutes: context.product.duration(option: snapshot.optionId), meetingPoint: context.product.meetingPoint,
            amount: amount, utcExpiresAt: nil, vouchers: vouchers,
            cancellation: BC.Booking.Cancellation(allowed: refund != nil, deadline: refund.map { LocalFormat.iso($0.deadline) },
                                                  refund: .init(refund == nil ? .none : refund!.percentage >= 100 ? .full : .partial),
                                                  refundAmount: refund == nil ? nil : amount),
            refund: nil,
            contact: BC.Booking.Contact(name: [details?.firstName, details?.lastName].compactMap { $0 }.joined(separator: " "),
                                        email: details?.email ?? ""))
    }
}

/// Hands Viator the token the hosted form already produced.
private struct ViatorTokenPayment: ViatorPaymentTokenProviding {
    let token: String

    func paymentToken(for hold: ViatorCheckoutHold) async throws -> String { token }
}

/// Waits a bounded time for a task's result.
enum LocalRace {
    /// The task's result, or `nil` when it is still running after `seconds`.
    static func result<T: Sendable>(of task: Task<T, Error>, within seconds: TimeInterval) async -> Result<T, Error>? {
        await withTaskGroup(of: Result<T, Error>?.self) { group in
            group.addTask {
                do { return .success(try await task.value) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
