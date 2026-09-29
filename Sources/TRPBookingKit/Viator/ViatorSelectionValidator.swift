import Foundation

/// A problem with a Viator party or its answers, found before anything is sent.
public enum ViatorSelectionIssue: Sendable, Hashable, CustomStringConvertible {
    case noTravelers
    case travelerCount(requested: Int, minimum: Int, maximum: Int?)
    case needsAdult
    case unknownAgeBand(ViatorAgeBand)
    case ageBandCount(band: ViatorAgeBand, requested: Int, minimum: Int, maximum: Int?)
    case missingAnswer(questionId: String, travelerNum: Int?)
    case answerTooLong(questionId: String, maximum: Int)
    case answerNotAllowed(questionId: String)
    case invalidUnit(questionId: String)
    case unknownQuestion(String)

    public var description: String {
        switch self {
        case .noTravelers: return "Select at least one traveller."
        case .travelerCount(let requested, let minimum, let maximum): return "This tour takes \(minimum)–\(maximum.map(String.init) ?? "any") travellers; \(requested) were selected."
        case .needsAdult: return "At least one adult must travel."
        case .unknownAgeBand(let band): return "\(band.rawValue.capitalized) travellers are not accepted on this tour."
        case .ageBandCount(let band, let requested, let minimum, let maximum): return "\(band.rawValue.capitalized): \(minimum)–\(maximum.map(String.init) ?? "any") allowed; \(requested) were selected."
        case .missingAnswer(let id, let traveler): return traveler.map { "Traveller \($0): \(id) is required." } ?? "\(id) is required."
        case .answerTooLong(let id, let maximum): return "\(id) must be at most \(maximum) characters."
        case .answerNotAllowed(let id): return "\(id) has an answer that is not one of the options."
        case .invalidUnit(let id): return "\(id) needs a valid unit."
        case .unknownQuestion(let id): return "\(id) is not a question of this tour."
        }
    }
}

/// Checks a Viator party and its booking answers against the product's rules.
public struct ViatorSelectionValidator: Sendable {

    public init() {}

    /// Checks the party before `availability/check`, which otherwise answers with a vague 400.
    public func paxIssues(_ paxMix: [ViatorPax], product: ViatorProduct) -> [ViatorSelectionIssue] {
        let party = paxMix.filter { $0.numberOfTravelers > 0 }
        let total = party.reduce(0) { $0 + $1.numberOfTravelers }
        guard total > 0 else { return [.noTravelers] }

        var issues: [ViatorSelectionIssue] = []
        if !Self.within(total, minimum: product.minTravelersPerBooking, maximum: product.maxTravelersPerBooking) {
            issues.append(.travelerCount(requested: total, minimum: product.minTravelersPerBooking, maximum: product.maxTravelersPerBooking))
        }
        let leadBands: Set<ViatorAgeBand> = [.adult, .traveler]
        if !party.contains(where: { leadBands.contains($0.ageBand) }) {
            issues.append(.needsAdult)
        }
        for pax in party {
            guard let rule = product.ageBands.first(where: { $0.ageBand == pax.ageBand }) else {
                issues.append(.unknownAgeBand(pax.ageBand))
                continue
            }
            if !Self.within(pax.numberOfTravelers, minimum: rule.minTravelersPerBooking, maximum: rule.maxTravelersPerBooking) {
                issues.append(.ageBandCount(band: pax.ageBand, requested: pax.numberOfTravelers,
                                            minimum: rule.minTravelersPerBooking, maximum: rule.maxTravelersPerBooking))
            }
        }
        for rule in product.ageBands where rule.minTravelersPerBooking > 0 && !party.contains(where: { $0.ageBand == rule.ageBand }) {
            issues.append(.ageBandCount(band: rule.ageBand, requested: 0, minimum: rule.minTravelersPerBooking, maximum: rule.maxTravelersPerBooking))
        }
        return issues
    }

    /// Checks the answers before `cart/book`. `CONDITIONAL` questions are only checked when answered,
    /// since their condition lives in Viator's rules, not in the dictionary.
    public func answerIssues(_ answers: [ViatorAnswer],
                             product: ViatorProduct,
                             questions: [ViatorBookingQuestion],
                             travelerCount: Int) -> [ViatorSelectionIssue] {
        let asked = questions.filter { product.bookingQuestionIds.contains($0.id) }
        var issues: [ViatorSelectionIssue] = answers
            .filter { answer in !asked.contains { $0.id == answer.question } }
            .map { .unknownQuestion($0.question) }

        for question in asked {
            let given = answers.filter { $0.question == question.id && !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if question.required == .mandatory {
                issues += missing(question, given: given, travelerCount: travelerCount)
            }
            for answer in given {
                issues += problems(with: answer, question: question)
            }
        }
        return issues
    }

    /// Throws `BookingError.invalidSelection` with every issue found.
    public func validate(_ paxMix: [ViatorPax], product: ViatorProduct) throws {
        let found = paxIssues(paxMix, product: product)
        guard found.isEmpty else { throw BookingError.invalidSelection(found.map(\.description)) }
    }

    /// Throws `BookingError.invalidSelection` with every issue found.
    public func validate(_ details: ViatorBookerDetails, product: ViatorProduct, questions: [ViatorBookingQuestion], travelerCount: Int) throws {
        let found = answerIssues(details.answers, product: product, questions: questions, travelerCount: travelerCount)
        guard found.isEmpty else { throw BookingError.invalidSelection(found.map(\.description)) }
    }

    private static func within(_ count: Int, minimum: Int, maximum: Int?) -> Bool {
        guard count >= minimum else { return false }
        guard let maximum else { return true }
        return count <= maximum
    }

    private func missing(_ question: ViatorBookingQuestion, given: [ViatorAnswer], travelerCount: Int) -> [ViatorSelectionIssue] {
        switch question.group {
        case .perBooking:
            return given.isEmpty ? [.missingAnswer(questionId: question.id, travelerNum: nil)] : []
        case .perTraveler:
            let answered = Set(given.compactMap(\.travelerNum))
            return (1...max(1, travelerCount)).filter { !answered.contains($0) }.map { .missingAnswer(questionId: question.id, travelerNum: $0) }
        }
    }

    private func problems(with answer: ViatorAnswer, question: ViatorBookingQuestion) -> [ViatorSelectionIssue] {
        var issues: [ViatorSelectionIssue] = []
        if let maximum = question.maxLength, answer.answer.count > maximum {
            issues.append(.answerTooLong(questionId: question.id, maximum: maximum))
        }
        if !question.allowedAnswers.isEmpty, !question.allowedAnswers.contains(answer.answer) {
            issues.append(.answerNotAllowed(questionId: question.id))
        }
        if question.requiresUnit, answer.unit.map({ question.units.isEmpty || question.units.contains($0) }) != true {
            issues.append(.invalidUnit(questionId: question.id))
        }
        return issues
    }
}
