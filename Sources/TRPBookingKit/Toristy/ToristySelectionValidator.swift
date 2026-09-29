import Foundation

/// A problem with a selection, found before anything is sent to Toristy.
public enum ToristySelectionIssue: Sendable, Hashable, CustomStringConvertible {
    case unknownRate(String)
    case rateNotOfferedAtStartTime(rateId: String, startTimeId: Int)
    case departureNotBookable
    case notEnoughSeats(requested: Int, available: Int)
    case belowMinimumParticipants(requested: Int, minimum: Int)
    case rateBookingBounds(requested: Int, minimum: Int?, maximum: Int?)
    case unknownPricingCategory(String)
    case categoryBookingBounds(categoryId: String, requested: Int, minimum: Int?, maximum: Int?)
    case noPassengers
    case missingMainContact(questionId: String)
    case missingPassengerDetail(passengerIndex: Int, questionId: String)
    case missingQuestion(questionId: String)
    case missingPassengerAnswer(passengerIndex: Int, questionId: String)
    case unknownExtra(String)
    case extraLimitExceeded(extraId: String, requested: Int, limit: Int)
    case pickupUnavailable
    case dropoffUnavailable
    case unknownMeetingPoint(Int)

    public var description: String {
        switch self {
        case .unknownRate(let id): return "Rate \(id) is not offered."
        case .rateNotOfferedAtStartTime(let rate, let time): return "Rate \(rate) is not offered at start time \(time)."
        case .departureNotBookable: return "This departure is sold out."
        case .notEnoughSeats(let requested, let available): return "Only \(available) seats are left; \(requested) were requested."
        case .belowMinimumParticipants(let requested, let minimum): return "This departure needs at least \(minimum) participants; \(requested) were selected."
        case .rateBookingBounds(let requested, let minimum, let maximum): return "This rate takes \(minimum ?? 1)–\(maximum.map(String.init) ?? "any") participants; \(requested) were selected."
        case .unknownPricingCategory(let id): return "Pricing category \(id) is not valid for this rate."
        case .categoryBookingBounds(let id, let requested, let minimum, let maximum): return "Category \(id) takes \(minimum ?? 0)–\(maximum.map(String.init) ?? "any") participants; \(requested) were selected."
        case .noPassengers: return "Select at least one participant."
        case .missingMainContact(let id): return "Contact detail \(id) is required."
        case .missingPassengerDetail(let index, let id): return "Participant \(index + 1): \(id) is required."
        case .missingQuestion(let id): return "Question \(id) must be answered."
        case .missingPassengerAnswer(let index, let id): return "Participant \(index + 1): question \(id) must be answered."
        case .unknownExtra(let id): return "Extra \(id) is not offered with this rate."
        case .extraLimitExceeded(let id, let requested, let limit): return "Extra \(id) is limited to \(limit); \(requested) were selected."
        case .pickupUnavailable: return "Pickup is not available for this departure."
        case .dropoffUnavailable: return "Drop-off is not available for this departure."
        case .unknownMeetingPoint(let id): return "Meeting point \(id) is not offered."
        }
    }
}

/// Checks a selection against the service's rules, so the customer hears about a problem at the
/// form rather than as a 400 from `bookingValidation`.
public struct ToristySelectionValidator: Sendable {

    public init() {}

    public func issues(for selection: ToristySelection, information: ToristyBookingInformation) -> [ToristySelectionIssue] {
        var issues: [ToristySelectionIssue] = []
        let startTime = selection.startTime
        let partySize = selection.passengers.count

        guard let rate = information.rate(id: selection.rateId) else {
            return [.unknownRate(selection.rateId)]
        }
        if !rate.applies(toStartTimeId: startTime.id) {
            issues.append(.rateNotOfferedAtStartTime(rateId: rate.id, startTimeId: startTime.id))
        }
        if !startTime.isBookable {
            issues.append(.departureNotBookable)
        }
        if partySize == 0 {
            issues.append(.noPassengers)
        }
        if !startTime.isUnlimited, partySize > startTime.availableCount {
            issues.append(.notEnoughSeats(requested: partySize, available: startTime.availableCount))
        }
        if partySize > 0, partySize < startTime.minParticipants {
            issues.append(.belowMinimumParticipants(requested: partySize, minimum: startTime.minParticipants))
        }

        let departureRate = startTime.rate(id: rate.id)
        if let departureRate, partySize > 0 {
            let belowMinimum = departureRate.minPerBooking.map { partySize < $0 } ?? false
            let aboveMaximum = departureRate.maxPerBooking.map { partySize > $0 } ?? false
            if belowMinimum || aboveMaximum {
                issues.append(.rateBookingBounds(requested: partySize, minimum: departureRate.minPerBooking, maximum: departureRate.maxPerBooking))
            }
        }

        for (categoryId, count) in selection.passengerCounts.sorted(by: { $0.key < $1.key }) {
            guard let category = rate.category(id: categoryId), departureRate?.accepts(pricingCategoryId: categoryId) ?? true else {
                issues.append(.unknownPricingCategory(categoryId))
                continue
            }
            let belowMinimum = category.minPerBooking.map { $0 > 0 && count < $0 } ?? false
            let aboveMaximum = category.maxPerBooking.map { $0 > 0 && count > $0 } ?? false
            if belowMinimum || aboveMaximum {
                issues.append(.categoryBookingBounds(categoryId: categoryId, requested: count, minimum: category.minPerBooking, maximum: category.maxPerBooking))
            }
        }

        issues += missingAnswers(selection, fields: information.fields)
        issues += extraIssues(selection, rate: rate)
        issues += transferIssues(selection, information: information, departureRate: departureRate)
        return issues
    }

    /// Throws `BookingError.invalidSelection` when there is any issue.
    public func validate(_ selection: ToristySelection, information: ToristyBookingInformation) throws {
        let found = issues(for: selection, information: information)
        guard found.isEmpty else { throw BookingError.invalidSelection(found.map(\.description)) }
    }

    private func missingAnswers(_ selection: ToristySelection, fields: ToristyBookingFields) -> [ToristySelectionIssue] {
        var issues: [ToristySelectionIssue] = []
        let contact = answered(selection.mainContact)
        for field in fields.mainContact where field.required && !contact.contains(field.questionId) {
            issues.append(.missingMainContact(questionId: field.questionId))
        }
        let bookingAnswers = answered(selection.bookingAnswers + selection.mainContact)
        for question in fields.mainContactQuestions where question.required && !bookingAnswers.contains(question.questionId) {
            issues.append(.missingQuestion(questionId: question.questionId))
        }
        for (index, passenger) in selection.passengers.enumerated() {
            let details = answered(passenger.details)
            for field in fields.passengerContact where field.required && !details.contains(field.questionId) {
                issues.append(.missingPassengerDetail(passengerIndex: index, questionId: field.questionId))
            }
            let answers = answered(passenger.answers)
            for question in fields.passengerQuestions where question.required && !answers.contains(question.questionId) {
                issues.append(.missingPassengerAnswer(passengerIndex: index, questionId: question.questionId))
            }
        }
        return issues
    }

    private func extraIssues(_ selection: ToristySelection, rate: ToristyRate) -> [ToristySelectionIssue] {
        var issues: [ToristySelectionIssue] = []
        var bookingTotals: [String: Int] = [:]
        for passenger in selection.passengers {
            for chosen in passenger.extras where chosen.quantity > 0 {
                guard let extra = rate.extras.first(where: { $0.id == chosen.extraId }) else {
                    issues.append(.unknownExtra(chosen.extraId))
                    continue
                }
                bookingTotals[extra.id, default: 0] += chosen.quantity
                if extra.isLimitPerPassenger, let limit = extra.limit, chosen.quantity > limit {
                    issues.append(.extraLimitExceeded(extraId: extra.id, requested: chosen.quantity, limit: limit))
                }
            }
        }
        for (extraId, total) in bookingTotals.sorted(by: { $0.key < $1.key }) {
            guard let extra = rate.extras.first(where: { $0.id == extraId }), !extra.isLimitPerPassenger, let limit = extra.limit else { continue }
            if total > limit {
                issues.append(.extraLimitExceeded(extraId: extraId, requested: total, limit: limit))
            }
        }
        return Array(Set(issues)).sorted { $0.description < $1.description }
    }

    private func transferIssues(_ selection: ToristySelection, information: ToristyBookingInformation,
                                departureRate: ToristyStartTimeRate?) -> [ToristySelectionIssue] {
        var issues: [ToristySelectionIssue] = []
        if let pickup = selection.pickup {
            if departureRate?.pickupSelection == .unavailable || selection.startTime.isPickupSoldOut {
                issues.append(.pickupUnavailable)
            }
            if let placeId = pickup.placeId, !information.pickupPoints.isEmpty, !information.pickupPoints.contains(where: { $0.id == placeId }) {
                issues.append(.unknownMeetingPoint(placeId))
            }
        }
        if let dropoff = selection.dropoff {
            if departureRate?.dropoffSelection == .unavailable {
                issues.append(.dropoffUnavailable)
            }
            if let placeId = dropoff.placeId, !information.dropoffPoints.isEmpty, !information.dropoffPoints.contains(where: { $0.id == placeId }) {
                issues.append(.unknownMeetingPoint(placeId))
            }
        }
        return issues
    }

    private func answered(_ answers: [ToristyAnswer]) -> Set<String> {
        Set(answers.filter { !$0.isBlank }.map(\.questionId))
    }
}
