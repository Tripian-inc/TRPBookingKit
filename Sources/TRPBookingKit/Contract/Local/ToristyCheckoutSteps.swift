import Foundation

/// The Toristy steps every Toristy payment flow shares: date, start time, rate, travelers, contact and traveler
/// details and summary, and the cart held for them.
///
/// The cart is held when the details are submitted and reused while the selection is unchanged; a changed selection
/// holds a new cart and releases the previous one. A summary submitted without a cart, after the flow released it,
/// holds a new one. The payment itself is the flow's: `paymentAction` turns the held cart into the `NextAction`
/// the client is handed.
final class ToristyCheckoutSteps {
    typealias BC = BookingContract
    typealias PaymentAction = (_ hold: ToristyHold, _ email: String?) async throws -> BC.NextAction

    var snapshot = FlowSnapshot()
    let context: FlowContext
    let toristy: ToristyCheckout
    private let paymentAction: PaymentAction
    private var answers = StepAnswers()
    private var serviceId = 0
    private var information: ToristyBookingInformation?
    private var availability: ToristyAvailability?
    private var date: BookingDate?
    private var startTime: ToristyStartTime?
    private var rate: ToristyRate?
    private var units: [(category: ToristyPricingCategory, count: Int)] = []
    private var selection: ToristySelection?
    private(set) var hold: ToristyHold?
    private var heldSelection: ToristySelection?
    private(set) var email: String?
    private var contactName = ""

    static let steps = ["date", "time", "rate", "travelers", "details", "summary"]
    private static let defaultMaximumTravelers = 15
    static let cancelNote = "Checkout cancelled before payment."
    private static let replaceNote = "Selection changed before payment."

    init(context: FlowContext, toristy: ToristyCheckout, paymentAction: @escaping PaymentAction) {
        self.context = context
        self.toristy = toristy
        self.paymentAction = paymentAction
    }

    func start() async throws {
        guard let serviceId = Int(context.product.providerProductId) else { throw FlowRejection.supplierUnavailable(retryable: false) }
        self.serviceId = serviceId
        information = try await toristy.bookingInformation(serviceId: serviceId, currency: context.currency)
        let today = BookingDate(date: context.now(), timeZone: context.product.timeZone)
        availability = try await toristy.availability(serviceId: serviceId, from: today, through: today.adding(days: 89))
        show("date")
    }

    func submit(answers submitted: BC.Answers, expectedAmount: BC.Money?) async throws {
        guard let stepId = snapshot.step?.id else { throw FlowRejection.stepMismatch }
        switch stepId {
        case "date": try submitDate(submitted)
        case "time": try submitTime(submitted)
        case "rate": try submitRate(submitted)
        case "travelers": try submitTravelers(submitted)
        case "details": try await submitDetails(submitted)
        default: try submitSummary(expectedAmount: expectedAmount)
        }
        answers.record(submitted, for: stepId)
        if stepId == "summary" {
            try await offerPayment()
        } else {
            show(Self.steps[(Self.steps.firstIndex(of: stepId) ?? 0) + 1])
        }
    }

    func back() async throws {
        guard let stepId = snapshot.backStepId(in: Self.steps) else { throw FlowRejection.stepMismatch }
        show(stepId)
    }

    /// Releases an unconfirmed cart at Toristy without emailing anyone, so its seats are not held until it expires.
    /// Payment is closed before the release is sent, so a payment result arriving meanwhile cannot confirm the cart.
    func cancel() async {
        snapshot.nextAction = nil
        snapshot.allowed = []
        guard let hold, !isPaymentUnderway else { return }
        await release(hold, note: Self.cancelNote)
        guard !isPaymentUnderway else { return }
        await context.store.update(hold.reference) { $0.status = .cancelled }
    }

    func expire() async {
        if let hold { await context.store.update(hold.reference) { $0.status = .expired } }
    }

    var isPaymentUnderway: Bool {
        [.processing, .confirmed, .failed].contains(snapshot.status)
    }

    /// Releases the held cart, marks its record cancelled and shows the summary again without a hold.
    func releaseHold(note: String) async {
        guard let released = hold else { return }
        hold = nil
        heldSelection = nil
        snapshot.clearHold()
        snapshot.bookingStatus = nil
        show("summary")
        await release(released, note: note)
        await context.store.update(released.reference) { $0.status = .cancelled }
    }

    /// Cancels a cart at Toristy without notifying anyone; a failure is ignored and the cart then lapses on its own.
    private func release(_ hold: ToristyHold, note: String) async {
        _ = try? await toristy.cancel(hold.reference, note: note, notify: false)
    }

    /// Marks the checkout confirmed and keeps its contract booking on the cart's record.
    func finish(reference: BookingReference, total: Decimal, currency: String) async {
        snapshot.status = .confirmed
        snapshot.clearHold()
        snapshot.bookingStatus = .confirmed
        snapshot.result = BC.CheckoutResult(title: LocalBlocks.confirmedResult.title, message: LocalBlocks.confirmedResult.message,
                                            bookingUuid: context.bookingUuid)
        let contract = contractBooking(reference: reference, total: total, currency: currency)
        await context.store.update(reference) {
            $0.contractBooking = contract
            $0.pendingContractBooking = nil
        }
    }

    private func submitDate(_ submitted: BC.Answers) throws {
        guard let value = submitted.string("date"), let chosen = BookingDate(value), availableDates.contains(chosen) else {
            throw FlowRejection.validation([BC.ErrorData.FieldError(field: "date", message: "Choose one of the available dates.")])
        }
        if chosen != date {
            startTime = nil
            rate = nil
        }
        date = chosen
    }

    private func submitTime(_ submitted: BC.Answers) throws {
        guard let value = submitted.string("time"), let chosen = departures.first(where: { $0.time == value }) else {
            throw FlowRejection.validation([BC.ErrorData.FieldError(field: "time", message: "Choose a start time.")])
        }
        guard chosen.isBookable else { throw FlowRejection.soldOut }
        if chosen != startTime { rate = nil }
        startTime = chosen
    }

    private func submitRate(_ submitted: BC.Answers) throws {
        guard let value = submitted.string("rate"), let chosen = offeredRates.first(where: { $0.id == value }) else {
            throw FlowRejection.validation([BC.ErrorData.FieldError(field: "rate", message: "Choose a rate.")])
        }
        if chosen != rate {
            units = chosen.prices.filter { startTime?.rate(id: chosen.id)?.accepts(pricingCategoryId: $0.id) ?? true }.map { ($0, 0) }
        }
        rate = chosen
        snapshot.optionId = chosen.id
    }

    private func submitTravelers(_ submitted: BC.Answers) throws {
        let counts = submitted.units("units")
        let chosen = units.map { (category: $0.category, count: counts[$0.category.id] ?? 0) }
        let total = chosen.reduce(0) { $0 + $1.count }
        guard total >= totalBounds.min, total <= totalBounds.max,
              chosen.allSatisfy({ $0.count >= ($0.category.minPerBooking ?? 0) && $0.count <= ($0.category.maxPerBooking ?? totalBounds.max) }) else {
            throw FlowRejection.validation([BC.ErrorData.FieldError(field: "units", message: "Choose a valid number of travelers.")])
        }
        units = chosen
        snapshot.amount = estimatedTotal.map { LocalFormat.money($0, context.currency) }
    }

    private func submitDetails(_ submitted: BC.Answers) async throws {
        var errors = LocalBlocks.contactErrors("lead", in: submitted)
        let travelerFields = travelers.enumerated().flatMap { index, category -> [(String, String)] in
            var fields = [("t\(index + 1).fullName", "Enter the traveler's full name.")]
            if category.maxAge != nil { fields.append(("t\(index + 1).birthDate", "Enter the traveler's date of birth.")) }
            return fields
        }
        errors += LocalValidation.required(travelerFields, in: submitted)
        guard errors.isEmpty else { throw FlowRejection.validation(errors) }
        let firstName = submitted.string("lead.firstName") ?? ""
        let lastName = submitted.string("lead.lastName") ?? ""
        email = submitted.string("lead.email")
        contactName = "\(firstName) \(lastName)"
        let contact = [ToristyAnswer(questionId: "firstName", value: firstName),
                       ToristyAnswer(questionId: "lastName", value: lastName),
                       ToristyAnswer(questionId: "email", value: email ?? ""),
                       ToristyAnswer(questionId: "phone", value: submitted.string("lead.phone") ?? "")]
        let passengers = travelers.enumerated().map { index, category -> ToristyPassenger in
            var details = [ToristyAnswer(questionId: "fullName", value: submitted.string("t\(index + 1).fullName") ?? "")]
            if let birthDate = submitted.string("t\(index + 1).birthDate") {
                details.append(ToristyAnswer(questionId: "dateOfBirth", value: birthDate))
            }
            return ToristyPassenger(pricingCategoryId: category.id, details: details)
        }
        guard let chosen = draftSelection(mainContact: contact, passengers: passengers), let information else {
            throw FlowRejection.stepMismatch
        }
        selection = chosen
        if let hold, heldSelection == chosen, !hold.deadline.isExpired(at: context.now()) { return }
        let placed = try await toristy.reserve(chosen, information: information, activityId: context.product.id,
                                               title: context.product.title)
        if let replaced = hold {
            await release(replaced, note: Self.replaceNote)
            await context.store.update(replaced.reference) { $0.status = .cancelled }
        }
        place(placed, for: chosen)
    }

    private func submitSummary(expectedAmount: BC.Money?) throws {
        if let expectedAmount, let current = snapshot.amount,
           LocalFormat.decimal(expectedAmount) != LocalFormat.decimal(current) || expectedAmount.currency != current.currency {
            throw FlowRejection.priceChanged
        }
    }

    /// Offers the held cart for payment, holding a new cart first when the flow released the previous one.
    func offerPayment() async throws {
        if hold == nil { try await holdAgain() }
        guard let hold else { throw FlowRejection.stepMismatch }
        let action = try await paymentAction(hold, email)
        snapshot.status = .awaitingPayment
        snapshot.step = nil
        snapshot.paymentStepId = Self.steps.last
        snapshot.allowed = [.back, .cancel]
        snapshot.nextAction = action
    }

    private func holdAgain() async throws {
        guard let selection, let information else { throw FlowRejection.stepMismatch }
        let offered = snapshot.amount
        let placed = try await toristy.reserve(selection, information: information, activityId: context.product.id,
                                               title: context.product.title)
        place(placed, for: selection)
        guard let offered, let current = snapshot.amount,
              LocalFormat.decimal(offered) != LocalFormat.decimal(current) || offered.currency != current.currency else { return }
        show("summary")
        throw FlowRejection.priceChanged
    }

    private func place(_ placed: ToristyHold, for chosen: ToristySelection) {
        hold = placed
        heldSelection = chosen
        snapshot.holdPlacedAt = context.now()
        snapshot.holdExpiresAt = placed.deadline.expiresAt
        snapshot.priceValidUntil = placed.deadline.expiresAt
        snapshot.bookingStatus = .onHold
        snapshot.amount = LocalFormat.money(placed.total, placed.currency)
    }

    private func show(_ stepId: String) {
        snapshot.status = .collectingDetails
        snapshot.nextAction = nil
        snapshot.allowed = stepId == "date" ? [.submit, .cancel] : [.submit, .back, .cancel]
        let count: Int? = hold == nil ? nil : Self.steps.count
        let index = (Self.steps.firstIndex(of: stepId) ?? 0) + 1
        switch stepId {
        case "date":
            let dates = availableDates
            snapshot.step = LocalBlocks.step("date", "Choose a date", index: index, count: count, blocks: [
                .date(BC.DateBlock(id: "date", onUnsupported: .init(.fallback), mode: .init(.available),
                                   range: dates.first.map { BC.DateBlock.DateRange(from: $0.description, to: $0.adding(days: 89).description) },
                                   dates: dates.map(\.description), defaultValue: answers.string("date")))
            ])
        case "time":
            snapshot.step = LocalBlocks.step("time", "Choose a start time", subtitle: date.map(LocalFormat.longDate), index: index,
                                             count: count, blocks: [timeBlock])
        case "rate":
            let subtitle = [date.map(LocalFormat.longDate), startTime?.time].compactMap { $0 }.joined(separator: ", ")
            snapshot.step = LocalBlocks.step("rate", "Choose a rate", subtitle: subtitle, index: index, count: count, blocks: [rateBlock])
        case "travelers":
            snapshot.step = LocalBlocks.step("travelers", "Number of travelers", index: index, count: count,
                                             blocks: [travelersBlock, estimateBlock])
        case "details":
            var blocks = LocalBlocks.contact("lead", defaults: answers)
            for (offset, category) in travelers.enumerated() {
                let number = offset + 1
                blocks.append(LocalBlocks.text("t\(number).fullName", "Traveler \(number) full name", scope: .traveler,
                                               traveler: offset, defaults: answers))
                if category.maxAge != nil {
                    blocks.append(LocalBlocks.date("t\(number).birthDate", "Traveler \(number) date of birth",
                                                   hint: category.minAge.map { "\(Self.plural(category.name)) must be \($0) or older." },
                                                   traveler: offset, defaults: answers))
                }
            }
            snapshot.step = LocalBlocks.step("details", "Contact and traveler details", index: index, count: count, blocks: blocks)
        default:
            snapshot.step = LocalBlocks.step("summary", "Summary", index: index, count: count, blocks: summaryBlocks,
                                             primary: LocalBlocks.paymentAction)
        }
    }

    private var availableDates: [BookingDate] {
        (availability?.days ?? []).filter { !$0.bookableTimes.isEmpty }.map(\.date).sorted()
    }

    private var departures: [ToristyStartTime] {
        date.flatMap { availability?.day($0)?.times } ?? []
    }

    private var offeredRates: [ToristyRate] {
        guard let startTime else { return [] }
        return (information?.rates ?? []).filter { $0.applies(toStartTimeId: startTime.id) }
    }

    private var departureRate: ToristyStartTimeRate? {
        rate.flatMap { startTime?.rate(id: $0.id) }
    }

    private var totalBounds: (min: Int, max: Int) {
        let minimum = max(1, departureRate?.minPerBooking ?? 1, startTime?.minParticipants ?? 0)
        return (minimum, departureRate?.maxPerBooking ?? Self.defaultMaximumTravelers)
    }

    /// The booked categories, one entry per traveler, in the rate's category order.
    private var travelers: [ToristyPricingCategory] {
        units.flatMap { Array(repeating: $0.category, count: $0.count) }
    }

    private var partySize: Int {
        max(units.reduce(0) { $0 + $1.count }, 1)
    }

    private func draftSelection(mainContact: [ToristyAnswer], passengers: [ToristyPassenger]) -> ToristySelection? {
        guard let rate, let date, let startTime else { return nil }
        return ToristySelection(serviceId: serviceId, rateId: rate.id, date: date, startTime: startTime, mainContact: mainContact,
                                passengers: passengers, currency: context.currency)
    }

    private var estimatedTotal: Decimal? {
        guard let information,
              let draft = draftSelection(mainContact: [], passengers: travelers.map { ToristyPassenger(pricingCategoryId: $0.id) }) else {
            return nil
        }
        return ToristyPriceEstimator().estimate(draft, information: information)?.total
    }

    private var timeBlock: BC.Block {
        let options = departures.map { departure -> BC.ChoiceBlock.Option in
            let seats = departure.seatsLeft
            let subtitle = !departure.isBookable ? "Sold out" : seats.map { "\($0) \($0 == 1 ? "seat" : "seats") left" }
            return BC.ChoiceBlock.Option(value: departure.time, title: departure.time, subtitle: subtitle,
                                         badge: departure.isBookable && (seats ?? .max) <= 3 ? "Few seats left" : nil,
                                         disabled: departure.isBookable ? nil : true)
        }
        return .choice(BC.ChoiceBlock(id: "time", options: options, multiple: false, defaultValue: answers.string("time").map { .single($0) }))
    }

    private var rateBlock: BC.Block {
        let options = offeredRates.map { candidate -> BC.ChoiceBlock.Option in
            let departure = startTime?.rate(id: candidate.id)
            let perBooking = startTime?.pricePer == .booking || departure?.pricedPerPerson == false
            let price = candidate.startingPrice ?? candidate.prices.compactMap(\.price).min()
            let subtitle: String?
            if perBooking {
                subtitle = departure?.maxPerBooking.map { "Up to \($0) people" }
            } else {
                subtitle = price.map { "From \(LocalFormat.amount($0)) \(context.currency) per person" }
            }
            return BC.ChoiceBlock.Option(value: candidate.id, title: candidate.name, subtitle: subtitle,
                                         price: price.map { LocalFormat.money($0, context.currency) })
        }
        return .choice(BC.ChoiceBlock(id: "rate", options: options, multiple: false, defaultValue: answers.string("rate").map { .single($0) }))
    }

    private func unitPrice(_ category: ToristyPricingCategory) -> Decimal? {
        category.unitPrice(forPartySize: partySize)
    }

    private var travelersBlock: BC.Block {
        let items = units.map { unit -> BC.QuantityBlock.Item in
            BC.QuantityBlock.Item(unitId: unit.category.id, title: unit.category.name,
                                  subtitle: LocalFormat.ageRange(min: unit.category.minAge, max: unit.category.maxAge),
                                  price: unitPrice(unit.category).map { LocalFormat.money($0, context.currency) },
                                  min: unit.category.minPerBooking ?? 0, max: unit.category.maxPerBooking ?? totalBounds.max)
        }
        let defaults = answers.value("units").map { _ in answers.byStep["travelers"]?.units("units") ?? [:] }
        return .quantity(BC.QuantityBlock(id: "units", items: items, total: BC.QuantityBlock.Total(min: totalBounds.min, max: totalBounds.max),
                                          defaultValue: defaults))
    }

    private var estimateBlock: BC.Block {
        let lines = units.map { unit in
            BC.SummaryBlock.Line(title: unit.category.name,
                                 detail: unitPrice(unit.category).map { "\(LocalFormat.amount($0)) \(context.currency) per person" })
        }
        let total = units.reduce(Decimal(0)) { $0 + (unitPrice($1.category) ?? 0) * Decimal($1.count) }
        return .summary(BC.SummaryBlock(id: "estimate", lines: lines, total: LocalFormat.money(total, context.currency),
                                        note: "The estimate updates as you choose travelers."))
    }

    private var summaryBlocks: [BC.Block] {
        let lines = units.filter { $0.count > 0 }.map { unit in
            BC.SummaryBlock.Line(title: "\(unit.count) × \(unit.category.name)",
                                 amount: unitPrice(unit.category).map { LocalFormat.money($0 * Decimal(unit.count), context.currency) })
        }
        let when = [date.map(LocalFormat.longDate), startTime?.time].compactMap { $0 }.joined(separator: ", ")
        let note = [when, rate?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        var blocks: [BC.Block] = [.summary(BC.SummaryBlock(id: "summary", lines: lines,
                                                          total: snapshot.amount ?? LocalFormat.money(0, context.currency), note: note))]
        if let deadline = freeCancellationDeadline {
            blocks.append(LocalBlocks.notice("cancellation", .info,
                                             "Free cancellation until \(LocalFormat.dayAndTime(deadline, in: context.product.timeZone))."))
        }
        return blocks
    }

    private var start: Date? {
        guard let date else { return nil }
        let time = (startTime?.time ?? "00:00").split(separator: ":").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.product.timeZone
        return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day,
                                                  hour: time.first ?? 0, minute: time.dropFirst().first ?? 0))
    }

    /// The last moment no cancellation fee applies: before the widest window of any fee-bearing rule.
    private var freeCancellationDeadline: Date? {
        guard let start, let rules = information?.cancellationRules, !rules.isEmpty else { return nil }
        let cutoff = rules.filter { $0.feePercentage > 0 }.map(\.cutoffHours).max() ?? 0
        return start.addingTimeInterval(-TimeInterval(cutoff) * 3600)
    }

    /// The contract booking the cart becomes once paid, with Toristy's confirmation code as its reference when known.
    func contractBooking(reference: BookingReference, total: Decimal, currency: String) -> BC.Booking {
        let amount = LocalFormat.money(total, currency)
        let deadline = freeCancellationDeadline
        return BC.Booking(
            uuid: context.bookingUuid, status: .init(.confirmed), provider: "toristy",
            providerReference: reference.secondary ?? reference.primary,
            product: BC.Product(id: context.product.id, optionId: snapshot.optionId, title: context.product.title,
                                imageUrl: context.product.imageUrl),
            units: Dictionary(units.filter { $0.count > 0 }.map { ($0.category.id, $0.count) }, uniquingKeysWith: +),
            start: BC.Booking.Start(date: date?.description ?? "", time: startTime?.time, timezone: context.product.timeZone.identifier),
            durationMinutes: context.product.duration(option: snapshot.optionId), meetingPoint: context.product.meetingPoint,
            amount: amount, utcExpiresAt: nil, vouchers: [],
            cancellation: BC.Booking.Cancellation(allowed: deadline != nil, deadline: deadline.map(LocalFormat.iso),
                                                  refund: .init(deadline == nil ? .none : .full),
                                                  refundAmount: deadline == nil ? nil : amount),
            refund: nil,
            contact: BC.Booking.Contact(name: contactName, email: email ?? ""))
    }

    private static func plural(_ noun: String) -> String {
        switch noun.lowercased() {
        case "child": return "Children"
        case "person": return "People"
        default: return noun + "s"
        }
    }
}
