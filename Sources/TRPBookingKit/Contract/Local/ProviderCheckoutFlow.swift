import Foundation

/// The state of one local checkout that the client turns into a contract `Checkout`.
struct FlowSnapshot {
    typealias BC = BookingContract

    var status: BC.CheckoutStatus = .collectingDetails
    var optionId: String?
    var amount: BC.Money?
    var holdPlacedAt: Date?
    var holdExpiresAt: Date?
    var priceValidUntil: Date?
    var step: BC.Step?
    var nextAction: BC.NextAction?
    var allowed: [BC.AllowedAction] = [.submit, .cancel]
    var bookingStatus: BC.BookingStatus?
    var result: BC.CheckoutResult?
    var httpStatus = 200
    var retryAfter: TimeInterval?

    var isFinished: Bool {
        [.confirmed, .pending, .failed, .expired, .cancelled].contains(status)
    }

    var nextActionId: String? {
        switch nextAction {
        case .stripePaymentIntent(let payload)?: return payload.id
        case .providerHostedForm(let payload)?: return payload.id
        case .braintreeDropin(let payload)?: return payload.id
        case .redirect(let payload)?: return payload.id
        case .threeDS(let payload)?: return payload.id
        default: return nil
        }
    }

    mutating func clearHold() {
        holdPlacedAt = nil
        holdExpiresAt = nil
        priceValidUntil = nil
    }
}

/// A contract error a flow raises; the client adds the checkout when `includesCheckout` is set.
struct FlowRejection: Error {
    let code: BookingContract.ErrorCode
    let httpStatus: Int
    var errors: [BookingContract.ErrorData.FieldError] = []
    var retryable = false
    var includesCheckout = true

    static let stepMismatch = FlowRejection(code: .stepMismatch, httpStatus: 409)
    static let priceChanged = FlowRejection(code: .priceChanged, httpStatus: 409)
    static let soldOut = FlowRejection(code: .soldOut, httpStatus: 409)
    static let paymentDeclined = FlowRejection(code: .paymentDeclined, httpStatus: 402)
    static let holdExpired = FlowRejection(code: .holdExpired, httpStatus: 410)
    static let notCancellable = FlowRejection(code: .notCancellable, httpStatus: 409, includesCheckout: false)

    static func validation(_ errors: [BookingContract.ErrorData.FieldError]) -> FlowRejection {
        FlowRejection(code: .validation, httpStatus: 422, errors: errors)
    }

    static func supplierUnavailable(retryable: Bool = true) -> FlowRejection {
        FlowRejection(code: .supplierUnavailable, httpStatus: 503, retryable: retryable, includesCheckout: false)
    }

    /// The contract error a provider failure stands for.
    static func from(_ error: Error) -> FlowRejection {
        switch error {
        case let rejection as FlowRejection: return rejection
        case let contract as BookingContract.ContractError:
            return FlowRejection(code: contract.code, httpStatus: contract.httpStatus, errors: contract.data.errors,
                                 retryable: contract.data.retryable, includesCheckout: contract.data.checkout != nil)
        case let booking as BookingError:
            switch booking {
            case .invalidSelection(let messages):
                return .validation(messages.map { BookingContract.ErrorData.FieldError(field: "answers", message: $0) })
            case .holdExpired: return .holdExpired
            case .paymentFailed, .paymentCancelled: return .paymentDeclined
            case .notCancellable: return .notCancellable
            case .server(let status, _, _) where status < 500: return .supplierUnavailable(retryable: false)
            case .rejected, .holdRejected, .tooManyHolds, .confirmationFailedAfterCharge:
                return .supplierUnavailable(retryable: false)
            default: return .supplierUnavailable()
            }
        default: return .supplierUnavailable()
        }
    }
}

/// What a flow is given about the checkout it runs.
struct FlowContext: Sendable {
    let checkoutId: String
    let bookingUuid: String
    let product: LocalProduct
    let request: BookingContract.CreateCheckoutRequest
    let store: BookingRecordStore
    let identifiers: LocalIdentifiers
    let now: @Sendable () -> Date

    var currency: String { request.currency }
}

/// One provider's checkout behind the contract's step machine.
///
/// The client checks the step id, allowed actions, action id and hold before calling a flow,
/// so a flow only handles calls that fit its current state. A flow updates `snapshot` before it throws.
protocol ProviderCheckoutFlow: AnyObject {
    var snapshot: FlowSnapshot { get set }
    /// Builds the first step.
    func start() async throws
    func submit(answers: BookingContract.Answers, expectedAmount: BookingContract.Money?) async throws
    func back() async throws
    func act(result: BookingContract.ActionResult) async throws
    /// Brings a checkout that is still processing up to date; called on every `get`.
    func refresh() async
    func extend() async throws
    /// Releases whatever the checkout holds at the provider.
    func cancel() async
    /// Marks the provider's record of an expired hold.
    func expire() async
}

extension ProviderCheckoutFlow {
    func refresh() async {}

    func extend() async throws { throw FlowRejection.stepMismatch }
}

/// Answers kept per step so a step shown again after `back` carries them as defaults.
struct StepAnswers {
    private(set) var byStep: [String: BookingContract.Answers] = [:]
    private(set) var order: [String] = []

    mutating func record(_ answers: BookingContract.Answers, for stepId: String) {
        byStep[stepId] = answers
        if !order.contains(stepId) { order.append(stepId) }
    }

    func value(_ id: String) -> BookingContract.JSONValue? {
        for step in order.reversed() {
            if let value = byStep[step]?[id], !value.isNull { return value }
        }
        return nil
    }

    func string(_ id: String) -> String? { value(id)?.stringValue }
}

extension BookingContract.Answers {
    func string(_ id: String) -> String? {
        self[id]?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    func units(_ id: String) -> [String: Int] {
        (self[id]?.objectValue ?? [:]).compactMapValues { $0.numberValue.map { Int($0) } }
    }
}

/// Checks shared by the flows' detail steps.
enum LocalValidation {
    static func required(_ ids: [(id: String, message: String)], in answers: BookingContract.Answers) -> [BookingContract.ErrorData.FieldError] {
        ids.filter { answers.string($0.id) == nil }.map { BookingContract.ErrorData.FieldError(field: $0.id, message: $0.message) }
    }

    static func email(_ id: String, in answers: BookingContract.Answers) -> BookingContract.ErrorData.FieldError? {
        guard let email = answers.string(id) else { return nil }
        let pattern = "^[^@\\s]+@[^@\\s]+\\.[^@\\s]{2,}$"
        return email.range(of: pattern, options: .regularExpression) == nil
            ? BookingContract.ErrorData.FieldError(field: id, message: "Enter a valid email address.") : nil
    }

    static func consent(_ id: String, in answers: BookingContract.Answers) -> BookingContract.ErrorData.FieldError? {
        answers[id]?.boolValue == true ? nil : BookingContract.ErrorData.FieldError(field: id, message: "Please accept the terms to continue.")
    }
}
