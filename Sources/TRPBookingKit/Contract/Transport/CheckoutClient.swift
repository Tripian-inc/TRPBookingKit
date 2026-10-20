import Foundation

extension BookingContract {

    /// A checkout as one call answered it.
    ///
    /// `httpStatus` is 202 while the server is still processing, and `retryAfter` is then the number of seconds to
    /// wait before polling with `get`.
    public struct CheckoutResponse: Hashable, Sendable {
        public let checkout: Checkout
        public let httpStatus: Int
        public let retryAfter: TimeInterval?

        public init(checkout: Checkout, httpStatus: Int, retryAfter: TimeInterval? = nil) {
            self.checkout = checkout
            self.httpStatus = httpStatus
            self.retryAfter = retryAfter
        }

        public var isProcessing: Bool { httpStatus == 202 }
    }

    /// One page of `GET /bookings`.
    public struct BookingPage: Hashable, Sendable {
        public let bookings: [Booking]
        public let pagination: Pagination?

        public init(bookings: [Booking], pagination: Pagination?) {
            self.bookings = bookings
            self.pagination = pagination
        }
    }
}

/// The checkout calls of the booking contract.
///
/// Every mutating call takes an `IdempotencyKey`; send the same key again only when retrying the same request.
/// A contract error response is thrown as `BookingContract.ContractError`.
public protocol CheckoutClient: Sendable {

    /// `POST /checkouts`.
    func create(_ request: BookingContract.CreateCheckoutRequest,
                idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.CheckoutResponse

    /// `GET /checkouts/{id}`, also used to poll a processing checkout.
    func get(id: String, lang: String) async throws -> BookingContract.CheckoutResponse

    /// `POST /checkouts/{id}/steps/{stepId}`.
    func submit(checkoutId: String, stepId: String, answers: BookingContract.Answers,
                expectedAmount: BookingContract.Money?, lang: String,
                idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.CheckoutResponse

    /// `POST /checkouts/{id}/back`, leaving `fromStepId`.
    func back(checkoutId: String, fromStepId: String, lang: String,
              idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.CheckoutResponse

    /// `POST /checkouts/{id}/actions/{actionId}`.
    func action(checkoutId: String, actionId: String, result: BookingContract.ActionResult, lang: String,
                idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.CheckoutResponse

    /// `POST /checkouts/{id}/extend`.
    func extend(checkoutId: String, lang: String,
                idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.CheckoutResponse

    /// `POST /checkouts/{id}/cancel`.
    func cancel(checkoutId: String, lang: String,
                idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.CheckoutResponse

    /// `GET /checkouts/{id}/actions/{actionId}/settlement`: whether a payment the client cannot observe, such as a
    /// provider hosted cart, has been made. A client that cannot tell answers `pending`.
    func settlement(checkoutId: String, actionId: String) async throws -> BookingContract.ActionSettlement
}

extension CheckoutClient {

    public func settlement(checkoutId: String, actionId: String) async throws -> BookingContract.ActionSettlement {
        .pending
    }

    /// `create` with a fresh idempotency key.
    public func create(_ request: BookingContract.CreateCheckoutRequest) async throws -> BookingContract.CheckoutResponse {
        try await create(request, idempotencyKey: BookingContract.IdempotencyKey())
    }

    /// `submit` with a fresh idempotency key.
    public func submit(checkoutId: String, stepId: String, answers: BookingContract.Answers,
                       expectedAmount: BookingContract.Money? = nil,
                       lang: String) async throws -> BookingContract.CheckoutResponse {
        try await submit(checkoutId: checkoutId, stepId: stepId, answers: answers, expectedAmount: expectedAmount,
                         lang: lang, idempotencyKey: BookingContract.IdempotencyKey())
    }

    /// `back` with a fresh idempotency key.
    public func back(checkoutId: String, fromStepId: String, lang: String) async throws -> BookingContract.CheckoutResponse {
        try await back(checkoutId: checkoutId, fromStepId: fromStepId, lang: lang,
                       idempotencyKey: BookingContract.IdempotencyKey())
    }

    /// `action` with a fresh idempotency key.
    public func action(checkoutId: String, actionId: String, result: BookingContract.ActionResult,
                       lang: String) async throws -> BookingContract.CheckoutResponse {
        try await action(checkoutId: checkoutId, actionId: actionId, result: result, lang: lang,
                         idempotencyKey: BookingContract.IdempotencyKey())
    }

    /// `extend` with a fresh idempotency key.
    public func extend(checkoutId: String, lang: String) async throws -> BookingContract.CheckoutResponse {
        try await extend(checkoutId: checkoutId, lang: lang, idempotencyKey: BookingContract.IdempotencyKey())
    }

    /// `cancel` with a fresh idempotency key.
    public func cancel(checkoutId: String, lang: String) async throws -> BookingContract.CheckoutResponse {
        try await cancel(checkoutId: checkoutId, lang: lang, idempotencyKey: BookingContract.IdempotencyKey())
    }
}

/// The booking calls of the booking contract.
public protocol BookingClient: Sendable {

    /// `GET /bookings`, filtered by `status` when it is not empty; `page` starts at 1.
    func list(status: [BookingContract.BookingStatus], page: Int, limit: Int,
              lang: String) async throws -> BookingContract.BookingPage

    /// `GET /bookings/{uuid}`.
    func get(uuid: String, lang: String) async throws -> BookingContract.Booking

    /// `POST /bookings/{uuid}/cancel`.
    func cancel(uuid: String, reason: String?, lang: String,
                idempotencyKey: BookingContract.IdempotencyKey) async throws -> BookingContract.Booking
}

extension BookingClient {

    /// `cancel` with a fresh idempotency key.
    public func cancel(uuid: String, reason: String? = nil, lang: String) async throws -> BookingContract.Booking {
        try await cancel(uuid: uuid, reason: reason, lang: lang, idempotencyKey: BookingContract.IdempotencyKey())
    }
}
